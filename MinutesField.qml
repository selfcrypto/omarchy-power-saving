import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui

// Minutes spin box for the stage rows: Omarchy's NumberField look, plus two
// things it lacks.
//
// 1. Keypad keys that arrive as navigation (KP_Up, KP_Home, KP_Insert…) are
//    typed as their digits. The shell often holds a stale "NumLock off" state:
//    Hyprland hands a window the modifier state of whichever keyboard last
//    produced a key, and fcitx5's virtual keyboard carries no NumLock, so the
//    numpad would otherwise step the value instead of typing into it.
// 2. Edits are committed after a short pause, so five clicks on the arrow
//    become one shell.json write instead of five.
//
// `shownValue` is the value from config; it is re-applied whenever it changes,
// which a plain `value:` binding would stop doing after the first user edit.
QQC.SpinBox {
  id: root

  property int shownValue: 0
  property color foreground: Color.foreground
  property color accent: Color.accent
  property string fontFamily: Style.font.family
  property int commitDelayMs: 400
  readonly property bool hovering: hover.hovered
  readonly property bool hot: hovering
  readonly property var borderSpec: Border.controlSpec(activeFocus ? "focus" : (hot ? "hover-cursor" : "normal"), foreground, accent)

  signal committed(int value)

  property int pendingValue: 0

  from: 1
  to: 1440
  editable: true
  // implicitWidth, not width: inside the row's RowLayout only the implicit size counts.
  implicitWidth: Style.space(84)
  implicitHeight: Math.max(Style.spacing.controlHeight, Style.font.body + Style.spacing.controlPaddingY * 2)
  font.family: fontFamily
  font.pixelSize: Style.font.body

  leftPadding: Border.left(borderSpec) + Style.spacing.controlPaddingX
  rightPadding: Border.right(borderSpec) + Style.spacing.controlPaddingX
  topPadding: Border.top(borderSpec)
  bottomPadding: Border.bottom(borderSpec)

  onShownValueChanged: value = shownValue
  Component.onCompleted: value = shownValue

  onValueModified: {
    pendingValue = value
    commitTimer.restart()
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

  contentItem: TextInput {
    id: input
    text: root.displayText
    font: root.font
    color: root.foreground
    selectionColor: Style.selectionFillFor(root.foreground, root.accent)
    selectedTextColor: root.foreground
    horizontalAlignment: Qt.AlignHCenter
    verticalAlignment: Qt.AlignVCenter
    readOnly: !root.editable
    validator: root.validator
    inputMethodHints: Qt.ImhFormattedNumbersOnly

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
      if (!(event.modifiers & Qt.KeypadModifier)) return
      var digit = root.keypadDigit(event.key)
      if (digit === "") return
      if (input.selectionStart !== input.selectionEnd) input.remove(input.selectionStart, input.selectionEnd)
      input.insert(input.cursorPosition, digit)
      event.accepted = true
    }
  }
}
