// Hyprland emits these whenever a screencopy session starts or stops, which
// covers gliff-server (ext-image-copy-capture) as well as screen recorders
// and browser screen shares, so the event is only a cue to re-probe.
function isCaptureEvent(name) {
  var event = String(name || "")
  return event === "screencast" || event === "screencastv2"
}

// Parses the probe output: one "<pid> [peer]" line per running gliff-server,
// where peer is the ssh client address when the server was spawned over ssh.
function stateFromOutput(text) {
  var lines = String(text || "").split("\n")
  var sessions = 0
  var peers = []
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].trim().split(/\s+/)
    if (parts[0] === "") continue
    sessions++
    var peer = parts[1] || ""
    if (peer !== "" && peers.indexOf(peer) === -1) peers.push(peer)
  }
  return { active: sessions > 0, sessions: sessions, peers: peers }
}

function peerSummary(peers) {
  var list = Array.isArray(peers) ? peers : []
  return list.length > 0 ? " from " + list.join(", ") : ""
}

function activeTooltip(peers) {
  return "Remote session" + peerSummary(peers)
}

function startedBody(peers) {
  return "Someone is viewing and controlling this screen" + peerSummary(peers) + " through gliff."
}

if (typeof module !== "undefined") {
  module.exports = {
    isCaptureEvent: isCaptureEvent,
    stateFromOutput: stateFromOutput,
    peerSummary: peerSummary,
    activeTooltip: activeTooltip,
    startedBody: startedBody
  }
}
