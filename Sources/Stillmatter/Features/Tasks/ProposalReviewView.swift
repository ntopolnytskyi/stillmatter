import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Dense review collection for pending Action Item proposals.
final class ProposalReviewView: NSView, NSTextFieldDelegate {
    override var isFlipped: Bool { true }

    final class ProposalRow {
        let proposal: ActionItemProposal
        let selection = ProposalReviewButton(checkboxWithTitle: "", target: nil, action: nil)
        let titleField: NSTextField
        let sourceLabel = NSTextField(labelWithString: "")
        let pendingLabel = GraphiteFocusStatusLabel()
        let acceptButton = ProposalReviewButton(title: "Accept", target: nil, action: nil)
        let referenceOnlyButton = ProposalReviewButton(title: "Reference Only", target: nil, action: nil)
        let dismissButton = ProposalReviewButton(title: "Dismiss", target: nil, action: nil)
        let container = ProposalReviewRowView()

        init(proposal: ActionItemProposal) {
            self.proposal = proposal
            titleField = NSTextField(string: proposal.title)
        }
    }

    private let settingsStore: SettingsStore
    private let inbox: TasksInbox?
    private var displayedOwner: String?
    private let onChange: () -> Void
    let listStack = NSStackView()
    private let selectAllCheckbox = ProposalReviewButton(checkboxWithTitle: "Select All", target: nil, action: nil)
    let selectionLabel = NSTextField(labelWithString: "No proposals selected")
    private let successLabel = GraphiteFocusStatusLabel()
    let failureLabel = GraphiteFocusStatusLabel()
    let emptyStateLabel = ProposalReviewStaticText(wrappingLabelWithString: "No pending Action Item proposals. Reviewed items leave this section; focus stays here so keyboard and VoiceOver users keep their place.")
    let acceptSelectedButton = ProposalReviewButton(title: "Accept Selected", target: nil, action: nil)
    private var successDismissal: DispatchWorkItem?
    let mergeSelectedButton = ProposalReviewButton(title: "Merge Selected", target: nil, action: nil)
    var rows: [ProposalRow] = []

    init(settingsStore: SettingsStore, inbox: TasksInbox?, onChange: @escaping () -> Void) {
        self.settingsStore = settingsStore
        self.inbox = inbox
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureKeyboardTraversal()
    }

    func refresh(isVisible: Bool) {
        guard isVisible, let base = inbox,
              let root = settingsStore.settings.stillmatterRootURL,
              let inbox = try? base.scoped(to: root) else {
            isHidden = true
            return
        }

        do {
            let proposals = try inbox.items(category: .review)
                .filter { $0.kind == .proposal }
                .compactMap { try inbox.pendingProposal(id: $0.id) }
            // Keep the section present after the last review so its focusable
            // empty state can receive keyboard and VoiceOver focus.
            displayedOwner = root.standardizedFileURL.resolvingSymlinksInPath().path
            isHidden = false
            rebuildRows(proposals)
        } catch {
            isHidden = false
            displayedOwner = nil
            rebuildRows([])
            setFailure("Could not load pending proposals: \(error)")
        }
    }

    var pendingTitlesForValidation: [String] { rows.map { $0.proposal.title } }

    @discardableResult
    func focusProposal(id: String) -> Bool {
        guard let row = rows.first(where: { $0.proposal.id == id }) else { return false }
        row.container.scrollToVisible(row.container.bounds)
        window?.makeFirstResponder(row.selection)
        return true
    }

