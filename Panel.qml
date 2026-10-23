import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "IdleModel.js" as IdleModel

// Power saving: a bar icon (highlighted while "stay awake" is on) with a panel
// that draws the idle stages in the order they fire (IdleSchedule.qml), then
// lists them in their groups, display (screensaver, standby), system (lock,
// suspend) and hibernation (where logind can hibernate), each with a switch
// and a minutes stepper. All state
// lives in Service.qml, which the shell loads once; this widget exists once
// per monitor and only reads from and calls into that service, so the copies
// never disagree.
//
// Left-click opens the panel, right-click toggles stay-awake. NOTE: after
// editing this file run `omarchy restart shell`. The hot reload
// re-instantiates but keeps the old compiled QML.
Panel {
  id: root
  moduleName: "io.github.selfcrypto.power-saving"
  ipcTarget: "io.github.selfcrypto.power-saving"

  readonly property var svc: bar && bar.shell && typeof bar.shell.serviceFor === "function" ? bar.shell.serviceFor("io.github.selfcrypto.power-saving") : null
  readonly property bool ready: svc !== null && svc !== undefined
  readonly property bool stayAwake: ready ? svc.stayAwake : false
  readonly property bool powerSaving: ready && !svc.stayAwake && !svc.stockIdleEnabled

  // `number` is the key that toggles the stage; it runs across both groups.
  // `nowKey` runs it at once, as a click on the row's name does.
  readonly property var displayStages: [
    { key: "screensaver", glyph: "󱄄", number: 1, nowKey: "r", hint: "Terminal screensaver; also `omarchy toggle screensaver`" },
    { key: "standby", glyph: "󰶐", number: 2, nowKey: "o", hint: "Monitors off (DPMS); a key or the mouse brings them back" }
  ]
  readonly property var systemStages: [
    { key: "lock", glyph: "󰌾", number: 3, nowKey: "k", hint: "Locks the session" },
    { key: "suspend", glyph: "󰒲", number: 4, nowKey: "s", hint: "Suspend through logind; the session locks first" }
  ]
  readonly property var hibernationStages: [
    { key: "hibernate", glyph: "󰜗", number: 5, nowKey: "h", hint: "Hibernate through logind; the session locks first" }
  ]
  // Hibernation is listed only where logind says it can hibernate.
  readonly property bool canHibernate: ready && svc.canHibernate
  readonly property var stages: displayStages.concat(systemStages, canHibernate ? hibernationStages : [])

  function stageEnabled(key) { return ready ? svc.stageEnabled(key) : false }
  function stageSeconds(key) { return ready ? svc.stageTimeout(key) : 0 }
  function stageMinutes(key) { return Math.max(1, Math.round(stageSeconds(key) / 60)) }
  function setStageEnabled(key, value) { if (ready) svc.setStageEnabled(key, value) }
  function setStageMinutes(key, minutes) { return ready && svc.setStageTimeout(key, Math.max(1, minutes) * 60) }
  function toggleStage(key) { setStageEnabled(key, !stageEnabled(key)) }
  function togglePowerSaving() { if (ready) svc.setIdleEnabled(root.stayAwake) }
  function lockNow() { if (!ready) return; root.close(); svc.lockSystem("panel") }
  function suspendNow() { if (!ready) return; root.close(); svc.suspendSystem("panel") }
  function hibernateNow() { if (!canHibernate) return; root.close(); svc.hibernateSystem("panel") }
  // "Then hibernate" under suspend: shown where logind can suspend then
  // hibernate, dimmed while suspend is off, and kept in view while it is on
  // so it can be turned off.
  readonly property bool thenHibernate: ready && svc.suspendThenHibernate
  readonly property bool canThenHibernate: ready && svc.canSuspendThenHibernate
  readonly property string hibernateDelayText: ready ? svc.hibernateDelayText : ""
  readonly property string hibernateDelayHint: ready ? svc.hibernateDelayHint : ""
  readonly property bool showThenHibernate: thenHibernate || canThenHibernate
  function toggleThenHibernate() { if (ready) svc.setSuspendThenHibernate(!thenHibernate) }
  function screensaverNow() { if (!ready) return; root.close(); svc.startScreensaver("panel") }
  function standbyNow() { if (!ready) return; root.close(); svc.standbyDisplays("panel") }
  function runStageNow(key) {
    if (key === "screensaver") screensaverNow()
    else if (key === "standby") standbyNow()
    else if (key === "lock") lockNow()
    else if (key === "suspend") suspendNow()
    else if (key === "hibernate") hibernateNow()
  }

  readonly property var stageList: {
    var list = []
    for (var i = 0; i < stages.length; i++) {
      var key = stages[i].key
      list.push({ key: key, glyph: stages[i].glyph, number: stages[i].number, enabled: root.stageEnabled(key), seconds: root.stageSeconds(key),
        note: key === "suspend" && root.thenHibernate && root.canThenHibernate ? "then hibernate" : "" })
    }
    return list
  }
  readonly property string summary: ready ? IdleModel.summaryText(stageList) : "Service not running"

  readonly property int stagesOn: stageList.filter(function(stage) { return stage.enabled }).length
  // Above the schedule: an exception when there is one, else what fires next.
  readonly property string scheduleStatus: {
    if (!ready) return "Service not running"
    if (svc.orderNote !== "") return svc.orderNote
    if (svc.suspendOverridden) return "Suspend is off while Hibernate is on"
    if (svc.stockIdleEnabled) return "Paused while omarchy.idle is on. Run: omarchy plugin disable omarchy.idle"
    if (stayAwake) return "Stay awake is on. Press t to resume."
    if (svc.standbyActive) return "Displays in standby"
    if (svc.screensaverWindowCount > 0) return "Screensaver running"
    if (stagesOn === 0) return "All stages off"
    return IdleModel.nextStageText(stageList)
  }

  // Tooltip of a minutes field: its range and, when a neighbour sets it, why.
  function minutesHint(key) {
    var range = minutesRange(key)
    var reason = ready ? IdleModel.boundsReason(key, svc.stageStates()) : ""
    return "Allowed: " + range.from + "–" + range.to + " min." + (reason ? " " + reason + "." : "")
  }

  // Tooltip of a stage switch: what turning it on also does, else what it is.
  function switchHint(entry) {
    var other = IdleModel.exclusiveWith(entry.key)
    if (other !== "" && !stageEnabled(entry.key) && stageEnabled(other))
      return "Turn on " + IdleModel.stageLabel(entry.key) + " and turn off " + IdleModel.stageLabel(other)
    return entry.hint
  }

  // Minutes a stage's field may take: its group neighbour's time while both are
  // on. The value it shows now is always inside, so a time that is not a whole
  // minute, or out of order by hand, is shown as it is and not clamped.
  function minutesRange(key) {
    if (!ready) return { from: 1, to: 1440 }
    var b = svc.stageTimeoutBounds(key)
    var shown = stageMinutes(key)
    var from = Math.min(shown, Math.max(1, Math.ceil(b.min / 60)))
    var to = b.max >= 0 ? Math.max(shown, Math.floor(b.max / 60)) : 1440
    return { from: from, to: Math.max(from, to) }
  }

  readonly property color foreground: Commons.Color.popups.text
  readonly property color accent: Commons.Color.accent
  readonly property color urgent: bar ? bar.urgent : Commons.Color.urgent
  readonly property color dim: Util.alpha(foreground, 0.72)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, accent)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    keyCatcher.pendingKey = ""
    if (opened) Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (opened && ready) svc.refreshHibernate()
  }

  // A key as printed on the keyboard, for the keys the panel answers to.
  component KeyCap: Rectangle {
    required property string label
    implicitWidth: Math.max(implicitHeight, capText.implicitWidth + Style.space(8))
    implicitHeight: capText.implicitHeight + Style.space(2)
    radius: Math.min(Style.cornerRadius, height / 2)
    color: "transparent"
    border.width: 1
    border.color: Util.alpha(root.foreground, 0.28)

    Text {
      id: capText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: parent.label
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // One stage row: glyph, number and name, the key that runs it, minutes,
  // switch. Both groups use it, so the two sections cannot drift apart. The
  // glyph-and-name part is a button that runs the stage at once.
  component StageRow: Rectangle {
    id: row
    required property var modelData
    readonly property string key: modelData.key
    readonly property bool isOn: root.stageEnabled(key)
    readonly property int minutes: root.stageMinutes(key)
    readonly property bool hovered: rowMouse.containsMouse || runMouse.containsMouse || minutesField.hovering || stageSwitch.containsMouse
    width: parent ? parent.width : 0
    height: Math.max(Style.space(44), rowLayout.implicitHeight + Style.space(10))
    radius: Style.cornerRadius
    color: row.hovered ? root.hoverFill : "transparent"

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    MouseArea {
      id: runMouse
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: rowLayout.x + minutesField.x - rowLayout.spacing / 2
      hoverEnabled: true
      enabled: root.ready
      cursorShape: Qt.PointingHandCursor
      onClicked: root.runStageNow(row.key)

      PanelToolTip {
        visible: runMouse.containsMouse
        text: IdleModel.stageLabel(row.key) + " now (" + row.modelData.nowKey + ")" + (root.powerSaving ? "" : ". Works while paused.")
        fontFamily: root.fontFamily
      }
    }

    RowLayout {
      id: rowLayout
      anchors.fill: parent
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      Rectangle {
        Layout.preferredWidth: Style.space(30)
        Layout.preferredHeight: Style.space(30)
        radius: Style.cornerRadius
        color: row.isOn ? Style.selectedAccentFill : Style.normalFillFor(root.foreground, root.accent)

        Text {
          anchors.centerIn: parent
          text: row.modelData.glyph
          color: row.isOn ? root.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
        }
      }

      Text {
        text: row.modelData.number + "  " + IdleModel.stageLabel(row.key)
        color: row.isOn ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: row.isOn
        elide: Text.ElideRight
        Layout.fillWidth: true
        Layout.maximumWidth: implicitWidth
        Layout.minimumWidth: implicitWidth
      }

      KeyCap { label: row.modelData.nowKey }

      Item { Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.horizontalStretchFactor: 0 }

      MinutesField {
        id: minutesField
        readonly property var range: root.minutesRange(row.key)
        from: range.from
        to: range.to
        shownValue: row.minutes
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        enabled: root.ready
        Accessible.name: IdleModel.stageLabel(row.key) + " idle minutes"
        // A refused write (out of order by the time it lands) puts the saved value back.
        onCommitted: function(v) { if (!root.setStageMinutes(row.key, v)) minutesField.value = row.minutes }

        PanelToolTip {
          visible: minutesField.hovering
          text: root.minutesHint(row.key)
          fontFamily: root.fontFamily
        }
      }

      ToggleSwitch {
        id: stageSwitch
        checked: row.isOn
        interactive: root.ready
        foreground: root.foreground
        onToggled: root.setStageEnabled(row.key, !row.isOn)

        PanelToolTip {
          visible: stageSwitch.containsMouse
          text: root.switchHint(row.modelData)
          fontFamily: root.fontFamily
        }
      }
    }
  }

  // Under the suspend row, marked ↳ as what follows it: suspend through logind's
  // SuspendThenHibernate. The box holds the delay systemd will use; it is
  // read-only, since the plugin cannot set it, and says how to on hover.
  component ThenHibernateRow: Item {
    id: thenRow
    readonly property bool isOn: root.thenHibernate && root.stageEnabled("suspend")
    width: parent ? parent.width : 0
    height: Style.space(44)

    RowLayout {
      id: thenLayout
      anchors.fill: parent
      anchors.leftMargin: Style.space(8) + Style.space(30) + Style.space(8)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(8)

      // Same text shape as a stage name ("4  Suspend"), so it lines up under it.
      Text {
        text: "↳  Hibernate after"
        color: thenRow.isOn ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        Layout.fillWidth: true
        Layout.maximumWidth: implicitWidth
        Layout.minimumWidth: implicitWidth
      }

      Item { Layout.fillWidth: true; Layout.minimumWidth: 0; Layout.horizontalStretchFactor: 0 }

      // The stepper's box, greyed: systemd's value, not the plugin's.
      BorderSurface {
        id: delayBox
        readonly property var spec: Border.controlSpec("normal", root.foreground, root.accent)
        Layout.preferredWidth: Style.space(100)
        Layout.preferredHeight: Math.max(Style.spacing.controlHeight, Style.font.body + Style.spacing.controlPaddingY * 2)
        color: Style.controlFill(false, false, root.foreground, root.accent)
        borderSpec: spec
        radius: Style.cornerRadius
        opacity: 0.6

        Text {
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: root.canThenHibernate ? root.hibernateDelayText : "n/a"
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          width: Math.min(implicitWidth, parent.width - Style.space(12))
          horizontalAlignment: Text.AlignHCenter
        }

        HoverHandler { id: delayHover }

        PanelToolTip {
          visible: delayHover.hovered
          text: root.canThenHibernate ? root.hibernateDelayHint : "The system cannot suspend then hibernate; suspend only."
          fontFamily: root.fontFamily
        }
      }

      ToggleSwitch {
        id: thenSwitch
        checked: root.thenHibernate
        interactive: root.ready
        foreground: root.foreground
        onToggled: root.toggleThenHibernate()
      }
    }
  }

  component StageGroup: Column {
    id: group
    required property string title
    required property var entries
    // Shown at the bottom of the group's card, when set.
    property Component footer: null
    width: parent ? parent.width : 0
    spacing: Style.space(6)

    PanelSectionHeader {
      text: group.title
      foreground: root.foreground
      color: root.dim
      fontFamily: root.fontFamily
    }

    Rectangle {
      width: parent.width
      height: groupRows.implicitHeight
      radius: Style.cornerRadius
      color: Style.normalFillFor(root.foreground, root.accent)

      Column {
        id: groupRows
        width: parent.width
        Repeater {
          model: group.entries
          delegate: StageRow {}
        }
        Loader {
          width: parent.width
          active: group.footer !== null
          sourceComponent: group.footer
        }
      }
    }
  }

  Component {
    id: thenHibernateRowComponent
    ThenHibernateRow {}
  }

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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(640))

    // Not the stock PanelKeyCatcher: it fires on key press only, and turns
    // lowercase "l" into a cursor move before any panel sees it. Two things
    // matter here. Omarchy ships misc.key_press_enables_dpms on, so monitors
    // switched off on the press of "o" came straight back on its release;
    // standby therefore runs on the release, which Hyprland has already seen
    // with the monitors still on. And lock is on "k" because "l" never
    // arrives as text through the stock catcher.
    Item {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      Keys.priority: Keys.BeforeItem

      // "o" and "r" run on release: the release of a key pressed here would
      // otherwise wake the monitors, or land after the panel has closed.
      property string pendingKey: ""

      Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) { root.close(); event.accepted = true; return }
        if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
          root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
          event.accepted = true
          return
        }
        var t = event.text
        if (!t || t.length !== 1) return
        var n = parseInt(t, 10)
        if (t === "t" || t === "T") root.togglePowerSaving()
        else if (n >= 1 && n <= root.stages.length) root.toggleStage(root.stages[n - 1].key)
        else if (t === "o" || t === "O" || t === "r" || t === "R") keyCatcher.pendingKey = t.toLowerCase()
        else if (t === "k" || t === "K") root.lockNow()
        else if (t === "s" || t === "S") root.suspendNow()
        else if ((t === "h" || t === "H") && root.canHibernate) root.hibernateNow()
        else return
        event.accepted = true
      }

      Keys.onReleased: function(event) {
        if (keyCatcher.pendingKey === "" || event.isAutoRepeat) return
        if (String(event.text).toLowerCase() !== keyCatcher.pendingKey) return
        var key = keyCatcher.pendingKey
        keyCatcher.pendingKey = ""
        event.accepted = true
        if (key === "o") root.standbyNow()
        else root.screensaverNow()
      }

      Flickable {
        id: scheduleViewport
        anchors.fill: parent
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: column
          width: scheduleViewport.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "Power saving"
            meta: !root.ready ? "Unavailable"
              : (root.stayAwake ? "Staying awake" : (!root.powerSaving ? "Paused" : root.stagesOn + " of " + root.stages.length + " stages on"))
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: root.stayAwake ? "󰅶" : "󰒲"
                color: root.stayAwake ? root.urgent : root.accent
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

          IdleSchedule {
            width: parent.width
            stages: root.stageList
            status: root.scheduleStatus
            caption: "Times count from your last activity"
            available: root.ready
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            onStageClicked: function(key) { root.toggleStage(key) }
          }

          StageGroup {
            title: "Display"
            entries: root.displayStages
          }

          StageGroup {
            title: "System"
            entries: root.systemStages
            footer: root.showThenHibernate ? thenHibernateRowComponent : null
          }

          StageGroup {
            visible: root.canHibernate
            title: "Hibernation"
            entries: root.hibernationStages
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // Run keys live beside their stage; global keys stay in the footer.
          Column {
            width: parent.width
            spacing: Style.space(2)

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: [{ key: "t", text: "stay awake" }, { key: "1–" + root.stages.length, text: "stage on/off" }, { key: "click", text: "a name runs it" }]
                delegate: Row {
                  id: hint
                  required property var modelData
                  spacing: Style.space(5)
                  rightPadding: Style.space(8)

                  KeyCap { label: hint.modelData.key }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: hint.modelData.text
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }

            // Things the panel cannot show as a state, with the detail on hover.
            Flow {
              width: parent.width
              spacing: Style.space(6)
              topPadding: Style.space(4)

              Repeater {
                model: [
                  { show: true, text: "Apps can delay idle actions",
                    hint: "Apps that request idle inhibition, such as video players, can keep the screen on." },
                  { show: root.ready && !root.canHibernate, text: "Hibernation unavailable",
                    hint: "The system does not currently offer hibernation. Setup: omarchy-hibernation-setup" }
                ].filter(function(note) { return note.show })
                delegate: Text {
                  id: footerNote
                  required property var modelData
                  rightPadding: Style.space(8)
                  textFormat: Text.PlainText
                  text: "󰋽 " + footerNote.modelData.text
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption

                  MouseArea {
                    id: noteMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    acceptedButtons: Qt.NoButton
                  }

                  PanelToolTip {
                    visible: noteMouse.containsMouse
                    text: footerNote.modelData.hint
                    fontFamily: root.fontFamily
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}
