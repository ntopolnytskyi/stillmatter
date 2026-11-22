import AppKit

/// Hidden shell regions stay attached for reuse, but must not leave dividers over a full-width page.
final class WorkspaceSplitView: NSSplitView {
    override func drawDivider(in rect: NSRect) {
        guard arrangedSubviews.filter({ !$0.isHidden }).count > 1 else { return }
        super.drawDivider(in: rect)
    }
}
