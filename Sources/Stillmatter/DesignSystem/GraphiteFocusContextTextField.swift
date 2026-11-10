import AppKit

/// Selectable read-only text whose contextual actions belong to the containing row.
/// NSTextField's default right-click handling can otherwise use the field editor's menu.
final class GraphiteFocusContextTextField: NSTextField {
    override func rightMouseDown(with event: NSEvent) {
        if let menu { NSMenu.popUpContextMenu(menu, with: event, for: self) }
        else { super.rightMouseDown(with: event) }
    }
}
