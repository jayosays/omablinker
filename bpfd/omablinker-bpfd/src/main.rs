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
/// uses) and mirrors storage activity into small world-readable state files
/// the plugin's bar widget watches natively, plus optionally a real sysfs
/// LED. Reads and writes are tracked as two independent channels, plus a
/// combined one for the single-LED display mode — see `Channel`.
#[derive(Debug, Parser)]
struct Opt {
    /// Optional sysfs LED brightness path to blink in lockstep with the
    /// on-screen LED, e.g. /sys/class/leds/some-led/brightness. List
    /// candidates with: ls /sys/class/leds/. Tracks combined activity,
    /// regardless of which mode the on-screen widget is displaying.
    #[arg(long, env = "OMABLINKER_LED_DEVICE")]
    led_device: Option<PathBuf>,

    /// Milliseconds of silence before a channel is considered idle.
    #[arg(long, env = "OMABLINKER_IDLE_MS", default_value_t = 120)]
    idle_ms: u64,

    /// Path to the combined-activity state file the bar widget's
    /// Service.qml watches. The per-direction state files (for the
    /// Read/Write display mode) are written as `state-read` and
    /// `state-write` next to it, in the same directory.
    #[arg(
        long,
        env = "OMABLINKER_STATE_LOG",
        default_value = "/run/omablinker/state"
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

/// A world-readable state file `Service.qml` watches directly with a
/// native `FileView` — no subprocess on the reading side, and none needed
/// here either: one byte, "1" while active or "0" while idle, overwritten
/// in place on the same open handle every time the state changes. A fresh
/// `FileView` load always sees the current value immediately, so unlike an
/// append-only log there's no need to re-emit during a sustained burst
/// just so a (re)starting widget doesn't miss it.
struct StateFile(File);

impl StateFile {
    fn open(path: &Path) -> anyhow::Result<Self> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        }
        let mut file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(path)
            .with_context(|| format!("opening {}", path.display()))?;
        fs::set_permissions(path, fs::Permissions::from_mode(0o644))
            .with_context(|| format!("chmod {}", path.display()))?;
        write!(file, "0")
            .with_context(|| format!("writing initial state to {}", path.display()))?;
        file.flush().ok();
        Ok(Self(file))
    }

    fn set(&mut self, active: bool) {
        let _ = self.0.seek(SeekFrom::Start(0));
        let _ = self.0.set_len(0);
        let _ = write!(self.0, "{}", u8::from(active));
        let _ = self.0.flush();
    }
}

/// One independent activity/idle state machine feeding one state file.
/// Read, write, and combined activity are tracked as three of these,
/// polling the same eBPF counters but reaching their own active/idle
/// decisions independently, all using the same `idle_window`.
struct Channel {
    state_file: StateFile,
    last_total: u64,
    last_event: Instant,
    active: bool,
    seeded: bool,
}

impl Channel {
    fn open(path: &Path) -> anyhow::Result<Self> {
        Ok(Self {
            state_file: StateFile::open(path)?,
            last_total: 0,
            last_event: Instant::now(),
            active: false,
            seeded: false,
        })
    }

    /// Feed this poll tick's raw counter total. `now` is passed in rather
    /// than read again here so all channels judge the same instant.
    fn tick(&mut self, total: u64, idle_window: Duration, now: Instant) {
        // Don't treat whatever the counter already holds from before this
        // process started as a fresh burst of activity.
        if !self.seeded {
            self.last_total = total;
            self.seeded = true;
            return;
        }

        if total != self.last_total {
            self.last_total = total;
            self.last_event = now;
            if !self.active {
                self.active = true;
                self.state_file.set(true);
            }
        } else if self.active && now.duration_since(self.last_event) >= idle_window {
            self.active = false;
            self.state_file.set(false);
        }
    }

    fn shutdown(&mut self) {
        if self.active {
            self.active = false;
            self.state_file.set(false);
        }
    }
}

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

    let state_dir = opt
        .state_log
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let mut combined = Channel::open(&opt.state_log)?;
    let mut read = Channel::open(&state_dir.join("state-read"))?;
    let mut write = Channel::open(&state_dir.join("state-write"))?;

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
        "watching block I/O, writing state to {} (combined), {} (read), {} (write)",
        opt.state_log.display(),
        state_dir.join("state-read").display(),
        state_dir.join("state-write").display()
    );

    let idle_window = Duration::from_millis(opt.idle_ms.max(20));

    // No async runtime needed: this loop is a single serial state machine
    // (sleep, a couple of map lookups, maybe a small write, check a flag)
    // with no concurrent I/O to multiplex, so a plain OS thread costs
    // nothing that an async executor would save and skips its
    // worker-thread pool and scheduler entirely. `signal-hook`'s flag
    // registration is async-signal-safe: the real handler just does an
    // atomic store, and we read it back here in normal code.
    let shutdown = Arc::new(AtomicBool::new(false));
    signal_hook::flag::register(signal_hook::consts::SIGTERM, Arc::clone(&shutdown))
        .context("registering SIGTERM handler")?;
    signal_hook::flag::register(signal_hook::consts::SIGINT, Arc::clone(&shutdown))
        .context("registering SIGINT handler")?;

    // The physical LED, if any, always reflects combined activity — it's a
    // single indicator, so splitting it by direction isn't meaningful the
    // way two independent on-screen LEDs are.
    let mut combined_was_active = false;

    while !shutdown.load(Ordering::Relaxed) {
        thread::sleep(POLL_INTERVAL);

        let read_total: u64 = activity.get(&0, 0)?.iter().copied().sum();
        let write_total: u64 = activity.get(&1, 0)?.iter().copied().sum();

        let now = Instant::now();
        read.tick(read_total, idle_window, now);
        write.tick(write_total, idle_window, now);
        combined.tick(read_total + write_total, idle_window, now);

        if combined.active != combined_was_active {
            combined_was_active = combined.active;
            if let Some(led) = &mut led {
                led.set(combined.active);
            }
        }
    }

    info!("received shutdown signal, shutting down");
    read.shutdown();
    write.shutdown();
    combined.shutdown();
    if let Some(led) = &mut led {
        led.set(false);
    }

    Ok(())
}
