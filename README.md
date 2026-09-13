# OmaBlinker

![](preview.png)

A third-party [Omarchy](https://omarchy.org) Quattro shell plugin that adds
a small LED to the bar and blinks it whenever the kernel reports storage
activity — the on-screen equivalent of the red/amber drive-activity LED on
old PC towers, minus the actual LED (most laptops don't have one). If your
machine *does* have a spare, software-controllable LED under
`/sys/class/leds/`, OmaBlinker can drive that too, in lockstep with the
on-screen one.

Click the LED to open a settings popup: LED shape (square/circle), color
(red/amber), and blink style (an instant snap or a brief fade).

## How it works

Storage activity is detected with **eBPF**, not by polling
`/proc/diskstats`. A small BPF program, written in Rust with
[Aya](https://aya-rs.dev), attaches tracepoint probes to
`block:block_rq_issue` and `block:block_rq_complete` — the same two
block-layer tracepoints the standard `biolatency` BCC tool uses — so it
sees every request the kernel issues to any block device and every
completion, independent of filesystem or which disk it lands on. Each
tracepoint hit just increments a per-CPU counter in a BPF map; there's no
per-request syscall or write in the kernel-side hot path.

Loading a BPF program needs root, which the desktop shell process doesn't
have and shouldn't be given, so the plugin is split into a privileged
daemon and an unprivileged widget that only talk through a plain,
world-readable log file — no sockets, no D-Bus, no capabilities handed to
the shell process:

```
 root, via systemd               your desktop session, via Omarchy
┌────────────────────────┐       ┌──────────────────────────────────┐
│ omablinker-bpfd (Rust) │       │ Service.qml   (kind: service)    │
│  - loads the eBPF      │       │  - tail -F's the pulse log       │
│    program (Aya)       │       │  - debounces into active/idle    │
│  - polls a per-CPU     │──────▶│                                  │
│    counter map ~50/s   │ world-│ BarWidget.qml (kind: bar-widget) │
│  - writes pulses to    │ file  │  - draws the LED, reflects       │
│    /run/omablinker/    │       │    Service's active state        │
│    pulses.log          │       │                                  │
│  - optionally blinks   │       └──────────────────────────────────┘
│    a real sysfs LED    │
└────────────────────────┘
```

`omablinker-bpfd` is a single ~1.7 MB, single-threaded, dynamically-linked
binary (only glibc/libgcc — no Python, no embedded clang/LLVM, no async
runtime) that attaches its tracepoints and is sitting idle within
milliseconds of starting. It polls its BPF map roughly 50 times a second
rather than waking up per I/O request, so a drive doing tens of thousands
of IOPS costs the same few cheap map-lookups per second as an idle one.
Being single-threaded doesn't reduce what it sees: the per-CPU map already
aggregates every core's counter inside the kernel, and one thread reads all
of them in a single syscall.

As required of any third-party Omarchy plugin, everything here is plain,
readable code: `manifest.json` + `Service.qml` + `BarWidget.qml` are the
whole shell-side plugin, and `bpfd/` is the whole privileged daemon. Nothing
is obfuscated or fetched at install time.

## Install

The normal Omarchy way, once this is listed on the plugin registry (or
right away, by pointing at this repo directly):

```
omarchy plugin add https://github.com/jayosays/omablinker.git --enable
```

That installs and enables the bar widget itself. It doesn't set up the
privileged eBPF daemon, though — per Omarchy's plugin model, `plugin add`
never runs anything from a plugin or asks for sudo, so that's a separate,
explicit step:

```
cd ~/.config/omarchy/plugins/jayosays.omablinker
./install.sh
```

`install.sh`:
1. Installs `rustup` and `bpf-linker` if either is missing.
2. Builds `omablinker-bpfd` in release mode.
3. Installs the binary and a systemd **system** service for it to run as
   root — it prints exactly what it's about to do first, so read it before
   running, the same way you'd read any third-party plugin before enabling it.

Working from a local clone instead (for development, or before pushing
anywhere)? Run the same script from wherever you cloned it — it also
symlinks the checkout into `~/.config/omarchy/plugins/jayosays.omablinker`
itself in that case:

```
git clone <this repo> ~/code/omablinker
cd ~/code/omablinker
./install.sh
omarchy plugin enable jayosays.omablinker
```

After enabling it, add the widget to a bar section from *Setup > Plugins*
(or edit `~/.config/omarchy/shell.json` directly — see `defaultSection` in
`manifest.json`, currently `right`).

## Uninstall

```
./uninstall.sh
omarchy plugin remove jayosays.omablinker
```

`uninstall.sh` stops and removes the systemd service and the daemon binary,
and unlinks the plugin from `~/.config/omarchy/plugins/`.
`/etc/omablinker.env` is left in place in case you reinstall later; delete
it yourself if you want it gone too.

## Appearance

Click the LED to open its settings popup:

- **LED shape** — `Square` (default) is the boxy drive-activity LED common
  on PC front panels. `Circle` is a classic round 5 mm LED.
- **LED color** — `Red` (default) is a saturated red-orange close to the
  5 mm red LEDs used on most beige-box drive lights. `Amber` is the
  orange-yellow tone common on 386/486-era cases (often shared with the
  turbo-mode light on the same front panel).
- **Blink style** — `Abrupt` (default) snaps the LED on and off instantly,
  matching how a real drive-activity LED flashes. `Fade` eases it in
  quickly and lets it linger a little on the way out, for a softer look.

These are stored in `~/.config/omablinker/widget-prefs.json`, managed
entirely by the popup rather than through `manifest.json`'s settings
schema — as of this writing, nothing in Omarchy's shell renders a settings
form from that schema yet, so a schema-only setting has no UI to change it
from. `idleTimeoutMs` (how long the LED stays lit after the last event,
default `120`ms) is one such setting; change it by adding it directly to
the widget's entry in `~/.config/omarchy/shell.json`.

## Configuring the daemon

Optional settings for `omablinker-bpfd` live in `/etc/omablinker.env` (see
`systemd/omablinker.env.example`), and take effect after
`sudo systemctl restart omablinker`:

| Key                     | Default | Meaning                                              |
|-------------------------|---------|-------------------------------------------------------|
| `OMABLINKER_LED_DEVICE` | (unset) | sysfs brightness path of a real LED to blink as well  |
| `OMABLINKER_IDLE_MS`    | `120`   | Same idea as `idleTimeoutMs`, for the physical LED    |

Find real LED candidates with `ls /sys/class/leds/`.

## Troubleshooting

```
systemctl status omablinker       # is the daemon running?
journalctl -u omablinker -f       # attach errors, LED device errors, etc.
cat /run/omablinker/pulses.log    # should print a fresh "1"/"0" line per burst
```

If the widget's tooltip says the service isn't running, that's
`Service.qml` reporting that its `tail -F` on the pulse log has nothing to
follow — check the daemon first.

## Development

```
cd bpfd
cargo build --release   # builds omablinker-bpfd-ebpf first, then embeds it in omablinker-bpfd
cargo run -- --led-device /sys/class/leds/foo/brightness   # runs via `sudo -E`, see .cargo/config.toml
```

`omablinker-bpfd-ebpf/src/main.rs` is the whole BPF program — two
`#[tracepoint]` functions and one `PerCpuArray` map. `omablinker-bpfd/src/main.rs`
is the whole daemon: load, attach, poll, write the pulse log, optionally
drive a real LED, clean up on `SIGTERM`.

Before publishing changes, Omarchy's own plugin guidance applies here too:

```
omarchy plugin validate .
```

### Building the eBPF program

`bpf-linker` links against a specific LLVM major version, and LLVM's
bitcode format isn't stable across majors — if the pinned nightly's bundled
LLVM and your installed `bpf-linker`'s LLVM disagree, the build fails with
`ERROR llvm: Invalid record`. The pinned nightly (`nightly-2026-07-01`,
LLVM 22.1.8) was chosen to match Arch's `bpf-linker` package as of 2026-09;
see the comment at the top of `bpfd/rust-toolchain.toml` for how to re-pin
it if a `pacman -Syu` ever moves that package to a new LLVM major version.

## Why not just use the kernel's built-in `disk-activity` LED trigger?

`/sys/class/leds/<led>/trigger` already supports a `disk-activity` value on
kernels with an LED class device, and it's a fine choice if you only want to
blink real hardware. OmaBlinker exists for the general case — a bar
indicator, since most laptops have no user-controllable drive LED at all —
and because eBPF tracepoints give a single, filesystem-agnostic signal
that's easy to also mirror onto real hardware when one exists, rather than
depending on whichever driver happens to expose the trigger.

© 2026 Jay O ([@jayosays](https://x.com/jayosays)). Built with Claude.