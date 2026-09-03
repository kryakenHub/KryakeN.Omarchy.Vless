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

    width: Math.max(24, textItem.implicitWidth + 12)
    height: Style.space(20)
    radius: 2
    color: _flashing ? Qt.rgba(fg.r, fg.g, fg.b, 0.22) : Qt.rgba(fg.r, fg.g, fg.b, 0.06)
    border.color: _flashing ? fg : Qt.rgba(dim.r, dim.g, dim.b, 0.3)
    border.width: 1

    Text {
      id: textItem
      anchors.centerIn: parent
      text: parent._flashing ? parent._flashLabel : parent.label
      color: parent.fg
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    MouseArea {
      anchors.fill: parent
      onClicked: { if (parent.onTap) parent.onTap() }
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
  property var _profiles: []
  property string _activeProfile: ""
  property var _deps: []
  property string profileMsg: ""
  // Профиль-сообщение: success = зелёный, ошибка = красный (см. рендеринг).
  property bool profileMsgIsError: false
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
    onTriggered: root._error = ""
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
  readonly property color accentColor: root.isRunning ? "#10B981" : "#EF4444"
  readonly property string panelFont: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property string daemonScriptPath:
    Qt.resolvedUrl("backend.sh").toString().replace(/^file:\/\//, "")

  // Root-owned copy installed by ensure_install(); used for all pkexec
  // invocations so we never re-execute a user-writable script as root.
  readonly property string privilegedScriptPath: "/etc/xray-vpn/backend.sh"

  // Copy-pasteable commands for onboarding (shown while a dependency is
  // missing): install a package, or re-validate the whole setup in a terminal.
  readonly property string doctorCommand:
    "bash ~/.config/omarchy/plugins/" + root.moduleName + "/backend.sh doctor"

  readonly property string statusMeta:
    !root.isInstalled
      ? "Not installed"
      : root.lastError !== ""
        ? "Error"
        : (root.isRunning
            ? (root.isSystemMode ? "System · Active" : "Proxy · Active")
            : (root.isSystemMode ? "System · Standby" : "Proxy · Standby"))

  // First install creates /etc/xray-vpn/backend.sh from the plugin checkout
  // automatically (a fresh setup where nothing exists yet). Afterwards, if
  // the root-owned helper is deleted, we do NOT try to restore it (that caused
  // an endless pkexec password loop) — we surface a clear error telling the
  // user to reinstall the plugin.
  // `_provisionedOnce` records that /etc/xray-vpn was created in this session,
  // so a later missing helper reports an error instead of re-provisioning.
  property bool _provisionedOnce: false
  property bool _bootstrapInFlight: false

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

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

  function _serveEnsure() {
    if (serveProcess.running) return
    if (Model.state.helperPresent) {
      root._provisionedOnce = true
      root._bootstrapInFlight = false
    } else if (root._provisionedOnce) {
      // /etc/xray-vpn was created earlier but the helper is gone now: honest
      // error, no automatic re-provision, no repeated password prompt.
      root._serveFailAll("VPN helper missing: /etc/xray-vpn/backend.sh was deleted. Reinstall the plugin.")
      return
    } else if (!root._bootstrapInFlight) {
      // Genuine first install (nothing provisioned yet): create /etc/xray-vpn once.
      root._bootstrapInFlight = true
      bootProc.command = ["pkexec", root.daemonScriptPath, "install"]
      bootProc.running = true
      return
    }
    serveProcess.command = ["pkexec", root.privilegedScriptPath, "serve"]
    serveProcess.running = true
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
    var item = root._serveQueue.splice(idx, 1)[0]
    root._serveInFlight = root._serveQueue.length
    if (o.code === 0) {
      if (item.ok) item.ok(String(o.out || ""), String(o.err || ""), Number(o.code))
    } else {
      var serr = String(o.err || "")
      if (item.err) item.err(Number(o.code), String(o.out || ""), serr)
      else if (item.ok) item.ok(String(o.out || ""), serr, Number(o.code))
    }
  }

  function _serveFailAll(reason) {
    serveGuard.stop()
    root._serveUp = false
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
    root._serveEnqueue(["toggle"],
      function() { root._error = ""; Model.state.error = ""; root.refreshStatus() },
      function(code, out, err) {
        Model.state.error = (err || "toggle failed").trim()
        root._error = Model.state.error
        if (root._error !== "") errorDismiss.restart()
      })
  }

  function setMode(m) {
    if (root.isBusy || root.mode === m) return
    // Optimistic: the next status poll reconciles with reality on failure.
    root._mode = m
    root._serveEnqueue(["mode", m],
      function() { root._error = ""; Model.state.error = ""; root.refreshStatus() },
      function(code, out, err) {
        Model.state.error = (err || "mode change failed").trim()
        root._error = Model.state.error
        if (root._error !== "") errorDismiss.restart()
      })
  }

  function setAutostart(on) {
    if (root.isBusy) return
    root._enabled = on
    root._serveEnqueue([on ? "enable" : "disable"],
      function() { root._error = ""; Model.state.error = ""; root.refreshStatus() },
      function(code, out, err) {
        Model.state.error = (err || "autostart change failed").trim()
        root._error = Model.state.error
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
        if (out !== "") { root.profileMsg = out; root.profileMsgIsError = false }
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

  function removeProfile(name) {
    if (root.isBusy) return
    // Удаление ресурса всегда показываем красным (необратимо), как в zapret.
    root.profileMsg = ""
    root.profileMsgIsError = true
    root._clearAddOnSuccess = false
    root._serveEnqueue(["profiles", "remove", name],
      function(out, err, code) {
        if (out !== "") { root.profileMsg = out; root.profileMsgIsError = true }
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

  Timer {
    id: statusTimer
    interval: {
      var sec = parseInt(root.setting("refreshIntervalSec", 5), 10)
      if (!isFinite(sec) || sec < 1) sec = 5
      return sec * 1000
    }
    running: true
    repeat: true
    onTriggered: if (!root.isBusy) root.refreshStatus()
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
        Model.parseStatus(out)
      } else {
        Model.parseStatus("")
        Model.state.error = (err || "status failed").trim()
      }
      root._installed = Model.state.installed
      root._running = Model.state.running
      root._enabled = Model.state.enabled
      root._mode = Model.state.mode
      root._config = Model.state.config
      root._configFile = Model.state.configFile
      root._server = Model.state.server
      root._exitIp = Model.state.exitIp
      root._latencyMs = Model.state.latencyMs
      root._error = Model.state.error
      root._profiles = Model.state.profiles
      root._activeProfile = Model.state.activeProfile
      var missing = []
      for (var di = 0; di < Model.state.deps.length; di++) {
        if (!Model.state.deps[di].ok) missing.push(Model.state.deps[di])
      }
      root._deps = missing
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
      if (exitCode === 0 && Model.parseTest(out)) {
        root._exitIp = Model.state.exitIp
        root._latencyMs = Model.state.latencyMs
        root._error = ""
      } else {
        root._exitIp = ""
        root._latencyMs = 0
        if (exitCode !== 0 || out.indexOf('"ok":false') >= 0) {
          root._error = "Connection test failed"
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
        Model.state.error = "status timeout"
        root._error = Model.state.error
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
        root._provisionedOnce = true
        console.log("[kryaken.omarchy.vless] bootstrap install ok")
        root._serveEnsure()
      } else {
        console.log("[kryaken.omarchy.vless] bootstrap install failed rc=" + exitCode + " err=" + err)
        root._serveFailAll("privilege helper setup failed (" + exitCode + "): " + err)
      }
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

          Repeater {
            model: root._deps
            delegate: RowLayout {
              required property var modelData
              width: parent.width
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

            Rectangle {
              Layout.fillWidth: true
              Layout.minimumWidth: 100
              Layout.preferredHeight: Style.space(44)
              radius: 2
              color: !root.isSystemMode
                ? root.alpha(root.isRunning ? root.accentColor : root.foregroundColor, 0.12)
                : root.alpha(root.foregroundColor, 0.04)
              border.color: !root.isSystemMode
                ? root.alpha(root.isRunning ? root.accentColor : root.dimColor, 0.55)
                : root.alpha(root.dimColor, 0.2)
              border.width: 1

              MouseArea {
                anchors.fill: parent
                enabled: !root.isBusy
                onClicked: root.setMode("proxy")
              }

              Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(8)
                spacing: Style.space(1)

                Text {
                  text: "Proxy"
                  font.family: root.panelFont
                  font.pixelSize: Style.font.body
                  font.bold: !root.isSystemMode
                  color: root.foregroundColor
                }

                Text {
                  text: "SOCKS 1080 · HTTP 1081"
                  elide: Text.ElideRight
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                  color: root.dimColor
                }
              }
            }

            Rectangle {
              Layout.fillWidth: true
              Layout.minimumWidth: 100
              Layout.preferredHeight: Style.space(44)
              radius: 2
              color: root.isSystemMode
                ? root.alpha(root.isRunning ? root.accentColor : root.foregroundColor, 0.12)
                : root.alpha(root.foregroundColor, 0.04)
              border.color: root.isSystemMode
                ? root.alpha(root.isRunning ? root.accentColor : root.dimColor, 0.55)
                : root.alpha(root.dimColor, 0.2)
              border.width: 1

              MouseArea {
                anchors.fill: parent
                enabled: !root.isBusy
                onClicked: root.setMode("system")
              }

              Column {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(8)
                spacing: Style.space(1)

                Text {
                  text: "System"
                  font.family: root.panelFont
                  font.pixelSize: Style.font.body
                  font.bold: root.isSystemMode
                  color: root.foregroundColor
                }

                Text {
                  text: "TCP 80/443 transparent"
                  elide: Text.ElideRight
                  font.family: root.panelFont
                  font.pixelSize: Style.font.caption
                  color: root.dimColor
                }
              }
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
            color: root.dimColor
          }

          Text {
            width: parent.width
            visible: root._profiles.length === 0
            color: root.dimColor
            text: "No profiles yet — add your first below."
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
          }

          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: root._profiles.length > 0

            Repeater {
              model: root._profiles
              delegate: Rectangle {
                required property string modelData
                width: parent.width
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
                    label: "P"
                    fg: root.foregroundColor
                    dim: root.dimColor
                    onTap: function() { root.probeProfile(modelData) }
                  }
                  SmallBtn {
                    label: "Use"
                    fg: root.foregroundColor
                    dim: root.dimColor
                    onTap: function() { root.selectProfile(modelData) }
                  }
                  SmallBtn {
                    label: "×"
                    fg: root.foregroundColor
                    dim: root.dimColor
                    onTap: function() { root.removeProfile(modelData) }
                  }
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: Style.space(26)
            radius: 2
            color: root.alpha(root.foregroundColor, 0.05)
            border.color: root.alpha(root.dimColor, 0.25)
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
              border.color: root.alpha(root.dimColor, 0.25)
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
              border.color: root.alpha(root.dimColor, 0.3)
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
                   : (root.profileMsgIsError ? "#EF4444" : "#10B981")
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
          height: Style.space(34)
          radius: Style.cornerRadius || 2
          color: root.alpha(root.foregroundColor, 0.05)
          border.color: root.alpha(root.dimColor, 0.25)
          border.width: 1
          visible: root.lastError !== ""

          Text {
            id: errorText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: root.lastError
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            color: "#EF4444"
            elide: Text.ElideRight
            visible: !root._errorFlash
          }

          Text {
            id: errCopyFlash
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            text: "Copied ✓"
            font.family: root.panelFont
            font.pixelSize: Style.font.caption
            color: "#10B981"
            horizontalAlignment: Text.AlignHCenter
            visible: root._errorFlash
          }

          TapHandler {
            onTapped: {
              if (root.lastError !== "") {
                Quickshell.clipboardText = root.lastError
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