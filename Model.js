// Pure parsers for the backend CLI output. No shared mutable state: each
// call returns a fresh result object, so an instance per monitor cannot
// race with another one over a common singleton.
.pragma library

function parseStatus(raw) {
  var text = String(raw || "").trim()
  if (text === "") return null
  try {
    var o = JSON.parse(text)
    return {
      installed: !!o.installed,
      running: !!o.active,
      enabled: !!o.enabled,
      mode: String(o.mode || "proxy"),
      config: String(o.config || ""),
      configFile: String(o.configFile || ""),
      server: String(o.server || ""),
      exitIp: String(o.exitIp || ""),
      latencyMs: Number(o.latencyMs || 0),
      error: String(o.error || ""),
      profiles: Array.isArray(o.profiles) ? o.profiles.map(String) : [],
      activeProfile: String(o.activeProfile || ""),
      helperPresent: o.helperPresent !== false,
      deps: Array.isArray(o.deps) ? o.deps.map(function(d) {
        return { n: String(d.n || ""), ok: !!d.ok, h: String(d.h || "") }
      }) : []
    }
  } catch (e) {
    return null
  }
}

function parseTest(raw) {
  var text = String(raw || "").trim()
  if (text === "") return { ok: false, exitIp: "", latencyMs: 0 }
  try {
    var o = JSON.parse(text)
    if (o.ok && o.exitIp) {
      return { ok: true, exitIp: String(o.exitIp), latencyMs: Number(o.latencyMs || 0) }
    }
    return { ok: false, exitIp: "", latencyMs: 0 }
  } catch (e) {
    return { ok: false, exitIp: "", latencyMs: 0 }
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