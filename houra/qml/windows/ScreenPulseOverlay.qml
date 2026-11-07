import QtQuick
import QtQml
import Houra.Shell

// Multi-monitor click-through screen pulse matching Widgets.swift:256-277:
// 3 equal 0.3s autoreversing pulses (1.8s total) with 22% white fill + 90% 8px border.
Scope {
  id: root

  property bool active: false
  property real pulseAlpha: 0.0

  function flash() {
    pulseAnim.stop()
    active = true
    pulseAnim.start()
  }

  SequentialAnimation {
    id: pulseAnim
    loops: 1
    NumberAnimation { target: root; property: "pulseAlpha"; from: 0.0; to: 1.0; duration: 300; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseAlpha"; from: 1.0; to: 0.0; duration: 300; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseAlpha"; from: 0.0; to: 1.0; duration: 300; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseAlpha"; from: 1.0; to: 0.0; duration: 300; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseAlpha"; from: 0.0; to: 1.0; duration: 300; easing.type: Easing.InOutSine }
    NumberAnimation { target: root; property: "pulseAlpha"; from: 1.0; to: 0.0; duration: 300; easing.type: Easing.InOutSine }
    ScriptAction { script: root.active = false }
  }

  Instantiator {
    model: root.active ? Qt.application.screens : [] // qmllint disable missing-property

    delegate: Component {
      LayerWindow {
        required property var modelData
        screen: modelData
        shown: root.active
        scope: "houra-screen-pulse"
        layer: "overlay"
        // A zero-size rect = empty input region: the pulse never takes clicks
        inputRects: [{ x: 0, y: 0, width: 0, height: 0 }]

        Rectangle {
          anchors.fill: parent
          color: Qt.rgba(1, 1, 1, 0.22 * root.pulseAlpha)
          border.width: 8
          border.color: Qt.rgba(1, 1, 1, 0.90 * root.pulseAlpha)
        }
      }
    }
  }
}
