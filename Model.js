.pragma library

var state = {
  installed: false,
  running: false,
  enabled: false,
  mode: "proxy",
  config: "",
  configFile: "",
  server: "",
  exitIp: "",
  latencyMs: 0,
  error: "",
  profiles: [],
  activeProfile: "",
  helperPresent: true,
  deps: []
}

function reset() {
  state.installed = false
  state.running = false
  state.enabled = false
  state.mode = "proxy"
  state.config = ""
  state.configFile = ""
  state.server = ""
  state.exitIp = ""
  state.latencyMs = 0
  state.error = ""
  state.profiles = []
  state.activeProfile = ""
  state.helperPresent = true
  state.deps = []
}

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") {
    reset()
    return false
  }
  try {
    var o = JSON.parse(text)
    state.installed = !!o.installed
    state.running = !!o.active
    state.enabled = !!o.enabled
    state.mode = String(o.mode || "proxy")
    state.config = String(o.config || "")
    state.configFile = String(o.configFile || "")
    state.server = String(o.server || "")
    state.exitIp = String(o.exitIp || "")
    state.latencyMs = Number(o.latencyMs || 0)
    state.error = String(o.error || "")
    state.profiles = Array.isArray(o.profiles) ? o.profiles.map(String) : []
    state.activeProfile = String(o.activeProfile || "")
    state.helperPresent = o.helperPresent !== false
    state.deps = Array.isArray(o.deps) ? o.deps.map(function(d) {
      return { n: String(d.n || ""), ok: !!d.ok, h: String(d.h || "") }
    }) : []
    return true
  } catch (e) {
    reset()
    state.error = "invalid status output"
    return false
  }
}

function parseTest(raw) {
  var text = String(raw || "").trim()
  if (text === "") {
    state.exitIp = ""
    state.latencyMs = 0
    return false
  }
  try {
    var o = JSON.parse(text)
    if (o.ok && o.exitIp) {
      state.exitIp = String(o.exitIp)
      state.latencyMs = Number(o.latencyMs || 0)
    } else {
      state.exitIp = ""
      state.latencyMs = 0
    }
    return !!o.ok
  } catch (e) {
    return false
  }
}

function parseProbe(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, ip: "", ms: 0, error: "" }
  try {
    var o = JSON.parse(text)
    return {
      ok: !!o.ok,
      ip: String(o.exitIp || ""),
      ms: Number(o.latencyMs || 0),
      error: String(o.error || "")
    }
  } catch (e) {
    return { ok: false, ip: "", ms: 0, error: "" }
  }
}