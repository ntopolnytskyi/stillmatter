import AppKit

/// Shared Graphite Focus overflow behavior for long titles, metadata, prose,
/// status explanations, and rows that also contain local controls.
enum GraphiteFocusOverflow {
    static func configurePrimaryTitle(_ label: NSTextField, fullText: String) {
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        exposeFullText(label, fullText)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    static func configureSecondaryMetadata(_ label: NSTextField, fullText: String, lineBreakMode: NSLineBreakMode = .byTruncatingMiddle) {
        label.maximumNumberOfLines = 1
        label.lineBreakMode = lineBreakMode
        exposeFullText(label, fullText)
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    static func configureWrappingText(_ label: NSTextField, fullText: String? = nil) {
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let fullText { exposeFullText(label, fullText) }
    }

    static func protectTrailingControl(_ control: NSView) {
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    static func exposeFullText(_ view: NSView, _ fullText: String) {
        view.toolTip = fullText
        view.setAccessibilityLabel(fullText)
    }
}
