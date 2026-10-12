import AppKit

/// Neutral selection keeps Meeting status colors legible and distinct from selection.
final class MeetingSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        GraphiteFocusPresentation.Colors(environment: .system(window: window)).surfaceSelectionNeutral.setFill()
        bounds.fill()
    }
}
