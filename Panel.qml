import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui
import "IdleModel.js" as IdleModel

// Power saving: a bar icon (highlighted while "stay awake" is on) with a
// panel listing the three idle stages — screensaver, lock, suspend — each
// with a switch and a minutes field. All state lives in Service.qml, which
// the shell loads once; this widget exists once per monitor and only reads
// from and calls into that service, so the copies never disagree.
//
// Left-click opens the panel, right-click toggles stay-awake. NOTE: after
// editing this file run `omarchy restart shell` — the hot reload
// re-instantiates but keeps the old compiled QML.
Panel {
  id: root
  moduleName: "io.github.selfcrypto.power-saving"
  ipcTarget: "io.github.selfcrypto.power-saving"

  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("io.github.selfcrypto.power-saving") : null
  readonly property bool ready: svc !== null && svc !== undefined
  readonly property bool stayAwake: ready ? svc.stayAwake : false
  readonly property bool powerSaving: ready && !svc.stayAwake && !svc.stockIdleEnabled

  readonly property var stages: [
    { key: "screensaver", glyph: "󱄄", hint: "Terminal screensaver; also `omarchy toggle screensaver`" },
    { key: "lock", glyph: "󰌾", hint: "Lock screen, displays blank 5 s later" },
    { key: "suspend", glyph: "󰒲", hint: "systemctl suspend; the session locks first" }
  ]

  function stageEnabled(key) { return ready ? svc.stageEnabled(key) : false }
  function stageSeconds(key) { return ready ? svc.stageTimeout(key) : 0 }
  function stageMinutes(key) { return Math.max(1, Math.round(stageSeconds(key) / 60)) }
  function setStageEnabled(key, value) { if (ready) svc.setStageEnabled(key, value) }
  function setStageMinutes(key, minutes) { if (ready) svc.setStageTimeout(key, Math.max(1, minutes) * 60) }
  function toggleStage(key) { setStageEnabled(key, !stageEnabled(key)) }
  function togglePowerSaving() { if (ready) svc.setIdleEnabled(root.stayAwake) }
  function lockNow() { if (!ready) return; root.close(); svc.lockSystem("panel") }
  function suspendNow() { if (!ready) return; root.close(); svc.suspendSystem("panel") }

  readonly property var stageList: {
    var list = []
    for (var i = 0; i < stages.length; i++) {
      var key = stages[i].key
      list.push({ key: key, glyph: stages[i].glyph, enabled: root.stageEnabled(key), seconds: root.stageSeconds(key) })
    }
    return list
  }
  readonly property string summary: ready ? IdleModel.summaryText(stageList) : "Service not running"
  readonly property string compactSummary: ready ? IdleModel.compactSummaryText(stageList) : "Service not running"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.stayAwake ? "󰅶" : "󰒲"
    active: root.stayAwake
    tooltipText: !root.ready
      ? "Power saving: service not running"
      : (root.stayAwake
        ? "Staying awake · right-click to resume power saving"
        : "Power saving: " + root.summary + " · right-click to stay awake")
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePowerSaving()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(460))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        var n = parseInt(t, 10)
        if (t === "t" || t === "T") root.togglePowerSaving()
        else if (n >= 1 && n <= root.stages.length) root.toggleStage(root.stages[n - 1].key)
        else if (t === "l" || t === "L") root.lockNow()
        else if (t === "s" || t === "S") root.suspendNow()
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "Power saving"
          meta: root.ready && root.svc.stockIdleEnabled
            ? "Paused · run: omarchy plugin disable omarchy.idle"
            : (root.stayAwake ? "Staying awake · stages paused" : root.compactSummary)
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.powerSaving ? 1.0 : 0.6
          iconComponent: Component {
            Text {
              text: root.stayAwake ? "󰅶" : "󰒲"
              color: root.stayAwake ? root.urgent : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
          trailingControl: Component {
            ToggleSwitch {
              id: powerSwitch
              checked: root.powerSaving
              interactive: root.ready
              foreground: root.foreground
              onToggled: root.togglePowerSaving()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.powerSaving ? "Stay awake (pause all stages)" : "Resume power saving"
                fontFamily: root.fontFamily
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(2)

          PanelSectionHeader {
            text: "STAGES · MINUTES OF IDLE"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Repeater {
            model: root.stages
            delegate: Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property string key: modelData.key
              readonly property bool isOn: root.stageEnabled(key)
              readonly property int minutes: root.stageMinutes(key)
              readonly property bool hovered: rowMouse.containsMouse || minutesField.hovering || stageSwitch.containsMouse
              width: column.width
              height: Style.space(50)
              radius: Style.cornerRadius
              color: row.hovered ? root.hoverFill : "transparent"
              opacity: root.powerSaving || !root.ready ? 1.0 : 0.55

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.NoButton
              }

              RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Text {
                  Layout.preferredWidth: Style.space(20)
                  text: row.modelData.glyph
                  color: row.isOn ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  horizontalAlignment: Text.AlignHCenter
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: 0

                  Text {
                    text: (row.index + 1) + "  " + IdleModel.stageLabel(row.key)
                    color: row.isOn ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    Layout.fillWidth: true
                    text: row.isOn ? "after " + IdleModel.durationText(root.stageSeconds(row.key)) : "off"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                MinutesField {
                  id: minutesField
                  shownValue: row.minutes
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  opacity: row.isOn ? 1.0 : 0.6
                  onCommitted: function(v) { root.setStageMinutes(row.key, v) }
                }

                ToggleSwitch {
                  id: stageSwitch
                  checked: row.isOn
                  interactive: root.ready
                  foreground: root.foreground
                  onToggled: root.setStageEnabled(row.key, !row.isOn)

                  PanelToolTip {
                    visible: stageSwitch.containsMouse
                    text: row.modelData.hint
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }
        }

        PanelSeparator { width: parent.width }

        RowLayout {
          width: parent.width
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            text: "Right now"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelActionButton {
            iconText: "󰌾"
            tooltipText: "Lock now (l)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.ready
            onClicked: root.lockNow()
          }

          PanelActionButton {
            iconText: "󰒲"
            tooltipText: "Suspend now (s)"
            foreground: root.foreground
            fontFamily: root.fontFamily
            enabled: root.ready
            onClicked: root.suspendNow()
          }
        }

        Text {
          width: parent.width
          text: "t stay awake · 1/2/3 stages · l lock · s suspend"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
