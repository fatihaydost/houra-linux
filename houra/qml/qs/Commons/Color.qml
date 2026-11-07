pragma Singleton
import QtQuick

// Shim for omarchy-shell's qs.Commons Color, backed by the system palette.
QtObject {
  readonly property SystemPalette _pal: SystemPalette { colorGroup: SystemPalette.Active }
  readonly property color background: _pal.window
  readonly property color foreground: _pal.windowText
  readonly property color accent: _pal.highlight
  readonly property color urgent: "#e06458"
  component Popups: QtObject {
    property color text
  }
  readonly property Popups popups: Popups { text: _pal.windowText }
}
