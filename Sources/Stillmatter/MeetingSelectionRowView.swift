import AppKit

/// Neutral selection keeps Meeting status colors legible and distinct from selection.
final class MeetingSelectionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        colors.surfaceSelectionNeutral.setFill()
        bounds.fill()
    }
}
