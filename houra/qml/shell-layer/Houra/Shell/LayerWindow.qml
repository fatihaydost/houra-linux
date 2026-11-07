import QtQuick
import org.kde.layershell 1.0 as LS

// Full-output wlr-layer-shell surface. Always anchored to all four edges:
// tiling scripts (e.g. Krohnkite) re-center partially anchored layer surfaces.
// Clicks only reach the rects in `inputRects`; everything else passes through.
Window {
  id: win
  property bool shown: false
  property string layer: "top"          // "top" | "overlay"
  property string scope: "houra"
  property string keyboardFocus: "none" // "none" | "exclusive" | "ondemand"
  property var inputRects: []           // [] = whole window takes input

  visible: false
  color: "transparent"
  flags: Qt.FramelessWindowHint
  // Qt re-picks the QScreen from the window position (default 0,0 = leftmost output),
  // and layer-shell-qt binds the surface to that QScreen: keep the geometry on our screen.
  x: screen ? screen.virtualX : 0
  y: screen ? screen.virtualY : 0
  width: screen ? screen.width : 1280
  height: screen ? screen.height : 720

  LS.Window.layer: layer === "overlay" ? LS.Window.LayerOverlay : LS.Window.LayerTop
  LS.Window.anchors: LS.Window.AnchorLeft | LS.Window.AnchorRight | LS.Window.AnchorTop | LS.Window.AnchorBottom
  LS.Window.exclusionZone: -1
  LS.Window.keyboardInteractivity: keyboardFocus === "exclusive" ? LS.Window.KeyboardInteractivityExclusive
    : keyboardFocus === "ondemand" ? LS.Window.KeyboardInteractivityOnDemand
    : LS.Window.KeyboardInteractivityNone
  LS.Window.scope: scope

  function _applyMask() { if (visible) Host.setInputMask(win, inputRects) }
  onInputRectsChanged: _applyMask()
  onWidthChanged: _applyMask()
  onHeightChanged: _applyMask()
  onVisibleChanged: _applyMask()
  onShownChanged: visible = shown
  // A layer surface is bound to its output when mapped: remap on screen change
  onScreenChanged: if (visible) { visible = false; visible = Qt.binding(function() { return win.shown }) }
  Component.onCompleted: visible = shown
}
