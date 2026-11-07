pragma Singleton
import QtQuick

// Shim for omarchy-shell's qs.Commons Style.
QtObject {
  component FontSpec: QtObject {
    property string family
    property int body
  }
  readonly property FontSpec font: FontSpec {
    family: Qt.application.font.family
    body: Math.max(11, Qt.application.font.pixelSize > 0 ? Qt.application.font.pixelSize : 13)
  }
  readonly property int cornerRadius: 10
  function space(n) { return Math.round(Number(n) || 0) }
  function spaceReal(n) { return Number(n) || 0 }
}
