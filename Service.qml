import QtQuick
import Quickshell.Io

// Headless half of the plugin. Doesn't touch eBPF itself — loading a BPF
// program needs root, and this runs inside the user's long-lived
// omarchy-shell process, so the actual tracepoint work happens in the
// privileged omablinker-bpfd systemd service (see bpfd/omablinker-bpfd).
// This just tails the world-readable pulse log that daemon writes and turns
// each line into a debounced "active" state for the bar widget.
Item {
  id: root

  readonly property string pulseLogPath: "/run/omablinker/pulses.log"

  property var shell: null
  property var settings: ({})
  property bool active: false
  property bool daemonSeen: false
  property string statusText: qsTr("Waiting for the omablinker eBPF service…")

  function configure(nextSettings) {
    settings = nextSettings || ({})
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, minimum, maximum) {
    var value = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(value)) value = fallback
    return Math.max(minimum, Math.min(maximum, value))
  }

  // How long the LED stays lit after the last observed block I/O event.
  // Short enough to flicker on scattered activity, long enough that a burst
  // reads as a steady glow rather than a strobe.
  readonly property int idleTimeoutMs: intSetting("idleTimeoutMs", 120, 40, 2000)

  function pulse() {
    daemonSeen = true
    active = true
    statusText = qsTr("Storage activity")
    idleTimer.restart()
  }

  function goIdle() {
    active = false
    statusText = daemonSeen
      ? qsTr("Idle")
      : qsTr("Waiting for the omablinker eBPF service…")
  }

  Timer {
    id: idleTimer
    interval: root.idleTimeoutMs
    repeat: false
    onTriggered: root.goIdle()
  }

  // omablinker-bpfd appends a line every time block I/O starts or stops being
  // observed. `tail -F` waits for the file to appear (it's created by the
  // system service, which may start after the shell) and follows it forever,
  // surviving log rotation/truncation.
  Process {
    id: tailProcess
    running: true
    command: ["tail", "-F", "-n0", root.pulseLogPath]
    stdout: SplitParser {
      onRead: function(data) { root.pulse() }
    }
    onExited: function(exitCode) {
      root.daemonSeen = false
      root.active = false
      root.statusText = qsTr("omablinker-bpfd is not running (see: systemctl status omablinker)")
      restartTimer.restart()
    }
  }

  Timer {
    id: restartTimer
    interval: 3000
    repeat: false
    onTriggered: tailProcess.running = true
  }
}
