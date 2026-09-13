use std::{
    fs::{self, File, OpenOptions},
    io::{Seek as _, SeekFrom, Write as _},
    os::unix::fs::PermissionsExt as _,
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    thread,
    time::{Duration, Instant},
};

use anyhow::Context as _;
use aya::{maps::PerCpuArray, programs::TracePoint};
use clap::Parser;
use log::{debug, info, warn};

/// eBPF block-I/O activity watcher for the omablinker Omarchy plugin.
///
/// Attaches to the `block:block_rq_issue` / `block:block_rq_complete`
/// tracepoints (the same two tracepoints the standard `biolatency` BCC tool
/// uses) and mirrors storage activity into a small world-readable log that
/// the plugin's bar widget tails, plus optionally a real sysfs LED.
#[derive(Debug, Parser)]
struct Opt {
    /// Optional sysfs LED brightness path to blink in lockstep with the
    /// on-screen LED, e.g. /sys/class/leds/some-led/brightness. List
    /// candidates with: ls /sys/class/leds/
    #[arg(long, env = "OMABLINKER_LED_DEVICE")]
    led_device: Option<PathBuf>,

    /// Milliseconds of silence before the LED is considered idle.
    #[arg(long, env = "OMABLINKER_IDLE_MS", default_value_t = 120)]
    idle_ms: u64,

    /// Path to the pulse log the bar widget's Service.qml tails.
    #[arg(
        long,
        env = "OMABLINKER_STATE_LOG",
        default_value = "/run/omablinker/pulses.log"
    )]
    state_log: PathBuf,
}

/// A real hardware LED, driven by writing its sysfs brightness file directly.
struct Led {
    file: File,
    max_brightness: u64,
}

impl Led {
    fn open(path: &Path) -> anyhow::Result<Self> {
        let max_brightness = path
            .parent()
            .map(|dir| dir.join("max_brightness"))
            .and_then(|p| fs::read_to_string(p).ok())
            .and_then(|s| s.trim().parse().ok())
            .unwrap_or(1);
        let file = OpenOptions::new()
            .write(true)
            .open(path)
            .with_context(|| format!("opening LED device {}", path.display()))?;
        Ok(Self {
            file,
            max_brightness,
        })
    }

    fn set(&mut self, on: bool) {
        let _ = self.file.seek(SeekFrom::Start(0));
        let value = if on { self.max_brightness } else { 0 };
        let _ = write!(self.file, "{value}");
        let _ = self.file.flush();
    }
}

/// The world-readable log the bar widget tails with `tail -F`. One line per
/// edge — "1" when activity starts, "0" when it goes idle — plus periodic
/// "1" re-emits during a long burst so a widget that (re)starts mid-burst
/// still sees it, without writing a line per individual block request.
struct PulseLog(File);

impl PulseLog {
    fn open(path: &Path) -> anyhow::Result<Self> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .with_context(|| format!("opening {}", path.display()))?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o644))
            .with_context(|| format!("chmod {}", path.display()))?;
        Ok(Self(file))
    }

    fn emit(&mut self, active: bool) {
        let _ = writeln!(self.0, "{}", u8::from(active));
        let _ = self.0.flush();
    }
}

/// How often a sustained burst re-emits "1", and how often we poll the
/// activity counter. Both are cheap: no syscalls happen in the kernel-side
/// hot path, and userspace only does a per-CPU map lookup on this cadence
/// rather than waking up once per I/O request.
const MIN_EMIT_INTERVAL: Duration = Duration::from_millis(40);
const POLL_INTERVAL: Duration = Duration::from_millis(20);

