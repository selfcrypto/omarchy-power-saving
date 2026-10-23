import QtQuick
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "IdleModel.js" as IdleModel

// The stages in the order they fire: one stop per stage, sorted by timeout,
// evenly spaced. A stage that is on is a filled dot; one that is off is a ring
// at its own time. Stages that are on and the line between them are in the
// accent, also while stay awake pauses them; the line is faint outside that
// span. Clicking a stop turns its stage on or off.
Rectangle {
  id: root

  // [{ key, glyph, number, enabled, seconds, note }] in any order; `note`,
  // when set, is a caption under the time.
  property var stages: []
  // One line above the stops; empty hides it.
  property string status: ""
  // One quiet line under the stops; empty hides it.
  property string caption: ""
  property bool available: true
  property color foreground: Commons.Color.popups.text
  property color accent: Commons.Color.accent
  property string fontFamily: Style.font.family
  readonly property color secondary: Util.alpha(foreground, 0.6)
  readonly property color faint: Util.alpha(foreground, 0.16)

  signal stageClicked(string key)

  // By timeout; equal times keep the panel's order.
  readonly property var ordered: {
    var list = stages.slice()
    for (var i = 0; i < list.length; i++) list[i] = Object.assign({ order: i }, list[i])
    list.sort(function(a, b) { return a.seconds - b.seconds || a.order - b.order })
    return list
  }
  readonly property int firstOn: {
    for (var i = 0; i < ordered.length; i++) if (ordered[i].enabled) return i
    return -1
  }
  readonly property int lastOn: {
    for (var i = ordered.length - 1; i >= 0; i--) if (ordered[i].enabled) return i
    return -1
  }
  readonly property real cell: ordered.length ? stops.width / ordered.length : 0
  readonly property real dot: Style.space(9)

  implicitHeight: content.implicitHeight + Style.space(24)
  color: Style.normalFillFor(foreground, accent)
  radius: Style.cornerRadius

  Column {
    id: content
    x: Style.space(12)
    y: Style.space(12)
    width: parent.width - Style.space(24)
    spacing: Style.space(10)

    Text {
      visible: root.status !== ""
      width: parent.width
      textFormat: Text.PlainText
      text: root.status
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      wrapMode: Text.WordWrap
    }

    Item {
      id: stops
      width: parent.width
      height: stopRow.implicitHeight

      // Segments between neighbouring stops, behind the dots.
      Repeater {
        model: Math.max(0, root.ordered.length - 1)

        delegate: Rectangle {
          required property int index
          readonly property bool live: root.available
            && root.firstOn >= 0 && index >= root.firstOn && index + 1 <= root.lastOn
          x: (index + 0.5) * root.cell + root.dot / 2 + Style.space(4)
          y: glyphProbe.height + Style.space(4) + root.dot / 2 - height / 2
          width: Math.max(0, root.cell - root.dot - Style.space(8))
          height: live ? 2 : 1
          radius: height / 2
          color: live ? root.accent : root.faint
        }
      }

      Row {
        id: stopRow
        width: parent.width

        Repeater {
          model: root.ordered

          delegate: Item {
            id: stop
            required property var modelData
            readonly property bool armed: root.available && modelData.enabled
            width: root.cell
            implicitHeight: stopColumn.implicitHeight

            Column {
              id: stopColumn
              width: parent.width
              spacing: Style.space(4)

              Text {
                width: parent.width
                text: stop.modelData.glyph
                color: stop.armed ? root.accent : root.secondary
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
                horizontalAlignment: Text.AlignHCenter
              }

              Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: root.dot
                height: width
                radius: width / 2
                color: stop.armed ? root.accent : "transparent"
                border.width: stop.armed ? 0 : 1
                border.color: root.secondary
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: IdleModel.durationText(stop.modelData.seconds)
                color: stop.armed ? root.foreground : root.secondary
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.strikeout: !stop.armed
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
              }

              Text {
                visible: !!stop.modelData.note
                width: parent.width
                textFormat: Text.PlainText
                text: stop.modelData.note || ""
                color: root.secondary
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
              }
            }

            MouseArea {
              id: stopMouse
              anchors.fill: parent
              enabled: root.available
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.stageClicked(stop.modelData.key)
            }

            PanelToolTip {
              visible: stopMouse.containsMouse
              text: IdleModel.stageLabel(stop.modelData.key) + (stop.armed
                ? " after " + IdleModel.durationText(stop.modelData.seconds) + " idle · " + stop.modelData.number + " turns it off"
                : " is off · " + stop.modelData.number + " turns it on")
              fontFamily: root.fontFamily
            }
          }
        }
      }

      // Height of the glyph line, to put the segments level with the dots.
      Text {
        id: glyphProbe
        visible: false
        text: "0"
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
    }

    Text {
      visible: root.caption !== ""
      width: parent.width
      textFormat: Text.PlainText
      text: root.caption
      color: root.secondary
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      horizontalAlignment: Text.AlignHCenter
      wrapMode: Text.WordWrap
    }
  }
}
