import AppKit
import SwiftUI

/// Measures a SwiftUI section at its actual AppKit column width. NSHostingView's
/// unconstrained intrinsic size treats long prose as one line, leaving its text
/// painted over the following section despite the view being width-constrained.
final class MeetingOverviewHostingView: NSHostingView<MeetingOverviewSection> {
    private var measured: (width: CGFloat, height: CGFloat)?
    private var lastLayoutWidth: CGFloat = 0

    func update(_ section: MeetingOverviewSection) {
        rootView = section
        measured = nil
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let width = bounds.width
        guard width > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: super.intrinsicContentSize.height)
        }
        if let measured, abs(measured.width - width) < 0.5 {
            return NSSize(width: NSView.noIntrinsicMetric, height: measured.height)
        }
        let height = ceil(NSHostingController(rootView: rootView).sizeThatFits(
            in: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height)
        measured = (width, height)
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        if abs(width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = width
            measured = nil
            invalidateIntrinsicContentSize()
        }
    }
}
