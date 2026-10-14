import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Minutes spin box for the stage rows: Omarchy's NumberField look, without
// its editable text control. The number is a plain Text and typing is handled
// key by key, so nothing in the box can take text from anywhere but the
// keyboard.
//
// 1. Digits go into `typed`, shown in place of the value until Enter applies
//    them or Escape drops them. Focus leaving applies them too. Nothing is
//    written while the user is still typing.
// 2. Keypad keys that arrive as navigation (KP_Up, KP_Home, KP_Insert…) are
//    typed as their digits. The shell often holds a stale "NumLock off" state:
//    Hyprland hands a window the modifier state of whichever keyboard last
//    produced a key, and fcitx5's virtual keyboard carries no NumLock, so the
//    numpad would otherwise step the value instead of typing into it.
// 3. Edits are committed after a short pause, so five clicks on the arrow
//    become one shell.json write instead of five.
//
// Letters are not taken: they go on to the panel's key catcher, so its
// shortcuts keep working while the field has focus.
//
// `shownValue` is the value from config; it is re-applied whenever it changes,
// which a plain `value:` binding would stop doing after the first user edit.
QQC.SpinBox {
  id: root

  property int shownValue: 0
  property color foreground: Commons.Color.foreground
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  property int commitDelayMs: 400
  readonly property bool hovering: hover.hovered
  readonly property bool hot: hovering
  readonly property var borderSpec: Border.controlSpec(activeFocus ? "focus" : (hot ? "hover-cursor" : "normal"), foreground, accent)

  signal committed(int value)

  property int pendingValue: 0
  // Digits typed since the field took focus or last applied them.
  property string typed: ""

  from: 1
  to: 1440
  editable: false
  // The box has no child that takes focus on its own; a click must give it to the box.
  focusPolicy: Qt.StrongFocus
  // implicitWidth, not width: inside the row's RowLayout only the implicit size counts.
  implicitWidth: Style.space(84)
  implicitHeight: Math.max(Style.spacing.controlHeight, Style.font.body + Style.spacing.controlPaddingY * 2)
  font.family: fontFamily
  font.pixelSize: Style.font.body
  Accessible.name: "Minutes"

  leftPadding: Border.left(borderSpec) + Style.spacing.controlPaddingX
  rightPadding: Border.right(borderSpec) + Style.spacing.controlPaddingX
  topPadding: Border.top(borderSpec)
  bottomPadding: Border.bottom(borderSpec)

  onShownValueChanged: value = shownValue
  Component.onCompleted: value = shownValue

  onValueModified: modified(value)
  onActiveFocusChanged: if (!activeFocus) applyTyped()

  function modified(v) {
    pendingValue = v
    commitTimer.restart()
  }

  // Makes the typed digits the value, within from…to. Nothing typed, nothing done.
  function applyTyped() {
    var text = typed
    typed = ""
    if (text === "") return
    var n = Math.min(to, Math.max(from, parseInt(text, 10)))
    if (n === value) return
    value = n
    modified(n)
  }

  // KP_Insert … KP_PageUp, as they arrive without NumLock, in keypad order 0–9.
  function keypadDigit(key) {
    switch (key) {
    case Qt.Key_Insert: return "0"
    case Qt.Key_End: return "1"
    case Qt.Key_Down: return "2"
    case Qt.Key_PageDown: return "3"
    case Qt.Key_Left: return "4"
    case Qt.Key_Clear: return "5"
    case Qt.Key_Right: return "6"
    case Qt.Key_Home: return "7"
    case Qt.Key_Up: return "8"
    case Qt.Key_PageUp: return "9"
    }
    return ""
  }

  // The digit a key press types, "" for any other key.
  function digitOf(event) {
    if (event.text.length === 1 && event.text >= "0" && event.text <= "9") return event.text
    if (event.modifiers & Qt.KeypadModifier) return keypadDigit(event.key)
    return ""
  }

  // Before the box itself, so a keypad Up without NumLock types 8 instead of stepping.
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier)) return
    var digit = digitOf(event)
    if (digit !== "") {
      // A leading 0 and anything above `to` are refused, so what is shown is
      // always a number the box can hold.
      var next = typed + digit
      if (next !== "0" && parseInt(next, 10) <= to) typed = next
      event.accepted = true
      return
    }
    switch (event.key) {
    case Qt.Key_Backspace:
      typed = typed.slice(0, -1)
      event.accepted = true
      return
    case Qt.Key_Return:
    case Qt.Key_Enter:
      applyTyped()
      event.accepted = true
      return
    case Qt.Key_Escape:
      // With nothing typed the key goes on to the panel, which closes on it.
      if (typed === "") return
      typed = ""
      event.accepted = true
      return
    case Qt.Key_Up:
    case Qt.Key_Down:
      // Step from the typed number, not from the value it replaces. The box
      // itself does the stepping once the key reaches it.
      applyTyped()
      return
    }
  }

  Timer {
    id: commitTimer
    interval: root.commitDelayMs
    onTriggered: root.committed(root.pendingValue)
  }

  background: BorderSurface {
    color: Style.controlFill(root.activeFocus, root.hot, root.foreground, root.accent)
    borderSpec: root.borderSpec
    radius: Style.cornerRadius

    HoverHandler { id: hover }
  }

  contentItem: Text {
    textFormat: Text.PlainText
    text: root.typed !== "" ? root.typed : root.displayText
    font: root.font
    color: root.foreground
    horizontalAlignment: Qt.AlignHCenter
    verticalAlignment: Qt.AlignVCenter
  }
}
