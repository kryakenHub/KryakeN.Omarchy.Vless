import QtQuick
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "kryaken.omarchy.vless"

  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool running: panelLoader.item ? panelLoader.item.isRunning === true : false
  readonly property bool problem: panelLoader.item ? panelLoader.item.lastError !== "" : false
  readonly property bool systemMode: panelLoader.item ? panelLoader.item.isSystemMode === true : false

  readonly property string glyphFamily: root.bar && root.bar.fontFamily !== undefined
    ? root.bar.fontFamily
    : Style.font.family

  // Same Nerd Font vocabulary as OmaVLESS/zapret: the filled shield glyph is
  // the "on" mark, the outline shield is "off", Octicons shield-x is failure.
  readonly property string glyphConnected: "󰒘"
  readonly property string glyphDisconnected: "󰒙"
  readonly property string glyphProblem: ""

  readonly property color iconFg: root.bar && root.bar.barForeground !== undefined
    ? root.bar.barForeground
    : Color.foreground

  function luminance(c) {
    return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
  }

  // Letter color for the FILLED shield: theme-dark on a light fill,
  // theme-light on a dark fill, so the "V" always contrasts.
  function contrastColor(c) {
    return root.luminance(c) > 0.5 ? "#101315" : "#f2f5f6"
  }

  function open() { if (panelLoader.item) panelLoader.item.open() }
  function close() { if (panelLoader.item) panelLoader.item.close() }
  function toggle() { opened ? close() : open() }

  function refresh() { if (panelLoader.item) panelLoader.item.refreshStatus() }

  function injectPanel() {
    var p = panelLoader.item
    if (!p) return
    p.bar = root.bar
    p.anchorItem = button
    p.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  Timer {
    id: poll
    interval: root.refreshIntervalMs()
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  function refreshIntervalMs() {
    var sec = parseInt(root.setting("refreshIntervalSec", 5), 10)
    if (!isFinite(sec) || sec < 1) sec = 5
    return sec * 1000
  }

  Component {
    id: shieldIcon
    Item {
      id: iconRoot
      readonly property bool filled: root.running || root.problem
      readonly property string glyph: root.problem
        ? root.glyphProblem
        : (filled ? root.glyphConnected : root.glyphDisconnected)
      readonly property color glyphColor: root.problem
        ? (root.bar && root.bar.urgent !== undefined ? root.bar.urgent : Color.urgent)
        : (filled ? root.iconFg : Qt.darker(root.iconFg, 1.55))
      readonly property color letterColor: filled
        ? root.contrastColor(glyphColor)
        : root.iconFg

      Item {
        id: stage
        anchors.fill: parent
        Text {
          id: glyphText
          anchors.centerIn: parent
          anchors.horizontalCenterOffset: 1
          anchors.verticalCenterOffset: 1
          text: iconRoot.glyph
          color: iconRoot.glyphColor
          font.family: root.glyphFamily
          font.pixelSize: 14
          renderType: Text.NativeRendering
        }
        Text {
          id: vText
          anchors.centerIn: parent
          anchors.horizontalCenterOffset: 0
          anchors.verticalCenterOffset: 1
          text: "V"
          color: iconRoot.letterColor
          font.family: root.glyphFamily
          font.pixelSize: 8
          font.bold: true
          renderType: Text.NativeRendering
        }
      }
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: shieldIcon
    tooltipText: (root.systemMode ? "VPN" : "Proxy") + (root.running ? " active" : " stopped")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        root.refresh()
      } else if (buttonCode === Qt.RightButton) {
        if (panelLoader.item) panelLoader.item.toggleDaemon()
      } else {
        root.toggle()
      }
    }
  }
}