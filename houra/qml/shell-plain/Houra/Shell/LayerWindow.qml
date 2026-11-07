import QtQuick

// Fallback for compositors without wlr-layer-shell (e.g. GNOME): a frameless,
// always-on-top window covering the screen, click-through outside `inputRects`.
Window {
  id: win
  property bool shown: false
  property string layer: "top"
  property string scope: "houra"
  property string keyboardFocus: "none"
  property var inputRects: []

  visible: shown
  color: "transparent"
  flags: Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
    | (keyboardFocus === "none" ? Qt.WindowDoesNotAcceptFocus : 0)
  x: screen ? screen.virtualX : 0
  y: screen ? screen.virtualY : 0
  width: screen ? screen.width : 1280
  height: screen ? screen.height : 720

  function _applyMask() { if (visible) Host.setInputMask(win, inputRects) }
  onInputRectsChanged: _applyMask()
  onWidthChanged: _applyMask()
  onHeightChanged: _applyMask()
  onVisibleChanged: _applyMask()
}
