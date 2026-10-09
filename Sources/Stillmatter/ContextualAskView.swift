import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Focused question, answer, and evidence workspace for ephemeral Contextual Ask requests.
final class ContextualAskView: NSView {
    private let serviceProvider: () -> ContextualAskService?
    private let queue = DispatchQueue(label: "Stillmatter.ContextualAsk", qos: .userInitiated)
    private let availableContexts = ContextualAskContext.allCases.filter { $0 != .settings }
    private let contextPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let questionField = NSTextField()
    private let broaderVaultCheckbox = NSButton(checkboxWithTitle: "Include broader vault", target: nil, action: nil)
    private let askButton = NSButton(title: "Ask", target: nil, action: nil)
    private let privacyLabel = NSTextField(wrappingLabelWithString: "Remote processing: only retrieved excerpts visible below are sent to pi/Codex. Contextual Ask cannot modify workspace files.")
    private let statusLabel = NSTextField(wrappingLabelWithString: "Ready. Ask a question about the selected workspace context.")
    private let answerLabel = NSTextField(wrappingLabelWithString: "")
    private let evidenceStack = NSStackView()
    private weak var requestInvoker: NSResponder?
    private var statusMeaning: GraphiteFocusStatusMeaning = .informational

    init(serviceProvider: @escaping () -> ContextualAskService?) {
        self.serviceProvider = serviceProvider
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        let heading = NSTextField(labelWithString: "Ask your workspace")
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading

        let contextLabel = NSTextField(labelWithString: "Search context")
        contextLabel.font = GraphiteFocusPresentation.Typography.control
        availableContexts.forEach { contextPopup.addItem(withTitle: $0.displayName) }
        contextPopup.selectItem(at: availableContexts.firstIndex(of: .today) ?? 0)
        contextPopup.setAccessibilityLabel("Contextual Ask search context")
        contextPopup.identifier = NSUserInterfaceItemIdentifier("contextual-ask-context")

        let contextSpacer = NSView()
        contextSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let contextControls = NSStackView(views: [contextLabel, contextPopup, contextSpacer])
        contextControls.orientation = .horizontal
        contextControls.alignment = .centerY
        contextControls.spacing = GraphiteFocusPresentation.Space.compact

        privacyLabel.identifier = NSUserInterfaceItemIdentifier("ContextualAsk.PrivacyDisclosure")
        privacyLabel.textColor = colors.textMetadata
        privacyLabel.font = GraphiteFocusPresentation.Typography.metadata
        privacyLabel.maximumNumberOfLines = 0
        privacyLabel.setAccessibilityLabel("Remote processing disclosure")

        questionField.placeholderString = "Ask about the current context…"
        questionField.target = self
        questionField.action = #selector(ask)
        questionField.setAccessibilityLabel("Contextual Ask question")
        questionField.identifier = NSUserInterfaceItemIdentifier("contextual-ask-question")

        broaderVaultCheckbox.target = self
        broaderVaultCheckbox.action = #selector(broaderVaultChanged(_:))
        broaderVaultCheckbox.toolTip = "Off keeps retrieval scoped to the selected context. Turn on to search all indexed Stillmatter content."
        broaderVaultCheckbox.setAccessibilityLabel("Include broader vault")
        broaderVaultCheckbox.identifier = NSUserInterfaceItemIdentifier("contextual-ask-broader-vault")
        updateBroaderVaultAccessibility()

        askButton.target = self
        askButton.action = #selector(ask)
        askButton.keyEquivalent = "\r"
        askButton.contentTintColor = colors.accent
        askButton.setAccessibilityLabel("Ask Contextual Ask")
        askButton.identifier = NSUserInterfaceItemIdentifier("contextual-ask-submit")

        let controlsSpacer = NSView()
        controlsSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [broaderVaultCheckbox, controlsSpacer, askButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = GraphiteFocusPresentation.Space.compact

        statusLabel.font = GraphiteFocusPresentation.Typography.metadata
        statusLabel.textColor = colors.textSecondary
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setAccessibilityLabel("Contextual Ask status")
        statusLabel.identifier = NSUserInterfaceItemIdentifier("contextual-ask-status")

        let answerHeading = NSTextField(labelWithString: "Answer")
        answerHeading.font = GraphiteFocusPresentation.Typography.sectionHeading
        answerLabel.font = GraphiteFocusPresentation.Typography.longForm
        answerLabel.maximumNumberOfLines = 0
        answerLabel.isSelectable = true
        answerLabel.textColor = colors.textPrimary
        answerLabel.setAccessibilityLabel("Contextual Ask answer")
        answerLabel.identifier = NSUserInterfaceItemIdentifier("contextual-ask-answer")

        evidenceStack.orientation = .vertical
        evidenceStack.alignment = .width
        evidenceStack.spacing = GraphiteFocusPresentation.Space.compact

        let resultsStack = NSStackView(views: [answerHeading, answerLabel, evidenceStack])
        resultsStack.orientation = .vertical
        resultsStack.alignment = .leading
        resultsStack.spacing = GraphiteFocusPresentation.Space.dense
        resultsStack.translatesAutoresizingMaskIntoConstraints = false

        let resultsDocument = ContextualAskResultsDocumentView()
        resultsDocument.translatesAutoresizingMaskIntoConstraints = false
        resultsDocument.addSubview(resultsStack)

        let resultsScrollView = NSScrollView()
        resultsScrollView.hasVerticalScroller = true
        resultsScrollView.autohidesScrollers = true
        resultsScrollView.drawsBackground = false
        resultsScrollView.borderType = .noBorder
        resultsScrollView.documentView = resultsDocument
        resultsScrollView.translatesAutoresizingMaskIntoConstraints = false

        let requestStack = NSStackView(views: [heading, contextControls, questionField, controls, privacyLabel, statusLabel])
        requestStack.orientation = .vertical
        requestStack.alignment = .leading
        requestStack.spacing = GraphiteFocusPresentation.Space.compact

        let workspace = NSStackView(views: [requestStack, resultsScrollView])
        workspace.orientation = .vertical
        workspace.alignment = .leading
        workspace.spacing = GraphiteFocusPresentation.Space.panel
        workspace.translatesAutoresizingMaskIntoConstraints = false
        addSubview(workspace)

        let fillAvailableWidth = workspace.trailingAnchor.constraint(equalTo: trailingAnchor)
        fillAvailableWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            workspace.leadingAnchor.constraint(equalTo: leadingAnchor),
            fillAvailableWidth,
            workspace.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            workspace.topAnchor.constraint(equalTo: topAnchor),
            workspace.bottomAnchor.constraint(equalTo: bottomAnchor),
            workspace.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            requestStack.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            contextControls.widthAnchor.constraint(equalTo: requestStack.widthAnchor),
            questionField.widthAnchor.constraint(equalTo: requestStack.widthAnchor),
            controls.widthAnchor.constraint(equalTo: requestStack.widthAnchor),
            privacyLabel.widthAnchor.constraint(equalTo: requestStack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: requestStack.widthAnchor),
            resultsScrollView.widthAnchor.constraint(equalTo: workspace.widthAnchor),
            answerLabel.widthAnchor.constraint(equalTo: resultsStack.widthAnchor),
            evidenceStack.widthAnchor.constraint(equalTo: resultsStack.widthAnchor),
            questionField.heightAnchor.constraint(greaterThanOrEqualToConstant: 26),
            resultsScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            resultsDocument.widthAnchor.constraint(equalTo: resultsScrollView.contentView.widthAnchor),
            resultsStack.leadingAnchor.constraint(equalTo: resultsDocument.leadingAnchor),
            resultsStack.trailingAnchor.constraint(equalTo: resultsDocument.trailingAnchor),
            resultsStack.topAnchor.constraint(equalTo: resultsDocument.topAnchor),
            resultsStack.bottomAnchor.constraint(equalTo: resultsDocument.bottomAnchor)
        ])
    }

    @objc private func broaderVaultChanged(_ sender: NSButton) {
        updateBroaderVaultAccessibility()
    }

    private func updateBroaderVaultAccessibility() {
        let included = broaderVaultCheckbox.state == .on
        broaderVaultCheckbox.setAccessibilityValue(included ? "Broader vault included" : "Selected context only")
        broaderVaultCheckbox.setAccessibilityHelp(
            included
                ? "Retrieval may use all indexed Stillmatter content."
                : "Retrieval is limited to the selected context."
        )
    }

    @objc private func ask() {
        let question = questionField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            showStatus(ContextualAskError.emptyQuestion.description, meaning: .destructive)
            window?.makeFirstResponder(questionField)
            return
        }
        guard let service = serviceProvider() else {
            showStatus("Contextual Ask is unavailable. Configure an Stillmatter root, build the Search Index, and install the pi CLI.", meaning: .destructive)
            window?.makeFirstResponder(questionField)
            return
        }
        let request = ContextualAskRequest(
            question: question,
            context: selectedContext,
            includesBroaderVault: broaderVaultCheckbox.state == .on
        )
        requestInvoker = window?.firstResponder
        setRunning(true)
        queue.async { [weak self] in
            let result = Result { try service.ask(request) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.setRunning(false)
                switch result {
                case let .success(answer):
                    self.render(answer)
                case let .failure(error):
                    self.answerLabel.stringValue = ""
                    self.clearEvidence()
                    self.showStatus("Ask failed: \(error)", meaning: .destructive)
                }
                self.restoreRequestFocus()
            }
        }
    }

    private func restoreRequestFocus() {
        if let requestInvoker = requestInvoker {
            window?.makeFirstResponder(requestInvoker)
        } else {
            window?.makeFirstResponder(questionField)
        }
        requestInvoker = nil
    }

    private var selectedContext: ContextualAskContext {
        guard availableContexts.indices.contains(contextPopup.indexOfSelectedItem) else { return .today }
        return availableContexts[contextPopup.indexOfSelectedItem]
    }

    private func setRunning(_ running: Bool) {
        [askButton, questionField, contextPopup, broaderVaultCheckbox].forEach { $0.isEnabled = !running }
        if running {
            answerLabel.stringValue = ""
            clearEvidence()
            showStatus("Asking pi/Codex. Waiting for a text response…", meaning: .informational)
        }
    }

    private func render(_ answer: ContextualAskAnswer) {
        answerLabel.stringValue = answer.answer
        clearEvidence()
        if answer.citations.isEmpty && answer.sources.isEmpty {
            showStatus("No workspace source matched. The answer is general guidance and has no workspace evidence.", meaning: .informational)
            return
        }

        showStatus("Answer complete. Review the visible evidence below.", meaning: .success)
        if !answer.citations.isEmpty {
            addEvidenceHeading("Citations")
            answer.citations.forEach { citation in
                evidenceStack.addArrangedSubview(evidenceRow(
                    title: citation.title,
                    kind: "Citation",
                    sourcePath: citation.sourcePath,
                    start: citation.transcriptStartSeconds,
                    end: citation.transcriptEndSeconds
                ))
            }
        }
        if !answer.sources.isEmpty {
            addEvidenceHeading("Visible sources")
            answer.sources.forEach { source in
                evidenceStack.addArrangedSubview(evidenceRow(
                    title: source.title,
                    kind: source.kind.displayName,
                    sourcePath: source.sourcePath,
                    start: source.transcriptStartSeconds,
                    end: source.transcriptEndSeconds
                ))
            }
        }
    }

    private func addEvidenceHeading(_ title: String) {
        let heading = NSTextField(labelWithString: title)
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        evidenceStack.addArrangedSubview(heading)
    }

    private func evidenceRow(title: String, kind: String, sourcePath: String, start: Double?, end: Double?) -> NSView {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = GraphiteFocusPresentation.Typography.rowTitle
        titleLabel.lineBreakMode = .byTruncatingTail

        let time: String
        if let start = start, let end = end {
            time = String(format: " • %.1f–%.1fs", start, end)
        } else if let start = start {
            time = String(format: " • %.1fs", start)
        } else {
            time = ""
        }
        let metadata = NSTextField(labelWithString: "\(kind)\(time)")
        metadata.identifier = NSUserInterfaceItemIdentifier("ContextualAsk.EvidenceMetadata")
        metadata.font = GraphiteFocusPresentation.Typography.metadata
        metadata.textColor = colors.textMetadata

        let path = NSTextField(labelWithString: sourcePath)
        path.identifier = NSUserInterfaceItemIdentifier("ContextualAsk.EvidencePath")
        path.font = GraphiteFocusPresentation.Typography.metadata
        path.textColor = colors.textSecondary
        path.lineBreakMode = .byTruncatingMiddle
        path.toolTip = sourcePath

        let row = NSStackView(views: [titleLabel, metadata, path])
        row.identifier = NSUserInterfaceItemIdentifier("ContextualAsk.EvidenceRow")
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = GraphiteFocusPresentation.Space.primitive
        row.setAccessibilityLabel("\(kind): \(title). Source \(sourcePath)\(time)")
        return row
    }

    private func clearEvidence() {
        evidenceStack.arrangedSubviews.forEach {
            evidenceStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
    }

    func applyPresentation() {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        statusLabel.textColor = statusMeaning.color(in: colors)
        privacyLabel.textColor = colors.textMetadata
        answerLabel.textColor = colors.textPrimary
        descendants(of: evidenceStack).compactMap { $0 as? NSTextField }.forEach { label in
            switch label.identifier?.rawValue {
            case "ContextualAsk.EvidenceMetadata": label.textColor = colors.textMetadata
            case "ContextualAsk.EvidencePath": label.textColor = colors.textSecondary
            default: break
            }
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }

    private func showStatus(_ text: String, meaning: GraphiteFocusStatusMeaning) {
        statusMeaning = meaning
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        statusLabel.stringValue = "\(meaning.symbol) \(text)"
        statusLabel.textColor = meaning.color(in: colors)
        statusLabel.setAccessibilityValue(text)
    }
}

private final class ContextualAskResultsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