fn main() -> anyhow::Result<()> {
    let opt = Opt::parse();
    env_logger::init();

    // Bump the memlock rlimit. This is needed for older kernels that don't use the
    // new memcg based accounting, see https://lwn.net/Articles/837122/
    let rlim = libc::rlimit {
        rlim_cur: libc::RLIM_INFINITY,
        rlim_max: libc::RLIM_INFINITY,
    };
    let ret = unsafe { libc::setrlimit(libc::RLIMIT_MEMLOCK, &rlim) };
    if ret != 0 {
        debug!("remove limit on locked memory failed, ret is: {ret}");
    }

    // This includes the eBPF object file as raw bytes at compile-time (built by
    // build.rs via aya-build) and loads it at runtime — no clang/LLVM in this
    // process, no runtime compilation, just a bpf() syscall.
    let mut ebpf = aya::Ebpf::load(aya::include_bytes_aligned!(concat!(
        env!("OUT_DIR"),
        "/omablinker-bpfd"
    )))?;

    for tracepoint_name in ["block_rq_issue", "block_rq_complete"] {
        let program: &mut TracePoint = ebpf
            .program_mut(tracepoint_name)
            .with_context(|| {
                format!("program {tracepoint_name} not found in the compiled eBPF object")
            })?
            .try_into()?;
        program.load()?;
        program
            .attach("block", tracepoint_name)
            .with_context(|| format!("attaching block:{tracepoint_name}"))?;
    }
    info!("attached to block:block_rq_issue and block:block_rq_complete");

    let activity: PerCpuArray<_, u64> =
        PerCpuArray::try_from(ebpf.map("ACTIVITY").context("ACTIVITY map missing")?)?;

    let mut pulses = PulseLog::open(&opt.state_log)?;
    let mut led = match &opt.led_device {
        Some(path) => match Led::open(path) {
            Ok(led) => Some(led),
            Err(e) => {
                warn!(
                    "--led-device {}: {e:#}; continuing without a hardware LED",
                    path.display()
                );
                None
            }
        },
        None => None,
    };

    info!(
        "watching block I/O, writing pulses to {}",
        opt.state_log.display()
    );

    let idle_window = Duration::from_millis(opt.idle_ms.max(20));

    // No async runtime needed: this loop is a single serial state machine
    // (sleep, one map lookup, maybe a small write, check a flag) with no
    // concurrent I/O to multiplex, so a plain OS thread costs nothing that
    // an async executor would save and skips its worker-thread pool and
    // scheduler entirely. `signal-hook`'s flag registration is
    // async-signal-safe: the real handler just does an atomic store, and we
    // read it back here in normal code.
    let shutdown = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&shutdown))
        .context("registering SIGTERM handler")?;
    signal_hook::flag::register(signal_hook::consts::SIGINT, Arc::clone(&shutdown))
        .context("registering SIGINT handler")?;

    let mut last_total: u64 = 0;
    let mut last_event = Instant::now();
    let mut last_emit = Instant::now() - MIN_EMIT_INTERVAL;
    let mut active = false;
    let mut seeded = false;

    while !shutdown.load(Ordering::Relaxed) {
        thread::sleep(POLL_INTERVAL);

        let total: u64 = activity.get(&0, 0)?.iter().copied().sum();

        // Don't treat whatever the counter already holds from before this
        // process started as a fresh burst of activity.
        if !seeded {
            last_total = total;
            seeded = true;
            continue;
        }

        let now = Instant::now();
        if total != last_total {
            last_total = total;
            last_event = now;
            if !active {
                active = true;
                pulses.emit(true);
                if let Some(led) = &mut led {
                    led.set(true);
                }
                last_emit = now;
            } else if now.duration_since(last_emit) >= MIN_EMIT_INTERVAL {
                pulses.emit(true);
                last_emit = now;
            }
        } else if active && now.duration_since(last_event) >= idle_window {
            active = false;
            pulses.emit(false);
            if let Some(led) = &mut led {
                led.set(false);
            }
        }
    }

    info!("received shutdown signal, shutting down");
    if active {
        pulses.emit(false);
    }
    if let Some(led) = &mut led {
        led.set(false);
    }

    Ok(())
}
