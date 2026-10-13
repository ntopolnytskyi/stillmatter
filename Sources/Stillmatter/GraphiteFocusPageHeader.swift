import AppKit

/// Shared Graphite Focus Page Header behavior for a title with optional local actions.
///
/// The title is a single line that truncates at the tail and yields horizontal space to
/// a noncompressing action cluster. Callers still own the surrounding document layout
/// and the action controls themselves.
enum GraphiteFocusPageHeader {
    static func configureTitleLabel(_ label: NSTextField, font: NSFont = GraphiteFocusPresentation.Typography.pageTitle) {
        label.font = font
        GraphiteFocusOverflow.configurePrimaryTitle(label, fullText: label.stringValue)
    }

    static func setTitle(_ title: String, on label: NSTextField) {
        label.stringValue = title
        GraphiteFocusOverflow.configurePrimaryTitle(label, fullText: title)
    }

    static func protectActionCluster(_ actions: NSView) {
        actions.setContentHuggingPriority(.required, for: .horizontal)
        actions.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    static func makeTitleAndActionsRow(title titleView: NSView, actions: NSView?) -> NSStackView {
        titleView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let actions { protectActionCluster(actions) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = GraphiteFocusPresentation.Space.compact
        row.distribution = .fill
        row.addArrangedSubview(titleView)
        if let actions {
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(actions)
            actions.trailingAnchor.constraint(equalTo: row.trailingAnchor).isActive = true
        }
        row.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return row
    }
}
