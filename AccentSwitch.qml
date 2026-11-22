import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// On/off switch with the size and off look of the shell's ToggleSwitch and an
// accent track when on. The stock switch takes its on color from the theme's
// `selected-color`, which the generated shell.toml writes as the foreground
// hex, so it cannot be given the accent from outside.
Item {
  id: root

  property bool checked: false
  // An operation in flight: clicks are swallowed, hover and tooltips stay.
  property bool busy: false
  property bool interactive: true
  property color foreground: Commons.Color.popups.text
  property color accent: Commons.Color.accent
  // Knob color when on: the surface behind the switch, so it reads on the accent.
  property color surface: Commons.Color.popups.background
  property bool rounded: Style.cornerRadius > 0

  signal toggled()

  readonly property alias containsMouse: mouse.containsMouse
  readonly property bool mirrored: LayoutMirroring.enabled

  readonly property int trackHeight: Math.max(22, Math.round(Style.spacing.controlHeight * 0.55))
  readonly property int trackWidth: Math.round(trackHeight * 1.9)
  readonly property int knobSize: Math.max(6, Math.round(trackHeight * 0.72))
  readonly property int knobInset: Math.max(1, Math.round((trackHeight - knobSize) / 2))
  readonly property int pad: interactive ? Style.space(6) : 0

  implicitWidth: trackWidth + pad * 2
  implicitHeight: trackHeight + pad * 2

  BorderSurface {
    anchors.fill: parent
    visible: root.interactive && mouse.containsMouse
    color: "transparent"
    radius: Style.cornerRadius
    borderSpec: Border.controlSpec("hover-cursor", root.foreground, root.accent)
  }

  BorderSurface {
    id: track
    width: root.trackWidth
    height: root.trackHeight
    anchors.centerIn: parent
    radius: root.rounded ? height / 2 : 0
    color: root.checked ? root.accent : Style.normalFillFor(root.foreground, root.accent)
    borderSpec: root.checked ? Border.flat(root.accent, 1) : Border.controlSpec("normal", root.foreground, root.accent)

    Behavior on color { ColorAnimation { duration: Style.duration(120) } }

    Rectangle {
      width: root.knobSize
      height: root.knobSize
      radius: root.rounded ? height / 2 : 0
      x: root.checked !== root.mirrored ? track.width - width - root.knobInset : root.knobInset
      anchors.verticalCenter: parent.verticalCenter
      color: root.checked ? root.surface : Qt.darker(root.foreground, 1.25)

      Behavior on x { NumberAnimation { duration: Style.duration(120); easing.type: Easing.OutCubic } }
      Behavior on color { ColorAnimation { duration: Style.duration(120) } }
    }
  }

  MouseArea {
    id: mouse
    anchors.fill: parent
    enabled: root.interactive
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    onClicked: if (!root.busy) root.toggled()
  }
}
