import AppKit

/// Honest current-state Reports canvas. Report discovery can replace this content state later
/// without changing shell ownership or inventing unsupported browsing behavior now.
final class ReportsView: NSView {
    enum State {
        case available
        case unavailable(String)
    }

    private let stateProvider: () -> State
    private let onOpenToday: () -> Void
    private let onOpenSettings: () -> Void
    private let stateStack = NSStackView()
    private let symbolLabel = NSTextField(labelWithString: "ⓘ")
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private var metadataLabels: [NSTextField] = []

    init(
        stateProvider: @escaping () -> State,
        onOpenToday: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.stateProvider = stateProvider
        self.onOpenToday = onOpenToday
        self.onOpenSettings = onOpenSettings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
        render(stateProvider())
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        symbolLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        GraphiteFocusPageHeader.configureTitleLabel(titleLabel, font: GraphiteFocusPresentation.Typography.sectionHeading)
        messageLabel.font = GraphiteFocusPresentation.Typography.body
        GraphiteFocusOverflow.configureWrappingText(messageLabel, fullText: "")
        actionButton.target = self
        actionButton.action = #selector(performRecoveryAction(_:))

        let dailyBrief = capabilityRow(
            title: "Daily Brief",
            status: "Available in Today",
            explanation: "Temporary planning context remains part of the Today workbench."
        )
        let weeklyReport = capabilityRow(
            title: "Weekly Report",
            status: "Available when scheduled",
            explanation: "Review is editable and requires explicit Accept or Remind next time."
        )

        stateStack.orientation = .vertical
        stateStack.alignment = .leading
        stateStack.spacing = GraphiteFocusPresentation.Space.dense
        [symbolLabel, titleLabel, messageLabel, dailyBrief, weeklyReport, actionButton].forEach(stateStack.addArrangedSubview)
        stateStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateStack)

        NSLayoutConstraint.activate([
            stateStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stateStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stateStack.topAnchor.constraint(equalTo: topAnchor),
            stateStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    func refresh(isVisible: Bool) {
        isHidden = !isVisible
        guard isVisible else { return }
        render(stateProvider())
        applyPresentation()
    }

    private func render(_ state: State) {
        switch state {
        case .available:
            symbolLabel.stringValue = "ⓘ"
            GraphiteFocusPageHeader.setTitle("Report browsing is not available yet", on: titleLabel)
            messageLabel.stringValue = "Daily Briefs remain available from Today. Stillmatter presents a Weekly Report in a focused editable review window when one is due. A report browser and historical report discovery are not implemented yet."
            GraphiteFocusOverflow.configureWrappingText(messageLabel, fullText: messageLabel.stringValue)
            actionButton.title = "Open Today"
            actionButton.identifier = NSUserInterfaceItemIdentifier("Reports.OpenToday")
        case let .unavailable(reason):
            symbolLabel.stringValue = "!"
            GraphiteFocusPageHeader.setTitle("Reports are unavailable", on: titleLabel)
            messageLabel.stringValue = "\(reason) Configure the workspace, then return to Reports. Report browsing and historical discovery are not implemented yet."
            GraphiteFocusOverflow.configureWrappingText(messageLabel, fullText: messageLabel.stringValue)
            actionButton.title = "Open Settings"
            actionButton.identifier = NSUserInterfaceItemIdentifier("Reports.OpenSettings")
        }
        actionButton.setAccessibilityLabel(actionButton.title)
        stateStack.setAccessibilityLabel("Reports. \(titleLabel.stringValue). \(messageLabel.stringValue)")
    }

    private func capabilityRow(title: String, status: String, explanation: String) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = GraphiteFocusPresentation.Typography.rowTitle
        let statusLabel = NSTextField(labelWithString: "ⓘ \(status)")
        statusLabel.font = GraphiteFocusPresentation.Typography.metadata
        let explanationLabel = NSTextField(wrappingLabelWithString: explanation)
        explanationLabel.font = GraphiteFocusPresentation.Typography.metadata
        GraphiteFocusOverflow.configureWrappingText(explanationLabel, fullText: explanation)
        metadataLabels.append(contentsOf: [statusLabel, explanationLabel])
        let row = NSStackView(views: [titleLabel, statusLabel, explanationLabel])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = GraphiteFocusPresentation.Space.primitive
        row.setAccessibilityLabel("\(title). \(status). \(explanation)")
        return row
    }

    @objc private func performRecoveryAction(_ sender: NSButton) {
        if sender.identifier?.rawValue == "Reports.OpenSettings" {
            onOpenSettings()
        } else {
            onOpenToday()
        }
    }

    func applyPresentation() {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        symbolLabel.textColor = titleLabel.stringValue == "Reports are unavailable" ? colors.destructive : colors.informational
        messageLabel.textColor = colors.textSecondary
        metadataLabels.enumerated().forEach { index, label in
            label.textColor = index.isMultiple(of: 2) ? colors.informational : colors.textMetadata
        }
    }

    func validateFixtures() {
        render(.available)
        precondition(!titleLabel.stringValue.lowercased().contains("placeholder"), "Reports must not use placeholder prose")
        precondition(messageLabel.stringValue.contains("Daily Briefs") && messageLabel.stringValue.contains("Weekly Report"), "Reports Content State must explain current capabilities")
        precondition(messageLabel.stringValue.contains("not implemented"), "Reports must honestly name unavailable discovery")
        precondition(actionButton.title == "Open Today", "Available Reports state must provide a useful next action")
        render(.unavailable("Choose an Stillmatter root."))
        precondition(titleLabel.stringValue == "Reports are unavailable" && actionButton.title == "Open Settings", "Unavailable Reports state must name prerequisites and recovery")
        let longReportTitle = "Weekly Report for a deliberately long planning period title with translated-looking quarter names Планування наступного кварталу that must truncate at the tail without losing the complete title to VoiceOver"
        GraphiteFocusPageHeader.setTitle(longReportTitle, on: titleLabel)
        precondition(titleLabel.maximumNumberOfLines == 1 && titleLabel.lineBreakMode == .byTruncatingTail,
                     "Reports Page Header title must be a single tail-truncated line")
        precondition(titleLabel.toolTip == longReportTitle && titleLabel.accessibilityLabel() == longReportTitle,
                     "Reports Page Header title must expose the complete report title")
        precondition(stateStack.accessibilityLabel()?.contains("Reports") == true, "Reports Content State must expose static accessibility meaning")
        render(stateProvider())
    }
}
