import QtQuick
import Quickshell

// Drives the real remote-session service against a stub gliff-server on PATH:
// idle at start, active with the ssh peer once a server runs, idle again after
// it exits, with a notification announcing each transition. The service is
// never refreshed by hand: a one-shot grim capture raises the same Hyprland
// screencast event that gliff-server does, so the event path is what gets
// exercised.
ShellRoot {
  id: root

  property string resultPath: Quickshell.env("OMARCHY_QML_TEST_RESULT")
  property string stubPidFile: Quickshell.env("OMARCHY_QML_TEST_STUB_PID")
  property var failures: []
  property var service: null

  function fail(message) {
    failures.push(String(message))
  }

  function assertTrue(condition, message) {
    if (!condition) fail(message)
  }

  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function writeResult() {
    var payload = JSON.stringify({ ok: failures.length === 0, failures: failures })
    Quickshell.execDetached(["bash", "-lc", "printf '%s' " + shellQuote(payload) + " > " + shellQuote(resultPath)])
  }

  function captureFrame() {
    Quickshell.execDetached(["grim", "-g", "0,0 1x1", Quickshell.env("OMARCHY_QML_TEST_FRAME")])
  }

  function step(delay, action) {
    var timer = Qt.createQmlObject("import QtQuick; Timer { repeat: false }", root)
    timer.interval = delay
    timer.triggered.connect(function() {
      action()
      timer.destroy()
    })
    timer.start()
  }

  Component.onCompleted: {
    var component = Qt.createComponent("file://" + Quickshell.env("OMARCHY_PATH") + "/shell/plugins/services/remote-session/Service.qml")
    if (component.status !== Component.Ready) {
      fail("remote session service failed to load: " + component.errorString())
      writeResult()
      return
    }
    service = component.createObject(root, { shell: null })
    if (!service) {
      fail("remote session service failed to instantiate: " + component.errorString())
      writeResult()
      return
    }

    step(600, function() {
      root.assertTrue(service.stateLoaded === true, "service probes on startup")
      root.assertTrue(service.active === false, "service starts idle without a gliff server")
      Quickshell.execDetached(["bash", "-c", "SSH_CONNECTION='10.0.0.5 51234 10.0.0.1 22' gliff-server --stdio & echo $! > " + root.shellQuote(root.stubPidFile)])
    })
    step(1200, function() { root.captureFrame() })
    step(1800, function() {
      root.assertTrue(service.active === true, "service reports an active session while gliff-server runs")
      root.assertTrue(service.sessions === 1, "service counts one session")
      root.assertTrue(JSON.stringify(service.peers) === JSON.stringify(["10.0.0.5"]), "service reports the ssh peer, got " + JSON.stringify(service.peers))
      Quickshell.execDetached(["bash", "-c", "kill \"$(cat " + root.shellQuote(root.stubPidFile) + ")\""])
    })
    step(2400, function() { root.captureFrame() })
    step(3000, function() {
      root.assertTrue(service.active === false, "service returns to idle once gliff-server exits")
      root.writeResult()
    })
  }
}
