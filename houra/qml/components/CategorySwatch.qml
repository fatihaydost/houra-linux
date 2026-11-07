import QtQuick
import QtQuick.Shapes
import "../Theme.js" as Theme
import "../IconData.js" as IconData

Rectangle {
  id: root

  property int swatchSize: 22
  property string swatchColor: "#4c8df0"
  property string emoji: ""
  property string iconName: ""
  property string iconColor: ""

  readonly property string svgPath: IconData.pathFor(iconName)
  readonly property color resolvedGlyphColor: iconColor !== "" ? iconColor : Theme.inkOn(swatchColor)
  // A glyph under ~12 px is an unreadable speck: swatches that show one never go below 16 px
  readonly property bool hasGlyph: emoji !== "" || svgPath !== ""
  readonly property int boxSize: hasGlyph ? Math.max(16, swatchSize) : swatchSize
  readonly property real glyphDim: Math.max(12, Math.round(boxSize * 0.60))

  implicitWidth: boxSize
  implicitHeight: boxSize
  width: boxSize
  height: boxSize
  radius: Math.max(3, Math.round(boxSize * 0.32))
  color: swatchColor || "#4c8df0"

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    visible: root.emoji !== ""
    text: root.emoji
    font.pixelSize: Math.max(11, Math.round(root.boxSize * 0.56))
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
  }

  Shape {
    anchors.centerIn: parent
    width: root.glyphDim
    height: root.glyphDim
    visible: root.emoji === "" && root.svgPath !== ""
    preferredRendererType: Shape.CurveRenderer

    ShapePath {
      strokeWidth: 0
      strokeColor: "transparent"
      fillColor: root.resolvedGlyphColor
      scale: Qt.size(root.glyphDim / 256.0, root.glyphDim / 256.0)

      PathSvg {
        path: root.svgPath
      }
    }
  }
}
