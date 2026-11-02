import AppKit

/// Native defaults preserve the existing forms; one style can be shared by every consumer.
struct GraphiteFocusControlStyle {
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize) // graphite-focus-native-exception: preserve AppKit default typography for standard form controls
    var controlSize: NSControl.ControlSize = .regular
}
