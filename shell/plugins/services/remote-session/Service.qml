import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "RemoteSessionModel.js" as RemoteSessionModel

// Watches for gliff-server, the Hyprland remote desktop, so the machine being
// controlled can see that someone is on it: the RemoteSession bar indicator
// reads `active`, and a notification announces each session start and end.
Item {
  id: root

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  property bool stateLoaded: false
  property bool active: false
  property int sessions: 0
  property var peers: []

  property bool refreshPending: false

  function refresh() {
    if (statusProbe.running) {
      root.refreshPending = true
      return
    }
    root.refreshPending = false
    statusProbe.running = true
  }

  function applyProbe(text) {
    var state = RemoteSessionModel.stateFromOutput(text)
    var wasActive = root.active
    var announce = root.stateLoaded && state.active !== wasActive

    root.sessions = state.sessions
    root.peers = state.peers
    root.active = state.active
    root.stateLoaded = true

    if (announce) root.announce(state)
  }

  function announce(state) {
    var args = ["omarchy-notification-send", "-g", "󰢹"]
    if (state.active) {
      args.push("Remote session started", RemoteSessionModel.startedBody(state.peers))
    } else {
      args.push("Remote session ended", "The gliff connection to this screen closed.")
    }
    Quickshell.execDetached(args)
  }

  Component.onCompleted: refresh()

  // gliff-server captures the screen through ext-image-copy-capture, so every
  // session start and stop surfaces as a screencast event; the probe decides
  // whether it was gliff or another screencopy client.
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (RemoteSessionModel.isCaptureEvent(event ? event.name : "")) root.refresh()
    }
  }

  // Safety net while a session is active, in case a stop event is missed.
  Timer {
    interval: 15000
    repeat: true
    running: root.active
    onTriggered: root.refresh()
  }

  // Only this user's servers count: another account's session on the same
  // machine captures its own desktop, not this one.
  Process {
    id: statusProbe
    command: ["bash", "-c",
      'for pid in $(pgrep -x -u "$(id -u)" gliff-server); do ' +
      'peer=$(tr "\\0" "\\n" < "/proc/$pid/environ" 2>/dev/null | sed -n "s/^SSH_CONNECTION=\\([^ ]*\\).*/\\1/p"); ' +
      'printf "%s %s\\n" "$pid" "$peer"; ' +
      'done']
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyProbe(text)
    }
    onExited: function() {
      if (root.refreshPending) Qt.callLater(root.refresh)
    }
  }
}
