import AppKit

final class GraphiteFocusCollectionRow: NSButton {
    enum Emphasis {
        case standard
        case attention
        case proposal
    }

    private let invoke: () -> Void

    init(
        style: GraphiteFocusControlStyle = GraphiteFocusControlStyle(),
        symbol: String,
        title: String,
        metadata: String,
        emphasis: Emphasis = .standard,
        actionTitle: String = "Open",
        action: @escaping () -> Void
    ) {
        invoke = action
        super.init(frame: .zero)
        self.title = ""
        target = self
        self.action = #selector(activate)
        isBordered = false
        focusRingType = .default
        setButtonType(.momentaryChange)
        setAccessibilityLabel("\(title). \(metadata). \(actionTitle)")

        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: nil))
        let symbolLabel = NSTextField(labelWithString: symbol)
        symbolLabel.font = GraphiteFocusPresentation.Typography.control
        symbolLabel.textColor = emphasis == .attention ? colors.attention : (emphasis == .proposal ? colors.informational : colors.textMetadata)
        symbolLabel.alignment = .center
        symbolLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        GraphiteFocusRowStyle.title(titleLabel, colors: colors)
        titleLabel.maximumNumberOfLines = 2
        let metadataLabel = NSTextField(wrappingLabelWithString: metadata)
        GraphiteFocusRowStyle.metadata(metadataLabel, colors: colors)
        metadataLabel.maximumNumberOfLines = 2
        let labels = NSStackView(views: [titleLabel, metadataLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = GraphiteFocusPresentation.Space.primitive
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actionLabel = NSTextField(labelWithString: actionTitle)
        actionLabel.font = style.font
        actionLabel.textColor = colors.accent

        let row = NSStackView(views: [symbolLabel, labels, actionLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = GraphiteFocusPresentation.Space.dense
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphiteFocusPresentation.Space.compact),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GraphiteFocusPresentation.Space.compact),
            row.topAnchor.constraint(equalTo: topAnchor, constant: GraphiteFocusPresentation.Space.dense),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -GraphiteFocusPresentation.Space.dense),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 48)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // The labels/stack draw the button; the button owns pointer activation.
        super.hitTest(point) == nil ? nil : self
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            performClick(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func activate() {
        invoke()
    }
}
