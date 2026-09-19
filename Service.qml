import QtQuick
import Quickshell.Io

// Headless half of the plugin. Doesn't touch eBPF itself — loading a BPF
// program needs root, and this runs inside the user's long-lived
// omarchy-shell process, so the actual tracepoint work happens in the
// privileged omablinker-bpfd systemd service (see bpfd/omablinker-bpfd).
// This watches the world-readable state files that daemon overwrites in
// place — one for combined activity, one each for read and write, and an
// optional fourth for cache-read pulses — and exposes each directly as a
// boolean. BarWidget.qml decides which of these to actually display, based
// on its own "Activity" (Combined/Read-Write) and "Cache-read LED" settings.
Item {
  id: root

  readonly property string stateDir: "/run/omablinker"

  property var shell: null
  property bool daemonSeen: false

  // Mirrors each state file directly rather than layering an independent
  // debounce on top of it: a real LED's brightness is just a direct
  // function of whether current is flowing right now, and the only reason
  // any hold-time exists at all is to stretch a single sub-millisecond
  // block request long enough for a human to see it — which the daemon
  // already does once, itself, for every channel. A second, disconnected
  // timer here doesn't make brief activity any more visible; it only risks
  // going dark mid-burst while real activity is still ongoing.
  FileView {
    id: combinedFile
    path: root.stateDir + "/state"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoadFailed: root.daemonSeen = false
  }
  readonly property string rawCombined: combinedFile.text()
  onRawCombinedChanged: root.daemonSeen = true
  readonly property bool combinedActive: daemonSeen && rawCombined.trim() === "1"

  FileView {
    id: readFile
    path: root.stateDir + "/state-read"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }
  readonly property string rawRead: readFile.text()
  readonly property bool readActive: daemonSeen && rawRead.trim() === "1"

  FileView {
    id: writeFile
    path: root.stateDir + "/state-write"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
  }
  readonly property string rawWrite: writeFile.text()
  readonly property bool writeActive: daemonSeen && rawWrite.trim() === "1"

  // Only exists if the daemon's cache-read kprobe attached (best-effort,
  // see omablinker-bpfd/src/main.rs) — a missing file just leaves
  // cacheReadActive false via onLoadFailed, same as any other absent state.
  FileView {
    id: cacheReadFile
    path: root.stateDir + "/state-cache-read"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoadFailed: root.cacheReadSeen = false
  }
  readonly property string rawCacheRead: cacheReadFile.text()
  onRawCacheReadChanged: root.cacheReadSeen = true
  property bool cacheReadSeen: false
  readonly property bool cacheReadActive: cacheReadSeen && rawCacheRead.trim() === "1"

  readonly property string statusText: daemonSeen
    ? qsTr("Watching block I/O")
    : qsTr("omablinker-bpfd not seen yet (see: systemctl status omablinker)")
}
