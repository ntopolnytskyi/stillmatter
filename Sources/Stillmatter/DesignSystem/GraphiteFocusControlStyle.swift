import AppKit

/// Native defaults preserve the existing forms; one style can be shared by every consumer.
struct GraphiteFocusControlStyle {
    var font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    var controlSize: NSControl.ControlSize = .regular
}
