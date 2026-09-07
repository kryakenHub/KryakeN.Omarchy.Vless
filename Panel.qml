import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// VLESS VPN control panel: status, profiles, mode (proxy/system),
// start/stop, autostart, connection test and logs.
Panel {
  id: root
  moduleName: "kryaken.omarchy.vless"
  manageIpc: false

  component SmallBtn: Rectangle {
    property string label: ""
    property var onTap: null
    property color fg: Color.foreground
    property color dim: Qt.darker(fg, 1.4)

    property string _flashLabel: ""
    property bool _flashing: false
    property int _flashMs: 1100

    function flash(text) {
      _flashLabel = text
      _flashing = true
      flashTimer.restart()
    }

    Timer {
      id: flashTimer
      interval: _flashMs
      repeat: false
      onTriggered: { _flashing = false; _flashLabel = "" }
    }

    implicitWidth: Math.max(24, textItem.implicitWidth + 12)
    implicitHeight: Style.space(20)
    Layout.alignment: Qt.AlignVCenter
    radius: 2
    color: !enabled
      ? Qt.rgba(dim.r, dim.g, dim.b, 0.05)
      : (_flashing ? Qt.rgba(fg.r, fg.g, fg.b, 0.22) : Qt.rgba(fg.r, fg.g, fg.b, 0.06))
    border.color: !enabled
      ? Qt.rgba(dim.r, dim.g, dim.b, 0.15)
      : (_flashing ? fg : Qt.rgba(dim.r, dim.g, dim.b, 0.3))
    border.width: 1

    Text {
      id: textItem
      anchors.centerIn: parent
      text: parent._flashing ? parent._flashLabel : parent.label
      color: parent.enabled ? parent.fg : parent.dim
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      enabled: parent.enabled
      onClicked: { if (parent.onTap) parent.onTap() }
    }
  }

  component ModeCard: Rectangle {
    property string label: ""
    property string captionText: ""
    property bool active: false
    property bool busy: false
    // `warm` is true while the tunnel is running: the active card then
    // uses the accent (green) hue, otherwise it falls back to foreground.
    property bool warm: false
    property color accent: Color.foreground
    property color fg: Color.foreground
    property color dim: Qt.darker(fg, 1.4)
    property var onTap: null

    Layout.fillWidth: true
    Layout.minimumWidth: 100
    Layout.preferredHeight: Style.space(44)
    radius: 2
    color: active
      ? Qt.rgba((warm ? accent : fg).r, (warm ? accent : fg).g, (warm ? accent : fg).b, 0.12)
      : Qt.rgba(fg.r, fg.g, fg.b, 0.04)
    border.color: active
      ? Qt.rgba((warm ? accent : dim).r, (warm ? accent : dim).g, (warm ? accent : dim).b, 0.55)
      : Qt.rgba(dim.r, dim.g, dim.b, 0.2)
    border.width: 1

    MouseArea {
      anchors.fill: parent
      enabled: !busy
      onClicked: { if (onTap) onTap() }
    }

    Column {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.margins: Style.space(8)
      spacing: Style.space(1)

      Text {
        text: label
        font.family: Style.font.family
        font.pixelSize: Style.font.body
        font.bold: active
        color: fg
      }

      Text {
        text: captionText
        elide: Text.ElideRight
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        color: dim
      }
    }
  }

  property var anchorItem: null
  property var hostWidget: null

  readonly property string serviceName: "xray-vpn"

  // Constant switch geometry mirroring ToggleSwitch's rest-state rule
  // (trackHeight 22, trackWidth x1.9, cursorPad 6 per side) so the knob does
  // not wobble when `busy` flips `interactive` and the cursor ring collapses.
  readonly property int _switchW: Math.round(Math.max(22, Math.round(Style.spacing.controlHeight * 0.55)) * 1.9) + Style.space(12)
  readonly property int _switchH: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55)) + Style.space(12)

  // QML-notifyable mirrors of the backend state (the backend mutates a plain
  // JS object that emits no signals, so we copy into real properties).
  property bool _installed: false
  property bool _running: false
  property bool _enabled: false
  property string _mode: "proxy"
  property string _config: ""
  property string _configFile: ""
  property string _server: ""
  property string _exitIp: ""
  property int _latencyMs: 0
  property string _error: ""
  // True right after the user taps the error banner to copy it: the banner
  // briefly shows "Copied ✓" instead of the error text (never overlapping).
  property bool _errorFlash: false
  // When non-empty, tapping the error banner copies THIS command instead of
  // the raw error text (set for errors caused by missing dependencies, so a
  // tap pastes the install command that fixes them).
  property string _errorCopyCommand: ""
  property var _profiles: []
  property string _activeProfile: ""
  property var _deps: []
  property bool _helperPresent: true
  property string profileMsg: ""
  // Профиль-сообщение: success = зелёный, ошибка = красный (см. рендеринг).
  property bool profileMsgIsError: false
  // Профиль, чей "×" сейчас в стадии подтверждения (двухшаговое удаление).
  property string _deleteArmed: ""
  // True while a profile probe is in flight (runs via the serve helper).
  property bool _probing: false
  // Статус-сообщение (probe / операции с профилями) исчезает само через 5 с.
  Timer {
    id: profileMsgDismiss
    interval: 5000
    onTriggered: root.profileMsg = ""
  }
  onProfileMsgChanged: {
    if (root.profileMsg !== "") profileMsgDismiss.restart()
  }
  // Последняя ошибка (serve/status) показывается достаточно долго, чтобы её
  // можно было прочитать, прежде чем она пропадёт.
  Timer {
    id: errorDismiss
    interval: 9000
    onTriggered: if (!root._persistError) { root._error = ""; root._errorCopyCommand = "" }
  }
  // "Copied ✓" flash when the user taps the error banner to copy it (replaces
  // the error text briefly so the two never overlap).
  Timer {
    id: errCopyHint
    interval: 1200
    onTriggered: root._errorFlash = false
  }
  // TextInput содержимое (ids дочерних полей не резолвятся из root-скоупа —
  // грузим значение в свойство и читаем его).
  property string _addInput: ""
  property string _addName: ""
  property bool _clearAddOnSuccess: false

  // Privileged ops run through a single per-session serve process (pkexec once
  // per login; every request is then answered over its stdin/stdout, so no
  // password prompt per toggle). Requests are serialised server-side; replies
  // carry the request id and are routed back to per-request callbacks.
  property int _serveInFlight: 0
  property var _serveQueue: []
  property int _serveSeq: 0
  property bool _serveUp: false

  readonly property bool isRunning: root._running
  readonly property bool isEnabled: root._enabled
  readonly property bool isInstalled: root._installed
  readonly property bool isSystemMode: root._mode === "system"
  readonly property string mode: root._mode
  readonly property string configPath: root._config
  readonly property string server: root._server
  readonly property string exitIp: root._exitIp
  readonly property int latencyMs: root._latencyMs
  readonly property string lastError: root._error
  readonly property bool isBusy: root._serveInFlight > 0 || testProcess.running
  readonly property bool isTesting: testProcess.running
  readonly property bool isProbing: root._probing

  readonly property color foregroundColor: root.bar && root.bar.foreground !== undefined ? root.bar.foreground : Color.foreground
  readonly property color dimColor: Qt.darker(root.foregroundColor, 1.4)

  // WCAG-safe accents: picked per the panel surface luminance so the color is
  // readable both on dark (>=4.5:1 as text, >=3:1 for the active border) and
  // on light themes. The old fixed greens/reds failed AA on #05182e (red text
  // 4.28:1, active border 2.68:1).
  readonly property color panelBackground: Color.popups.background
  readonly property color accentPass: root._bgIsDark ? "#34D399" : "#065F46"
  readonly property color accentDanger: root._bgIsDark ? "#F87171" : "#B91C1C"
  readonly property color accentColor: root.isRunning ? root.accentPass : root.accentDanger
  // True while the banner shows the backend's "no profiles" error: the whole
  // Profiles block (heading, hint, add-field borders, "+ Add") highlights in
  // the same red so the cause and its fix path are visually linked.
  readonly property bool noProfilesError: root._error.indexOf("error: no profiles") === 0
  readonly property color noProfilesSoft: Qt.alpha(root.accentDanger, 0.55)
  readonly property string panelFont: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property string daemonScriptPath:
    Qt.resolvedUrl("backend.sh").toString().replace(/^file:\/\//, "")

  // Root-owned copy installed by ensure_install(); used for all pkexec
  // invocations so we never re-execute a user-writable script as root.
  readonly property string privilegedScriptPath: "/etc/xray-vpn/backend.sh"

  // Reviewed-artifact pins for THIS release — the exact sha256 of backend.sh
  // and factory.py committed in SHA256SUMS.txt at the same commit as this QML.
  // The panel verifies the user-writable plugin checkout against these BEFORE
  // crossing the privilege boundary (first-install bootstrap), so a tampered
  // script or a missing/mismatched manifest never gets to run as root.
  readonly property string pinBackendSha256: "5cd8d42cb61ed7d37dc1ebb634708ab916eda1a5b84d21d017db4ef25f4fff02"
  readonly property string pinFactorySha256: "3bad24d106b3f03d14054d6dd6b4a9217c9b1d2d0a7c9c214f266d6b1d44d337"

  // Absolute path of a file co-located with this Panel.qml inside the
  // user-writable plugin checkout (used for unprivileged pin verification).
  function _checkoutAbs(file) {
    return Qt.resolvedUrl(file).toString().replace(/^file:\/\//, "")
  }

  // Friendly guidance shown when the privileged helper file disappears while
  // a serve session is running (the user deleted /etc/xray-vpn mid-session).
  // For the first-install case the panel auto-installs via pkexec instead.
  readonly property string msgHelperMissing:
    "VPN backend was removed while running. Run \"" +
    root.installCommand + "\""

  // Copy-pasteable commands for onboarding (shown while a dependency is
  // missing): install a package, or re-validate the whole setup in a terminal.
  readonly property string doctorCommand:
    "bash ~/.config/omarchy/plugins/" + root.moduleName + "/backend.sh doctor"

  // The command that (re)creates /etc/xray-vpn. On first use the panel
  // auto-triggers this via pkexec; this string is shown only as fallback
  // guidance (e.g. if auto-install fails or the helper disappears mid-session).
  readonly property string installCommand:
    "sudo bash ~/.config/omarchy/plugins/" + root.moduleName +
    "/backend.sh install && omarchy restart shell"

  readonly property string statusMeta:
    !root.isInstalled
      ? "Not installed"
      : root.lastError !== ""
        ? "Error"
        : (root.isRunning
            ? (root.isSystemMode ? "System · Active" : "Proxy · Active")
            : (root.isSystemMode ? "System · Standby" : "Proxy · Standby"))

  // True while a pkexec install bootstrap is in flight (fresh install or
  // re-provision after /etc/xray-vpn was deleted).
  property bool _bootstrapInFlight: false
  // Callback slot for toolProc (single-shot unprivileged runner).
  property var _toolCb: null
  // True while the "VPN backend missing" notice must stay on screen instead of
  // auto-fading: it is cleared only once the helper files actually reappear.
  property bool _persistError: false

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // WCAG 2.x relative luminance of a color (RGB components are 0..1 floats).
  function _relLuminance(c) {
    function chan(v) {
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * chan(c.r) + 0.7152 * chan(c.g) + 0.0722 * chan(c.b)
  }

  readonly property bool _bgIsDark: root._relLuminance(root.panelBackground) < 0.5

  // Interval for the status poll, re-read from settings on every tick so a
  // changed refreshIntervalSec takes effect without a shell restart.
  function refreshIntervalMs() {
    var sec = parseInt(root.setting("refreshIntervalSec", 5), 10)
    if (!isFinite(sec) || sec < 1) sec = 5
    return sec * 1000
  }

  function _stringsEqual(a, b) {
    if (a === b) return true
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
  }

  function _depsEqual(a, b) {
    if (a === b) return true
    if (!a || !b || a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) {
      if (a[i].n !== b[i].n || a[i].ok !== b[i].ok || a[i].h !== b[i].h) return false
    }
    return true
  }

  // Apply a parsed status object. Arrays are only reassigned when their
  // contents actually change; keeping the same reference lets QML model
  // bindings (ListView/Repeater) reuse existing delegates instead of tearing
  // them down and rebuilding every poll tick.
  function _applyStatus(st, errMsg) {
    if (st === null) {
      root._installed = false
      root._running = false
      root._enabled = false
      root._mode = "proxy"
      root._config = ""
      root._configFile = ""
      root._server = ""
      root._exitIp = ""
      root._latencyMs = 0
      // A failed poll says nothing about the helper's presence: leave
      // _helperPresent untouched so a status timeout cannot trigger a needless
      // pkexec bootstrap (matches the old reset() semantics).
      if (errMsg) {
        root._error = errMsg
        root._errorCopyCommand = ""
      }
      if (root._profiles.length > 0) root._profiles = []
      root._activeProfile = ""
      if (root._deps.length > 0) root._deps = []
      return
    }
    root._installed = st.installed
    root._running = st.running
    root._enabled = st.enabled
    root._mode = st.mode
    root._config = st.config
    root._configFile = st.configFile
    root._server = st.server
    root._exitIp = st.exitIp
    root._latencyMs = st.latencyMs
    root._helperPresent = st.helperPresent
    // The "helper missing" notice is persistent: clear it only once the
    // backend files are actually present again.
    if (root._persistError && root._helperPresent) {
      root._persistError = false
      root._error = ""
      root._errorCopyCommand = ""
    }
    // Only surface a status-borne error; never clear an error that is still
    // being shown (e.g. the helper-missing notice) just because the status
    // poll reports no error. The active error fades via errorDismiss.
    if (st.error !== "") {
      root._error = st.error
      root._errorCopyCommand = ""
    }
    if (!root._stringsEqual(root._profiles, st.profiles)) root._profiles = st.profiles
    root._activeProfile = st.activeProfile
    var missing = []
    for (var di = 0; di < st.deps.length; di++) {
      if (!st.deps[di].ok) missing.push(st.deps[di])
    }
    if (!root._depsEqual(root._deps, missing)) root._deps = missing
  }

  function _serveEnqueue(args, okCb, errCb) {
    var item = { args: args, ok: okCb, err: errCb, id: root._serveSeq++ }
    root._serveQueue.push(item)
    root._serveInFlight = root._serveQueue.length
    serveGuard.restart()
    if (root._serveUp && serveProcess.running) {
      serveProcess.write(JSON.stringify({ id: item.id, args: item.args }) + "\n")
    } else {
      root._serveEnsure()
    }
  }

  // Runs a single unprivileged external tool and reports its stdout once.
  // Serialized through toolProc; used only for the pre-pkexec pin check.
  function _runTool(tool, path, cb) {
    root._toolCb = cb
    toolProc.command = [tool, path]
    toolProc.running = true
  }

  // Fail-closed pre-flight gate for the FIRST-install bootstrap. Hashes the
  // user-writable checkout's backend.sh/factory.py and reads SHA256SUMS.txt,
  // comparing everything against the hashes pinned in this QML (the reviewed
  // release). Missing file, missing manifest or any mismatch => pb(false):
  // the unverified checkout is never executed as root. cb(passed: bool).
  function _checkoutPinned(cb) {
    var steps = [
      { tool: "/usr/bin/sha256sum", file: "backend.sh", field: "backend" },
      { tool: "/usr/bin/sha256sum", file: "factory.py", field: "factory" },
      { tool: "/usr/bin/cat", file: "SHA256SUMS.txt", field: "manifest" }
    ]
    var idx = 0
    var res = {}
    function next() {
      if (idx >= steps.length) {
        var backendOk = res.backend === root.pinBackendSha256
        var factoryOk = res.factory === root.pinFactorySha256
        var manifestOk = typeof res.manifest === "string" &&
          res.manifest.indexOf(root.pinBackendSha256 + "  backend.sh") >= 0 &&
          res.manifest.indexOf(root.pinFactorySha256 + "  factory.py") >= 0
        cb(backendOk && factoryOk && manifestOk)
        return
      }
      var s = steps[idx++]
      root._runTool(s.tool, root._checkoutAbs(s.file), function(out) {
        var text = String(out)
        if (s.tool === "/usr/bin/sha256sum") {
          var m = /^([0-9a-f]{64})(?:\s+|$)/.exec(text.trim())
          res[s.field] = m ? m[1] : ""
        } else {
          res[s.field] = text
        }
        next()
      })
    }
    next()
  }

  function _serveEnsure() {
    if (serveProcess.running) return
    if (root._helperPresent) {
      root._bootstrapInFlight = false
      serveProcess.command = ["pkexec", root.privilegedScriptPath, "serve"]
      serveProcess.running = true
    } else if (!root._bootstrapInFlight) {
      root._bootstrapInFlight = true
      root._checkoutPinned(function(passed) {
        if (!passed) {
          // Fail closed at the privilege boundary: the writeable checkout does
          // not match the reviewed release (tampered/missing artifact or
          // manifest) — never execute it as root.
          root._bootstrapInFlight = false
          root._persistError = true
          root._error = "install blocked: plugin files do not match the released version (reinstall the plugin from the store)"
          root._errorCopyCommand = ""
          return
        }
        root._error = "Installing VPN backend..."
        root._errorCopyCommand = ""
        root._persistError = false
        bootProc.command = ["pkexec", root.daemonScriptPath, "install"]
        bootProc.running = true
      })
    }
  }

  function _serveFlush() {
    for (var i = 0; i < root._serveQueue.length; i++) {
      serveProcess.write(JSON.stringify({ id: root._serveQueue[i].id, args: root._serveQueue[i].args }) + "\n")
    }
  }

  function _serveLine(raw) {
    var text = String(raw || "").trim()
    if (text === "") return
    var o = null
    try { o = JSON.parse(text) } catch (e) {
      console.log("[kryaken.omarchy.vless] bad serve reply: " + text)
      return
    }
    var idx = -1
    for (var i = 0; i < root._serveQueue.length; i++) {
      if (root._serveQueue[i].id === o.id) { idx = i; break }
    }
    serveGuard.stop()
    if (idx < 0) {
      console.log("[kryaken.omarchy.vless] serve reply for unknown id " + o.id)
      return
    }
    // Heartbeat (code -1): the helper acknowledged the request and is still
    // processing it. Restart the watchdog and keep the item queued; the final
    // reply arrives separately.
    if (o.code === -1) {
      serveGuard.restart()
      return
    }
    var item = root._serveQueue.splice(idx, 1)[0]
    root._serveInFlight = root._serveQueue.length
    if (o.code === 0) {
      if (item.ok) item.ok(String(o.out || ""), String(o.err || ""), Number(o.code))
    } else {
      var serr = String(o.err || "")
      // A live serve helper whose backend.sh disappeared returns a friendly
      // marker instead of the raw '[Errno 2]' python trace.
      if (serr.indexOf("KRYAKEN_HELPER_MISSING") >= 0) {
        root._serveUp = false
        root._persistError = true
        serveProcess.running = false
        serr = root.msgHelperMissing
        console.log("[kryaken.omarchy.vless] helper missing during serve")
      }
      if (item.err) item.err(Number(o.code), String(o.out || ""), serr)
      else if (item.ok) item.ok(String(o.out || ""), serr, Number(o.code))
    }
  }

  function _serveFailAll(reason, persist) {
    serveGuard.stop()
    root._serveUp = false
    if (persist) root._persistError = true
    var q = root._serveQueue.splice(0, root._serveQueue.length)
    root._serveInFlight = root._serveQueue.length
    for (var i = 0; i < q.length; i++) {
      if (q[i].err) q[i].err(1, "", reason)
    }
  }

  function refreshStatus() {
    if (statusProcess.running || root._serveInFlight > 0) return
    statusProcess.command = [root.daemonScriptPath, "status"]
    statusProcess.running = true
    statusGuard.restart()
  }

  function toggleDaemon() {
    if (root.isBusy) return
    // Turning the VPN on with unmet dependencies would fail deep in the helper
    // with a bare "start failed". Prevent it up front with an actionable error:
    // it names the missing packages and tapping the banner copies the install
    // command (e.g. "yay -S xray-bin").
    if (!root._running && root._deps.length > 0) {
      var miss = []
      var cmds = []
      for (var i = 0; i < root._deps.length; i++) {
        miss.push(root._deps[i].n + " packet")
        if (root._deps[i].h !== "") cmds.push(root._deps[i].h)
      }
      root._errorCopyCommand = cmds.join(" && ")
      root._error = "missing " + miss.join(", ") + ", click to copy install command"
      errorDismiss.restart()
      return
    }
    root._serveEnqueue(["toggle"],
      function() { root._error = ""; root._errorCopyCommand = ""; root.refreshStatus() },
      function(code, out, err) {
        // Backend dependency errors print the banner text to stderr and the
        // exact install command to stdout (out), which is never rendered: the
        // banner shows only lastError, so tapping it copies just the command.
        root._error = (err || "toggle failed").trim()
        root._errorCopyCommand = (out || "").trim()
        if (root._error !== "") errorDismiss.restart()
      })
  }

  function setMode(m) {
    if (root.isBusy || root.mode === m) return
    // Optimistic: the next status poll reconciles with reality on failure.
    root._mode = m
    root._serveEnqueue(["mode", m],
      function() { root._error = ""; root._errorCopyCommand = ""; root.refreshStatus() },
      function(code, out, err) {
        root._error = (err || "mode change failed").trim()
        root._errorCopyCommand = ""
        if (root._error !== "") errorDismiss.restart()
      })
  }

  function setAutostart(on) {
    if (root.isBusy) return
    root._enabled = on
    root._serveEnqueue([on ? "enable" : "disable"],
      function() { root._error = ""; root._errorCopyCommand = ""; root.refreshStatus() },
      function(code, out, err) {
        root._error = (err || "autostart change failed").trim()
        root._errorCopyCommand = ""
        if (root._error !== "") errorDismiss.restart()
      })
  }

  function runTest() {
    if (!root.isRunning || testProcess.running) return
    root._exitIp = ""
    root._latencyMs = 0
    testProcess.command = [root.daemonScriptPath, "test"]
    testProcess.running = true
    testGuard.restart()
  }

  function addProfile() {
    var input = root._addInput
    if (input === "" || root.isBusy) return
    root.profileMsg = ""
    root.profileMsgIsError = false
    root._clearAddOnSuccess = true
    // The vless:// link / JSON contains the UUID and keys: deliver it to the
    // privileged helper over its stdin (unshift-secret), never in argv where
    // it would be visible in the process table.
    root._serveEnqueue(["unshift-secret", input], function() {})
    root._serveEnqueue(["profiles", "add", root._addName],
      function(out, err, code) {
        var n = (out !== "" ? out : root._addName).trim()
        if (n === "") n = "profile"
        root.profileMsg = "\"" + n + "\" added"
        root.profileMsgIsError = false
        if (root._clearAddOnSuccess) { root._addInput = ""; root._addName = "" }
        root._clearAddOnSuccess = false
        console.log("[kryaken.omarchy.vless] profiles add: out=" + out + " err=" + err)
        root.refreshStatus()
      },
      function(code, out, err) {
        root.profileMsg = (err || out || "profile operation failed").trim()
        root.profileMsgIsError = true
        root._clearAddOnSuccess = false
        console.log("[kryaken.omarchy.vless] profiles add failed: rc=" + code + " out=" + out + " err=" + err)
        root.refreshStatus()
      })
  }

  function selectProfile(name) {
    if (root.isBusy) return
    root._deleteArmed = ""
    root.profileMsg = ""
    root.profileMsgIsError = false
    root._clearAddOnSuccess = false
    root._serveEnqueue(["profiles", "select", name],
      function(out, err, code) {
        if (out !== "") { root.profileMsg = out; root.profileMsgIsError = false }
        root.refreshStatus()
      },
      function(code, out, err) {
        root.profileMsg = (err || out || "profile operation failed").trim()
        root.profileMsgIsError = true
        root.refreshStatus()
      })
  }

  // Two-step delete: the first tap arms the "×" as "Sure?" (auto-disarms
  // after a few seconds); the second tap really removes the profile, so an
  // irreversible delete can never be triggered by a single misclick.
  function requestRemoveProfile(name) {
    if (root.isBusy) return
    if (root._deleteArmed === name) {
      root._deleteArmed = ""
      disarmDelete.stop()
      root.removeProfile(name)
    } else {
      root._deleteArmed = name
      disarmDelete.restart()
    }
  }

  Timer {
    id: disarmDelete
    interval: 3000
    onTriggered: root._deleteArmed = ""
  }

  function removeProfile(name) {
    if (root.isBusy) return
    root._deleteArmed = ""
    // Удаление ресурса всегда показываем красным (необратимо), как в zapret.
    root.profileMsg = ""
    root.profileMsgIsError = true
    root._clearAddOnSuccess = false
    root._serveEnqueue(["profiles", "remove", name],
      function(out, err, code) {
        root.profileMsg = "\"" + name.trim() + "\" removed"
        root.profileMsgIsError = true
        root.refreshStatus()
      },
      function(code, out, err) {
        root.profileMsg = (err || out || "profile operation failed").trim()
        root.profileMsgIsError = true
        root.refreshStatus()
      })
  }

  function probeProfile(name) {
    if (root.isBusy) return
    root._deleteArmed = ""
    // Probe must read the profile (mode 0600, root-only) and launch its own
    // temporary xray, so it runs through the privileged serve helper rather
    // than an unprivileged backend.sh that cannot open the profile.
    root.profileMsg = "Probing " + name + "…"
    root.profileMsgIsError = false
    root._probing = true
    root._serveEnqueue(["probe", name],
      function(out, err, code) {
        root._probing = false
        var p = Model.parseProbe(out)
        if (p.ok && p.ip !== "") {
          root.profileMsg = "Probe ok · " + p.ip + (p.ms > 0 ? " · " + p.ms + "ms" : "")
          root.profileMsgIsError = false
        } else {
          root.profileMsg = p.error || "Probe failed"
          root.profileMsgIsError = true
        }
        root.refreshStatus()
      },
      function(code, out, err) {
        root._probing = false
        root.profileMsg = (err || out || "probe failed").trim()
        root.profileMsgIsError = true
        root.refreshStatus()
      })
  }

  function open() {
    root.controller.show()
    root.refreshStatus()
  }

  function close() { root.controller.hide() }

  function toggle() {
    if (root.opened) root.close()
    else root.open()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function") {
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    }
    return false
  }

  Component.onCompleted: {
    console.log("[kryaken.omarchy.vless] completed: testProcess=" + testProcess + " statusProcess=" + statusProcess + " isTesting=" + root.isTesting)
    root.refreshStatus()
  }

  // Status poll. Always running so the (always-visible) bar icon stays honest
  // about external changes; the cadence degrades to >=20s while the panel is
  // closed and snaps back to the configured interval on open. The interval is
  // a declarative binding on `opened`, so no imperative interval writes are
  // needed and a changed refreshIntervalSec is picked up on the next
  // open/close toggle (no shell restart required).
  Timer {
    id: statusTimer
    interval: root.opened ? root.refreshIntervalMs() : Math.max(root.refreshIntervalMs(), 20000)
    running: true
    repeat: true
    onTriggered: {
      if (!root.isBusy) root.refreshStatus()
    }
  }

  property string _statusOutput: ""
  property string _statusError: ""

  Process {
    id: statusProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
      onStreamFinished: root._statusOutput = text
    }
    stderr: StdioCollector {
      id: statusStderr
      waitForEnd: true
      onStreamFinished: root._statusError = text
    }
    onExited: function(exitCode) {
      var out = String(statusStdout.text || root._statusOutput || "")
      var err = String(statusStderr.text || root._statusError || "")
      statusGuard.stop()
      if (exitCode === 0 && out.length > 0) {
        root._applyStatus(Model.parseStatus(out))
      } else {
        root._applyStatus(null, (err || "status failed").trim())
      }
    }
  }

  property string _testOutput: ""

  Process {
    id: testProcess
    running: false
    command: []
    stdout: StdioCollector {
      id: testStdout
      waitForEnd: true
      onStreamFinished: root._testOutput = text
    }
    onExited: function(exitCode) {
      testGuard.stop()
      var out = String(testStdout.text || root._testOutput || "")
      var res = Model.parseTest(out)
      if (exitCode === 0 && res.ok) {
        root._exitIp = res.exitIp
        root._latencyMs = res.latencyMs
        root._error = ""
        root._errorCopyCommand = ""
      } else {
        root._exitIp = ""
        root._latencyMs = 0
        if (exitCode !== 0 || out.indexOf('"ok":false') >= 0) {
          root._error = "Connection test failed"
          root._errorCopyCommand = ""
        }
      }
    }
  }


  // Watchdogs: if a backend process never terminates (polkit/systemd stall
  // during shell load), abort it so polling and toggles recover.
  Timer {
    id: statusGuard
    interval: 12000
    repeat: false
    onTriggered: {
      if (statusProcess.running) {
        console.log("[kryaken.omarchy.vless] status watchdog: aborting stuck status process")
        statusProcess.running = false
        root._error = "status timeout"
        root._errorCopyCommand = ""
      }
    }
  }

  Timer {
    id: testGuard
    interval: 15000
    repeat: false
    onTriggered: {
      if (testProcess.running) {
        console.log("[kryaken.omarchy.vless] test watchdog: aborting stuck test process")
        testProcess.running = false
      }
    }
  }

  Process {
    id: serveProcess
    running: false
    stdinEnabled: true
    command: []
    stdout: SplitParser {
      splitMarker: "\n"
      onRead: function(data) { root._serveLine(data) }
    }
    stderr: StdioCollector { id: serveStderr }
    onStarted: {
      console.log("[kryaken.omarchy.vless] serve up")
      root._serveUp = true
      root._serveFlush()
      serveGuard.restart()
    }
    onExited: function(exitCode) {
      root._serveUp = false
      var stderr = String(serveStderr.text || "").trim()
      root._serveFailAll("privilege helper exited (" + exitCode + ")" + (stderr ? ": " + stderr : ""))
      console.log("[kryaken.omarchy.vless] serve exited: " + exitCode + " stderr=" + stderr)
    }
  }

  // One-shot bootstrap: provisions /etc/xray-vpn/backend.sh + factory.py from
  // the plugin checkout via the plugin's own `install` command (pkexec).
  // After success, immediately starts the serve process (no shell restart).
  Process {
    id: bootProc
    running: false
    command: []
    stdout: StdioCollector { id: bootStdout; waitForEnd: true }
    stderr: StdioCollector { id: bootStderr; waitForEnd: true }
    onStarted: { console.log("[kryaken.omarchy.vless] bootstrap install up") }
    onExited: function(exitCode) {
      root._bootstrapInFlight = false
      var err = String(bootStderr.text || "")
      if (exitCode === 0) {
        console.log("[kryaken.omarchy.vless] bootstrap install ok")
        root._error = ""
        root._errorCopyCommand = ""
        root._persistError = false
        root.refreshStatus()
        // Helper was just installed — start serve directly instead of
        // re-entering _serveEnsure() which would re-check the still-stale
        // _helperPresent and trigger a second pkexec.
        serveProcess.command = ["pkexec", root.privilegedScriptPath, "serve"]
        serveProcess.running = true
      } else {
        console.log("[kryaken.omarchy.vless] bootstrap install failed rc=" + exitCode + " err=" + err)
        root._serveFailAll("privilege helper setup failed (" + exitCode + "): " + err, true)
      }
    }
  }

  // Unprivileged single-shot runner used ONLY by _runTool/_checkoutPinned for
  // the pre-pkexec pin check. Never runs as root: it only hashes and reads the
  // plugin checkout, cross-checking it against the pinned reviewed release.
  Process {
    id: toolProc
    running: false
    command: []
    stdout: StdioCollector { id: toolStdout; waitForEnd: true }
    stderr: StdioCollector { id: toolStderr; waitForEnd: true }
    onExited: function() {
      var cb = root._toolCb
      root._toolCb = null
      if (cb) cb(String(toolStdout.text || ""))
    }
  }

  Timer {
    id: serveGuard
    interval: 120000
    repeat: false
    onTriggered: {
      if (serveProcess.running) {
        console.log("[kryaken.omarchy.vless] serve watchdog: restarting stuck helper")
        serveProcess.running = false
      } else {
        root._serveFailAll("privilege helper did not start")
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight + Style.space(24))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === " " || t === "t" || t === "T") root.toggleDaemon()
        else if (t === "s" || t === "S") root.refreshStatus()
        else if (t === "m" || t === "M") root.setMode(root.isSystemMode ? "proxy" : "system")
      }

      Column {
        id: mainColumn
        width: parent.width - Style.space(16)
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        anchors.topMargin: Style.space(8)
        spacing: Style.space(12)

        RowLayout {
          width: parent.width
          spacing: Style.space(12)

          Column {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(2)

            Text {
              text: "VLESS VPN"
              font.family: root.panelFont
              font.pixelSize: Style.font.title
              font.bold: true
              color: root.foregroundColor
            }

            Text {
              text: root.statusMeta.toUpperCase()
              elide: Text.ElideRight
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              color: root.dimColor
            }
          }

          ToggleSwitch {
            checked: root.isRunning
            busy: root.isBusy
            accent: root.accentColor
            foreground: root.foregroundColor
            onToggled: root.toggleDaemon()
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: root._switchW
            Layout.preferredHeight: root._switchH
          }
        }

        Column {
          id: setupCol
          width: parent.width
          spacing: Style.space(4)
          visible: root._deps.length > 0

          Text {
            text: "REQUIRED SETUP"
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            color: root.dimColor
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            color: root.dimColor
            text: "Install the missing dependencies, then copy and run the validation command (or press Check)."
          }

          ListView {
            width: parent.width
            // Bounded so the panel cannot grow past the screen; scrolls
            // internally with more than ~4 missing deps.
            height: Math.min(root._deps.length * Style.space(24), Style.space(96))
            spacing: Style.space(2)
            clip: true
            interactive: true
            model: root._deps
            delegate: RowLayout {
              required property var modelData
              width: ListView.view.width
              height: Style.space(22)
              spacing: Style.space(6)

              Text {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                text: "• " + modelData.n
                elide: Text.ElideRight
                font.family: root.panelFont
                font.pixelSize: Style.font.body
                color: root.foregroundColor
              }

              SmallBtn {
                id: copyDepBtn
                label: "Copy"
                fg: root.foregroundColor
                dim: root.dimColor
                onTap: function() { Quickshell.clipboardText = modelData.h; copyDepBtn.flash("Copied ✓") }
              }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(6)

            Text {
              Layout.fillWidth: true
              Layout.alignment: Qt.AlignVCenter
              text: "validate: " + root.doctorCommand
              elide: Text.ElideRight
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
              color: root.dimColor
            }

            SmallBtn {
              id: copyCmdBtn
              label: "Copy"
              fg: root.foregroundColor
              dim: root.dimColor
              onTap: function() { Quickshell.clipboardText = root.doctorCommand; copyCmdBtn.flash("Copied ✓") }
            }

            SmallBtn {
              id: checkBtn
              label: "Check"
              fg: root.foregroundColor
              dim: root.dimColor
              onTap: function() { root.refreshStatus(); checkBtn.flash("Checked ✓") }
            }
          }

          PanelSeparator {
            width: parent.width
            foreground: root.foregroundColor
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            width: parent.width
            text: "Tunnel scope"
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            color: root.dimColor
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            ModeCard {
              label: "Proxy"
              captionText: "SOCKS 1080 · HTTP 1081"
              active: !root.isSystemMode
              busy: root.isBusy
              warm: root.isRunning
              accent: root.accentColor
              fg: root.foregroundColor
              dim: root.dimColor
              onTap: function() { root.setMode("proxy") }
            }

            ModeCard {
              label: "System"
              captionText: "TCP 80/443 transparent"
              active: root.isSystemMode
              busy: root.isBusy
              warm: root.isRunning
              accent: root.accentColor
              fg: root.foregroundColor
              dim: root.dimColor
              onTap: function() { root.setMode("system") }
            }
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foregroundColor
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(12)

          Column {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(2)

            Text {
              text: "Start with system"
              font.family: root.panelFont
              font.pixelSize: Style.font.title
              font.bold: true
              color: root.foregroundColor
            }

            Text {
              text: root.isEnabled ? "AUTOSTART" : "NO AUTOSTART"
              elide: Text.ElideRight
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              color: root.dimColor
            }
          }

          ToggleSwitch {
            checked: root.isEnabled
            busy: root.isBusy
            interactive: !root.isBusy
            foreground: root.foregroundColor
            onToggled: root.setAutostart(!root.isEnabled)
            Layout.alignment: Qt.AlignVCenter
            Layout.preferredWidth: root._switchW
            Layout.preferredHeight: root._switchH
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foregroundColor
        }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Text {
            text: "Profiles"
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 1.2
            color: root.noProfilesError ? root.accentDanger : root.dimColor
          }

          Text {
            width: parent.width
            visible: root._profiles.length === 0
            color: root.noProfilesError ? root.noProfilesSoft : root.dimColor
            text: "No profiles yet — add your first below."
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
          }

          ListView {
            width: parent.width
            // Bounded list: many profiles no longer blow the panel past the
            // screen; the list scrolls internally instead.
            height: !root._profiles.length
              ? 0
              : Math.min(root._profiles.length * (Style.space(26) + Style.space(4)) - Style.space(4), Style.space(208))
            spacing: Style.space(4)
            clip: true
            interactive: true
            visible: root._profiles.length > 0
            model: root._profiles
            delegate: Rectangle {
              required property string modelData
              width: ListView.view.width
              height: Style.space(26)
              radius: 2
              color: modelData === root._activeProfile
                ? root.alpha(root.isRunning ? root.accentColor : root.foregroundColor, 0.10)
                : root.alpha(root.foregroundColor, 0.04)
              border.color: modelData === root._activeProfile
                ? root.alpha(root.isRunning ? root.accentColor : root.dimColor, 0.5)
                : root.alpha(root.dimColor, 0.2)
              border.width: 1

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(6)

                Text {
                  Layout.fillWidth: true
                  Layout.alignment: Qt.AlignVCenter
                  text: modelData + (modelData === root._activeProfile ? "  ●" : "")
                  elide: Text.ElideRight
                  font.family: root.panelFont
                  font.pixelSize: Style.font.body
                  font.bold: modelData === root._activeProfile
                  color: root.foregroundColor
                }

                SmallBtn {
                  label: root.isProbing ? "…" : "P"
                  enabled: !root.isBusy
                  fg: root.foregroundColor
                  dim: root.dimColor
                  onTap: function() { root.probeProfile(modelData) }
                }
                SmallBtn {
                  label: "Use"
                  enabled: !root.isBusy
                  fg: root.foregroundColor
                  dim: root.dimColor
                  onTap: function() { root.selectProfile(modelData) }
                }
                SmallBtn {
                  label: root._deleteArmed === modelData ? "Sure?" : "×"
                  enabled: !root.isBusy
                  fg: root._deleteArmed === modelData ? root.accentDanger : root.foregroundColor
                  dim: root.dimColor
                  onTap: function() { root.requestRemoveProfile(modelData) }
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: Style.space(26)
            radius: 2
            color: root.alpha(root.foregroundColor, 0.05)
            border.color: root.noProfilesError ? root.accentDanger : root.alpha(root.dimColor, 0.25)
            border.width: 1

            TextInput {
              id: profileInput
              text: root._addInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              verticalAlignment: TextInput.AlignVCenter
              font.family: root.panelFont
              font.pixelSize: Style.font.body
              color: root.foregroundColor
              clip: true
              onTextChanged: root._addInput = text

              Text {
                anchors.fill: parent
                verticalAlignment: Text.AlignVCenter
                text: "vless://… or path to a JSON config"
                font.family: root.panelFont
                font.pixelSize: Style.font.body
                color: root.dimColor
                visible: parent.text.length === 0
              }
            }
          }

          RowLayout {
            width: parent.width
            spacing: Style.space(8)

            Rectangle {
              Layout.fillWidth: true
              Layout.preferredHeight: Style.space(28)
              radius: 2
              color: root.alpha(root.foregroundColor, 0.05)
              border.color: root.noProfilesError ? root.accentDanger : root.alpha(root.dimColor, 0.25)
              border.width: 1
              Layout.alignment: Qt.AlignVCenter

              TextInput {
                id: profileNameInput
                text: root._addName
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                verticalAlignment: TextInput.AlignVCenter
                font.family: root.panelFont
                font.pixelSize: Style.font.caption
                color: root.foregroundColor
                clip: true
                onTextChanged: root._addName = text
                onAccepted: root.addProfile()

                Text {
                  anchors.fill: parent
                  verticalAlignment: Text.AlignVCenter
                  text: "name (optional)"
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                  color: root.dimColor
                  visible: parent.text.length === 0
                }
              }
            }

            Rectangle {
              Layout.preferredWidth: 64
              Layout.preferredHeight: Style.space(28)
              radius: 2
              color: root.alpha(root.foregroundColor, 0.08)
              border.color: root.noProfilesError ? root.accentDanger : root.alpha(root.dimColor, 0.3)
              border.width: 1
              Layout.alignment: Qt.AlignVCenter

              MouseArea {
                anchors.fill: parent
                enabled: root._addInput.length > 0 && !root.isBusy
                onClicked: root.addProfile()
              }

              Text {
                anchors.centerIn: parent
                text: "+ Add"
                font.family: root.panelFont
                font.pixelSize: Style.font.body
                font.bold: true
                color: root.foregroundColor
              }
            }
          }

          Text {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.profileMsg
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            font.bold: true
            color: root.isProbing ? root.foregroundColor
                   : (root.profileMsgIsError ? root.accentDanger : root.accentPass)
            visible: root.profileMsg !== ""
          }
        }

        PanelSeparator {
          width: parent.width
          foreground: root.foregroundColor
        }

        RowLayout {
          width: parent.width
          spacing: Style.space(12)

          Column {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Style.space(2)

            Text {
              text: "Connection test"
              font.family: root.panelFont
              font.pixelSize: Style.font.title
              font.bold: true
              color: root.foregroundColor
            }

            Text {
              text: root.exitIp !== ""
                ? "Exit " + root.exitIp + (root.latencyMs > 0 ? " · " + root.latencyMs + "ms" : "")
                : (root.isRunning ? "Tap to verify the tunnel" : "Not available while stopped")
              elide: Text.ElideRight
              font.family: root.panelFont
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              color: root.exitIp !== "" ? root.accentColor : root.dimColor
            }
          }

          Rectangle {
            Layout.preferredWidth: 52
            Layout.preferredHeight: Style.space(30)
            radius: 2
            color: root.alpha(root.foregroundColor, 0.06)
            border.color: root.alpha(root.dimColor, 0.3)
            border.width: 1
            visible: root.isRunning
            Layout.alignment: Qt.AlignVCenter

            Text {
              anchors.centerIn: parent
              text: root.isTesting ? "…" : "Test"
              font.family: root.panelFont
              font.pixelSize: Style.font.body
              font.bold: true
              color: root.foregroundColor
            }

            MouseArea {
              anchors.fill: parent
              enabled: root.isRunning && !root.isTesting && !root.isBusy
              onClicked: root.runTest()
            }
          }
        }

        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          font.family: root.panelFont
          font.pixelSize: Style.font.caption
          color: root.dimColor
          text: {
            var parts = []
            parts.push("Service: " + root.serviceName + ".service")
            var cfg = root._configFile !== "" ? root._configFile : root.configPath
            if (cfg !== "") parts.push("Config: " + cfg)
            return parts.join("\n")
          }
        }

        Rectangle {
          width: parent.width
          height: (root._errorFlash ? errCopyFlash.height : errorText.implicitHeight) + Style.space(12)
          radius: Style.cornerRadius || 2
          color: root.alpha(root.foregroundColor, 0.05)
          border.color: root.alpha(root.dimColor, 0.25)
          border.width: 1
          visible: root.lastError !== ""

          Text {
            id: errorText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.margins: Style.space(6)
            text: root.lastError
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            color: root.accentDanger
            wrapMode: Text.WordWrap
            visible: !root._errorFlash
          }

          Text {
            id: errCopyFlash
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(6)
            visible: root._errorFlash
            text: "Copied ✓"
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            color: root.accentPass
            horizontalAlignment: Text.AlignHCenter
          }

          TapHandler {
            onTapped: {
              if (root.lastError !== "") {
                // Copy the fix command when the error is dependency-driven,
                // otherwise the raw message; the persistent "backend missing"
                // notice copies its own install command instead.
                Quickshell.clipboardText = root._errorCopyCommand !== ""
                  ? root._errorCopyCommand
                  : (root._persistError ? root.installCommand : root.lastError)
                root._errorFlash = true
                errCopyHint.restart()
              }
            }
            cursorShape: Qt.PointingHandCursor
          }
        }
      }
    }
  }
}