    private func buildLayout() {
        let heading = NSTextField(labelWithString: "Review Action Items")
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        heading.alignment = .left
        let headingSpacer = NSView()
        headingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headingRow = NSStackView(views: [heading, headingSpacer])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY

        let guidance = NSTextField(wrappingLabelWithString: "Pending proposals are not Todo Items. Edit a title, then accept it, keep it as a reference, dismiss it, or merge selected proposals.")
        guidance.font = GraphiteFocusPresentation.Typography.body
        guidance.textColor = colors.textSecondary
        guidance.maximumNumberOfLines = 0

        selectAllCheckbox.target = self
        selectAllCheckbox.action = #selector(toggleSelectAll(_:))
        selectAllCheckbox.setAccessibilityLabel("Select all pending Action Item proposals")
        selectionLabel.font = GraphiteFocusPresentation.Typography.metadata
        selectionLabel.textColor = colors.textSecondary
        selectionLabel.setAccessibilityLabel("Proposal selection summary")

        let selectionBar = NSStackView(views: [selectAllCheckbox, selectionLabel])
        selectionBar.orientation = .horizontal
        selectionBar.alignment = .centerY
        selectionBar.spacing = GraphiteFocusPresentation.Space.dense

        successLabel.isHidden = true
        failureLabel.isHidden = true
        emptyStateLabel.isHidden = true
        emptyStateLabel.font = GraphiteFocusPresentation.Typography.body
        emptyStateLabel.textColor = colors.textSecondary
        emptyStateLabel.setAccessibilityElement(true)
        emptyStateLabel.setAccessibilityRole(.staticText)
        emptyStateLabel.setAccessibilityLabel("No pending Action Item proposals")
        emptyStateLabel.setAccessibilityValue(emptyStateLabel.stringValue)

        listStack.orientation = .vertical
        listStack.alignment = .width
        listStack.spacing = GraphiteFocusPresentation.Space.primitive
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.setAccessibilityLabel("Pending Action Item proposals")

        acceptSelectedButton.target = self
        acceptSelectedButton.action = #selector(acceptSelected)
        acceptSelectedButton.keyEquivalent = "\r"
        acceptSelectedButton.bezelStyle = .rounded
        acceptSelectedButton.setAccessibilityLabel("Accept selected proposals as Todo Items")
        mergeSelectedButton.target = self
        mergeSelectedButton.action = #selector(mergeSelected)
        mergeSelectedButton.bezelStyle = .recessed
        mergeSelectedButton.setAccessibilityLabel("Merge selected proposals into one Todo Item")

        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actionBar = NSStackView(views: [actionSpacer, mergeSelectedButton, acceptSelectedButton])
        actionBar.orientation = .horizontal
        actionBar.alignment = .centerY
        actionBar.spacing = GraphiteFocusPresentation.Space.compact

        let layout = NSStackView(views: [headingRow, guidance, selectionBar, successLabel, failureLabel, emptyStateLabel, listStack, actionBar])
        layout.orientation = .vertical
        layout.alignment = .width
        layout.spacing = GraphiteFocusPresentation.Space.compact
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)

        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        updateSelectionControls()
    }

    func rebuildRows(_ proposals: [ActionItemProposal]) {
        guard rows.map(\.proposal) != proposals else {
            updateSelectionControls()
            return
        }
        let focusedRow = rows.first { row in
            guard let responder = window?.firstResponder else { return false }
            return (row.titleField.currentEditor() != nil && responder === row.titleField.currentEditor()) ||
                [row.selection, row.dismissButton, row.referenceOnlyButton, row.acceptButton].contains { $0 === responder }
        }
        let focusedControl: NSView? = focusedRow.flatMap { row in
            if window?.firstResponder === row.titleField.currentEditor() {
                row.titleField.validateEditing()
                return row.titleField
            }
            return [row.selection, row.dismissButton, row.referenceOnlyButton, row.acceptButton]
                .first { $0 === window?.firstResponder }
        }
        let focusedID = focusedRow?.proposal.id
        let edits = Dictionary(uniqueKeysWithValues: rows.map { ($0.proposal.id, $0.titleField.stringValue) })
        let selectedIDs = Set(selectedRows.map(\.proposal.id))
        listStack.arrangedSubviews.forEach { view in
            listStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rows = proposals.map(ProposalRow.init)
        for (index, row) in rows.enumerated() {
            if let edit = edits[row.proposal.id] { row.titleField.stringValue = edit }
            row.selection.state = selectedIDs.contains(row.proposal.id) ? .on : .off
            configure(row: row, index: index)
            listStack.addArrangedSubview(row.container)
        }
        emptyStateLabel.isHidden = !rows.isEmpty
        updateSelectionControls()
        configureKeyboardTraversal()
        if let focusedID = focusedID, let focusedControl = focusedControl,
           let row = rows.first(where: { $0.proposal.id == focusedID }) {
            let replacement: NSView
            if focusedControl is NSTextField { replacement = row.titleField }
            else if focusedControl === focusedRow?.selection { replacement = row.selection }
            else if focusedControl === focusedRow?.dismissButton { replacement = row.dismissButton }
            else if focusedControl === focusedRow?.referenceOnlyButton { replacement = row.referenceOnlyButton }
            else { replacement = row.acceptButton }
            window?.makeFirstResponder(replacement)
        }
    }

    var keyboardTraversalControls: [NSView] {
        [selectAllCheckbox] + rows.flatMap {
            [$0.selection, $0.titleField, $0.dismissButton, $0.referenceOnlyButton, $0.acceptButton]
        } + [mergeSelectedButton, acceptSelectedButton]
    }

    private func configureKeyboardTraversal() {
        guard let window = window else { return }
        window.recalculateKeyViewLoop()
        let controls = keyboardTraversalControls
        for (current, next) in zip(controls, controls.dropFirst()) {
            current.nextKeyView = next
        }
        controls.compactMap { $0 as? ProposalReviewButton }.forEach { button in
            button.onTab = { [weak self, weak button] movesBackward in
                guard let self = self, let button = button else { return false }
                return self.moveKeyboardFocus(from: button, movesBackward: movesBackward)
            }
        }
    }

    func moveKeyboardFocus(from current: NSView, movesBackward: Bool) -> Bool {
        let controls = keyboardTraversalControls
        guard let currentIndex = controls.firstIndex(where: { $0 === current }) else { return false }
        let candidates: [NSView] = movesBackward
            ? Array(controls[..<currentIndex].reversed())
            : Array(controls.dropFirst(currentIndex + 1))
        for candidate in candidates {
            if candidate.isHiddenOrHasHiddenAncestor { continue }
            if let control = candidate as? NSControl, !control.isEnabled { continue }
            if window?.makeFirstResponder(candidate) == true {
                candidate.scrollToVisible(candidate.bounds)
                return true
            }
        }
        return false
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return moveKeyboardFocus(from: control, movesBackward: false)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return moveKeyboardFocus(from: control, movesBackward: true)
        }
        return false
    }

    private func configure(row: ProposalRow, index: Int) {
        let colors = colors
        row.selection.target = self
        row.selection.action = #selector(selectionChanged(_:))
        row.selection.tag = index
        row.selection.setAccessibilityLabel("Select proposal: \(row.proposal.title)")
        row.titleField.placeholderString = "Todo Item title"
        row.titleField.delegate = self
        row.titleField.setAccessibilityLabel("Editable title for proposal: \(row.proposal.title)")
        row.titleField.setAccessibilityIdentifier("proposal-title-\(row.proposal.id)")
        row.titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let titleRow = NSStackView(views: [row.selection, row.titleField])
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = GraphiteFocusPresentation.Space.compact

        row.sourceLabel.stringValue = row.proposal.sourceRef
        row.sourceLabel.toolTip = row.proposal.sourceRef
        row.sourceLabel.textColor = colors.textMetadata
        row.sourceLabel.font = GraphiteFocusPresentation.Typography.metadata
        row.sourceLabel.lineBreakMode = .byTruncatingMiddle
        row.sourceLabel.setAccessibilityLabel("Source reference")
        row.sourceLabel.setAccessibilityValue(row.proposal.sourceRef)
        row.pendingLabel.setStatus(row.proposal.isObsolete ? "Not in current Summary" : "Pending proposal",
            meaning: row.proposal.isObsolete ? .attention : .informational, colors: colors)

        let metadataSpacer = NSView()
        metadataSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let metadata = NSStackView(views: [row.pendingLabel, metadataSpacer, row.sourceLabel])
        metadata.orientation = .horizontal
        metadata.alignment = .centerY
        metadata.spacing = GraphiteFocusPresentation.Space.compact
        row.sourceLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true // graphite-focus-native-exception: keeps durable source references discoverable in dense rows

        row.acceptButton.target = self
        row.acceptButton.action = #selector(acceptOne(_:))
        row.acceptButton.setAccessibilityLabel("Accept \(row.proposal.title) as a Todo Item")
        row.acceptButton.setAccessibilityIdentifier("proposal-accept-\(row.proposal.id)")
        row.acceptButton.toolTip = "Create one canonical Todo Item from this proposal"
        row.referenceOnlyButton.target = self
        row.referenceOnlyButton.action = #selector(markReferenceOnly(_:))
        row.referenceOnlyButton.setAccessibilityLabel("Keep \(row.proposal.title) as reference only")
        row.referenceOnlyButton.toolTip = "Resolve the proposal without creating a Todo Item"
        row.dismissButton.target = self
        row.dismissButton.action = #selector(dismissOne(_:))
        row.dismissButton.bezelStyle = .inline
        row.dismissButton.setAccessibilityLabel("Dismiss proposal \(row.proposal.title)")
        row.dismissButton.toolTip = "Dismiss this proposal without creating a Todo Item"
        [row.acceptButton, row.referenceOnlyButton, row.dismissButton].forEach { $0.tag = index }

        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [actionSpacer, row.dismissButton, row.referenceOnlyButton, row.acceptButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = GraphiteFocusPresentation.Space.compact

        let content = NSStackView(views: [titleRow, metadata, actions])
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = GraphiteFocusPresentation.Space.primitive
        content.translatesAutoresizingMaskIntoConstraints = false

        row.container.wantsLayer = true
        row.container.layer?.borderWidth = GraphiteFocusPresentation.Stroke.width
        row.container.layer?.borderColor = colors.structuralStroke.cgColor
        row.container.layer?.backgroundColor = colors.surfacePanel.cgColor
        row.container.layer?.cornerRadius = GraphiteFocusPresentation.Radius.compact
        row.container.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: row.container.leadingAnchor, constant: GraphiteFocusPresentation.Space.dense),
            content.trailingAnchor.constraint(equalTo: row.container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.dense),
            content.topAnchor.constraint(equalTo: row.container.topAnchor, constant: GraphiteFocusPresentation.Space.compact),
            content.bottomAnchor.constraint(equalTo: row.container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.compact)
        ])
        row.container.heightAnchor.constraint(greaterThanOrEqualToConstant: 104).isActive = true // graphite-focus-native-exception: three-line editable review row must not collapse in an NSStackView
        row.container.setAccessibilityElement(true)
        row.container.setAccessibilityRole(.group)
        row.container.setAccessibilityLabel("Pending Action Item proposal: \(row.proposal.title)")
        row.container.onSelect = { [weak self, weak selection = row.selection] in
            guard let self = self, let selection = selection else { return }
            selection.state = selection.state == .on ? .off : .on
            self.window?.makeFirstResponder(selection)
            self.updateSelectionControls()
        }
    }

    @objc private func selectionChanged(_ sender: NSButton) {
        updateSelectionControls()
    }

    @objc private func toggleSelectAll(_ sender: NSButton) {
        rows.forEach { $0.selection.state = sender.state }
        updateSelectionControls()
    }

    @objc private func acceptOne(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), rows[sender.tag].acceptButton === sender else { return }
        let row = rows[sender.tag]
        performReview(success: "Added ‘\(row.titleField.stringValue)’ to Todos.", removingFocusedID: row.proposal.id, removedIndex: sender.tag) { reviewer, version in
            _ = try reviewer.accept(
                proposalID: row.proposal.id,
                editedTitle: row.titleField.stringValue,
                expectedTodoVersion: version
            )
        }
    }

    @objc private func acceptSelected() {
        let selected = selectedRows
        guard !selected.isEmpty, let first = selected.first,
              let firstIndex = rows.firstIndex(where: { $0 === first }) else { return }
        let success = selected.count == 1
            ? "Added ‘\(first.titleField.stringValue)’ to Todos."
            : "Added \(selected.count) proposals to Todos."
        performReview(success: success, removingFocusedID: first.proposal.id, removedIndex: firstIndex) { reviewer, version in
            if selected.count == 1 {
                _ = try reviewer.accept(
                    proposalID: first.proposal.id,
                    editedTitle: first.titleField.stringValue,
                    expectedTodoVersion: version
                )
            } else {
                _ = try reviewer.batchAccept(
                    proposalEditsInDisplayedOrder: selected.map { ($0.proposal.id, $0.titleField.stringValue) },
                    expectedTodoVersion: version
                )
            }
        }
    }

    @objc private func mergeSelected() {
        let selected = selectedRows
        guard selected.count >= 2, let first = selected.first,
              let firstIndex = rows.firstIndex(where: { $0 === first }) else { return }
        performReview(success: "Merged \(selected.count) proposals into ‘\(first.titleField.stringValue)’ in Todos.", removingFocusedID: first.proposal.id, removedIndex: firstIndex) { reviewer, version in
            _ = try reviewer.merge(
                proposalIDs: selected.map { $0.proposal.id },
                title: first.titleField.stringValue,
                expectedTodoVersion: version
            )
        }
    }

    @objc private func markReferenceOnly(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), rows[sender.tag].referenceOnlyButton === sender else { return }
        performStateReview(rowIndex: sender.tag, successPrefix: "Kept as reference only") { reviewer, id in
            try reviewer.markReferenceOnly(proposalID: id)
        }
    }

    @objc private func dismissOne(_ sender: NSButton) {
        guard rows.indices.contains(sender.tag), rows[sender.tag].dismissButton === sender else { return }
        performStateReview(rowIndex: sender.tag, successPrefix: "Dismissed proposal") { reviewer, id in
            try reviewer.dismiss(proposalID: id)
        }
    }

    var selectedRows: [ProposalRow] {
        rows.filter { $0.selection.state == .on }
    }

    func updateSelectionControls() {
        let count = selectedRows.count
        selectionLabel.stringValue = count == 0 ? "No proposals selected" : "\(count) proposal\(count == 1 ? "" : "s") selected"
        selectionLabel.setAccessibilityValue(selectionLabel.stringValue)
        acceptSelectedButton.isEnabled = count > 0
        mergeSelectedButton.isEnabled = count >= 2
        acceptSelectedButton.toolTip = count > 0 ? "Accept the selected proposals as canonical Todo Items" : "Select at least one proposal to accept"
        mergeSelectedButton.toolTip = count >= 2 ? "Merge the selected proposals into one canonical Todo Item" : "Select at least two proposals to merge"
        acceptSelectedButton.setAccessibilityHelp(acceptSelectedButton.toolTip ?? "")
        mergeSelectedButton.setAccessibilityHelp(mergeSelectedButton.toolTip ?? "")
        selectAllCheckbox.state = !rows.isEmpty && count == rows.count ? .on : .off
        selectAllCheckbox.isEnabled = !rows.isEmpty
    }

    private func performReview(
        success message: String,
        removingFocusedID removedID: String,
        removedIndex: Int,
        action: (ActionItemProposalReviewer, WorkspaceFileVersion) throws -> Void
    ) {
        let previousResponder = window?.firstResponder
        do {
            let (reviewer, vault) = try makeReviewer()
            guard let version = try vault.versionOfMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath) else {
                throw WorkspaceVaultError.missingFile(TodoItemIndex.mainTodoRelativePath)
            }
            try action(reviewer, version)
            clearFailure()
            setSuccess(message)
            onChange()
            focusAfterRemoval(of: removedID, removedIndex: removedIndex)
        } catch {
            showError(error, restoring: previousResponder)
        }
    }

    private func performStateReview(
        rowIndex: Int,
        successPrefix: String,
        action: (ActionItemProposalReviewer, String) throws -> Void
    ) {
        guard rows.indices.contains(rowIndex) else { return }
        let previousResponder = window?.firstResponder
        let removed = rows[rowIndex]
        do {
            let (reviewer, _) = try makeReviewer()
            try action(reviewer, removed.proposal.id)
            clearFailure()
            setSuccess("\(successPrefix): ‘\(removed.titleField.stringValue)’.")
            onChange()
            focusAfterRemoval(of: removed.proposal.id, removedIndex: rowIndex)
        } catch {
            showError(error, restoring: previousResponder)
        }
    }

    private func makeReviewer() throws -> (ActionItemProposalReviewer, WorkspaceVault) {
        guard let inbox = inbox else { throw ProposalReviewViewError.inboxUnavailable }
        guard let rootURL = settingsStore.settings.stillmatterRootURL else { throw ProposalReviewViewError.workspaceUnavailable }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stillmatter", isDirectory: true)
        guard displayedOwner == rootURL.standardizedFileURL.resolvingSymlinksInPath().path else {
            throw ProposalReviewViewError.workspaceUnavailable
        }
        let vault = WorkspaceVault(workspaceRootURL: rootURL, appSupportRootURL: appSupport)
        return (ActionItemProposalReviewer(inbox: try inbox.scoped(to: rootURL), todoMutator: TodoItemMutator(vault: vault), workspaceRootURL: rootURL), vault)
    }

    func clearFailure() {
        failureLabel.isHidden = true
        failureLabel.stringValue = ""
    }

    private func setSuccess(_ message: String) {
        successDismissal?.cancel()
        successLabel.setStatus(message, meaning: .success, colors: colors)
        successLabel.isHidden = false
        NSAccessibility.post(
            element: successLabel,
            notification: .announcementRequested,
            userInfo: [.announcement: message]
        )
        let dismissal = DispatchWorkItem { [weak self] in self?.successLabel.isHidden = true }
        successDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: dismissal)
    }

    func setFailure(_ message: String) {
        successDismissal?.cancel()
        successLabel.isHidden = true
        failureLabel.setStatus(message, meaning: .destructive, colors: colors)
        failureLabel.isHidden = false
    }

    private func showError(_ error: Error, restoring responder: NSResponder?) {
        setFailure("Review failed. The proposal was not changed; your selection and edits were preserved. Try again after correcting the problem. \(error)")
        if let responder = responder { window?.makeFirstResponder(responder) }
        NSAccessibility.post(
            element: failureLabel,
            notification: .announcementRequested,
            userInfo: [.announcement: failureLabel.statusText]
        )
    }

    func focusAfterRemoval(of removedID: String, removedIndex: Int) {
        guard rows.first(where: { $0.proposal.id == removedID }) == nil else { return }
        if rows.indices.contains(removedIndex) {
            window?.makeFirstResponder(rows[removedIndex].selection)
            rows[removedIndex].selection.scrollToVisible(rows[removedIndex].selection.bounds)
        } else if let last = rows.last {
            window?.makeFirstResponder(last.selection)
            last.selection.scrollToVisible(last.selection.bounds)
        } else {
            window?.makeFirstResponder(emptyStateLabel)
            NSAccessibility.post(element: emptyStateLabel, notification: .focusedUIElementChanged)
        }
    }

    private var colors: GraphiteFocusPresentation.Colors {
        GraphiteFocusPresentation.Colors(environment: .system(window: window))
    }


}

final class ProposalReviewStaticText: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        setAccessibilityFocused(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        setAccessibilityFocused(false)
        return true
    }
}

final class ProposalReviewButton: NSButton {
    var onTab: ((Bool) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let traversalModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        if event.keyCode == 48,
           traversalModifiers.intersection(blockedModifiers).isEmpty,
           onTab?(traversalModifiers.contains(.shift)) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class ProposalReviewRowView: NSView {
    var onSelect: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onSelect?()
    }
}

private enum ProposalReviewViewError: Error {
    case inboxUnavailable
    case workspaceUnavailable
}
