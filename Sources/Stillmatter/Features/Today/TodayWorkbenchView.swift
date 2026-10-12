import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Structured Workbench presentation for the read-only Today projection.
final class TodayWorkbenchView: NSView {
    override var isFlipped: Bool { true }

    enum State: Equatable {
        case loading
        case loaded(TodayDashboardSnapshot)
        case unavailable(String)
        case failed(String)
    }

    let stateProvider: () -> State
    private let onRetry: () -> Void
    private let onSelectArea: (ShellTab) -> Void
    private let onOpenDecision: (InboxItem) -> Void
    private let onOpenMeeting: (TodayMeeting, String?) -> Void
    private let onReviewProposals: (InboxItem) -> Void
    private let onOpenTodo: (TodoItem, String?) -> Void
    private let onReviewTitle: (InboxItem) -> Void
    let contentStack = NSStackView()
    private(set) var lastRenderedState = ""
    private enum SectionValue: Equatable {
        case status(String, String)
        case decisions([TodayInboxSection])
        case queue([TodoItem])
        case meetings([TodayMeeting])
    }
    private var renderedSections: [(String, SectionValue, NSView)] = []
    private var renderedState: State?
    private(set) var lastRenderedRowCount = 0
    private(set) var inboxRows: [String: NSButton] = [:]
    private var emptyInboxRows: [InboxCategory: NSButton] = [:]
    private var meetingRows: [String: NSButton] = [:]
    private var unavailableInboxItemID: String?
    private var unavailableInboxMessage: NSView?
    private var decisionDetail: NSView?
    private var detailInboxItem: InboxItem?
    private var detailMeetingID: String?
    private var detailWorkspaceOwner: String?

    init(
        stateProvider: @escaping () -> State,
        onRetry: @escaping () -> Void,
        onSelectArea: @escaping (ShellTab) -> Void,
        onReviewProposals: @escaping (InboxItem) -> Void,
        onOpenDecision: @escaping (InboxItem) -> Void,
        onOpenMeeting: @escaping (TodayMeeting, String?) -> Void,
        onOpenTodo: @escaping (TodoItem, String?) -> Void,
        onReviewTitle: @escaping (InboxItem) -> Void = { _ in }
    ) {
        self.stateProvider = stateProvider
        self.onRetry = onRetry
        self.onSelectArea = onSelectArea
        self.onReviewProposals = onReviewProposals
        self.onOpenDecision = onOpenDecision
        self.onOpenMeeting = onOpenMeeting
        self.onOpenTodo = onOpenTodo
        self.onReviewTitle = onReviewTitle
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh(isVisible: Bool) {
        isHidden = !isVisible
        guard isVisible else { return }
        render(stateProvider())
    }

    @discardableResult
    func focusInboxItem(id: String) -> Bool {
        guard let row = inboxRows[id] else { return false }
        unavailableInboxItemID = nil
        unavailableInboxMessage?.removeFromSuperview()
        unavailableInboxMessage = nil
        row.scrollToVisible(row.bounds)
        window?.makeFirstResponder(row)
        return true
    }

    func showMeetingDetail(_ meeting: TodayMeeting, currentTitle: String, currentTime: String) {
        guard let id = meeting.eventIdentifier else { return }
        decisionDetail?.removeFromSuperview()
        detailInboxItem = nil
        detailMeetingID = id
        if case let .loaded(snapshot) = renderedState { detailWorkspaceOwner = snapshot.workspaceOwner }
        let content = NSTextField(wrappingLabelWithString: "\(currentTitle)\n\(currentTime)")
        content.font = GraphiteFocusPresentation.Typography.body
        content.textColor = colors.textPrimary
        let close = TodayClosureButton(title: "Return to meetings", action: { [weak self] in
            self?.decisionDetail?.removeFromSuperview()
            self?.decisionDetail = nil
            self?.detailMeetingID = nil
            if let row = self?.meetingRows[id] { self?.window?.makeFirstResponder(row) }
        })
        let stack = NSStackView(views: [content, close])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.dense
        let panel = makePanel(title: "Calendar meeting", content: stack, identifier: "today-calendar-detail")
        decisionDetail = panel
        addFullWidth(panel, to: contentStack)
        layoutSubtreeIfNeeded()
        panel.scrollToVisible(panel.bounds)
        window?.makeFirstResponder(close)
    }

    func showDecisionDetail(_ item: InboxItem, actionTitle: String? = nil,
                            onAction: (() -> Void)? = nil, feedback: String? = nil) {
        decisionDetail?.removeFromSuperview()
        detailInboxItem = item
        detailWorkspaceOwner = item.workspaceOwner
        detailMeetingID = nil
        let source = item.sourceRef.map { "\nSource: \($0)" } ?? ""
        let details = item.details.map { "\n\($0)" } ?? ""
        let note: String
        switch item.kind {
        case .failedJob: note = "\nRetry is offered only for a current, retryable Meeting Job."
        case .cleanupProposal: note = "\nNo cleanup action is available for this record."
        default: note = ""
        }
        let result = feedback.map { "\n\($0)" } ?? ""
        let content = NSTextField(wrappingLabelWithString: "\(item.title)\(source)\(details)\(note)\(result)")
        content.font = GraphiteFocusPresentation.Typography.body
        content.textColor = colors.textPrimary
        let close = TodayClosureButton(title: "Return to decisions", action: { [weak self] in
            self?.decisionDetail?.removeFromSuperview()
            self?.decisionDetail = nil
            self?.detailInboxItem = nil
            self?.focusInboxItem(id: item.id)
        })
        let controls: [NSView] = [content] + (actionTitle.flatMap { title in
            onAction.map { action in TodayClosureButton(title: title, action: action) }
        }.map { [$0] } ?? []) + [close]
        let stack = NSStackView(views: controls)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.dense
        let panel = makePanel(title: "\(item.category.displayName) · \(item.kind.rawValue)",
                              content: stack, identifier: "today-decision-detail")
        decisionDetail = panel
        addFullWidth(panel, to: contentStack)
        layoutSubtreeIfNeeded()
        panel.scrollToVisible(panel.bounds)
        window?.makeFirstResponder((controls.dropFirst().first as? NSButton) ?? close)
    }

    func showUnavailableInboxItem(id: String) {
        guard unavailableInboxItemID != id else { return }
        unavailableInboxItemID = id
        unavailableInboxMessage?.removeFromSuperview()
        appendUnavailableInboxMessage()
    }

    private func appendUnavailableInboxMessage() {
        let message = TodayClosureButton(title: "This item is unavailable · Refresh Today", action: { [weak self] in self?.onRetry() })
        message.setAccessibilityIdentifier("today-inbox-item-unavailable")
        unavailableInboxMessage = message
        addFullWidth(message, to: contentStack)
        layoutSubtreeIfNeeded()
        message.scrollToVisible(message.bounds)
        window?.makeFirstResponder(message)
    }

    private func buildLayout() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = GraphiteFocusPresentation.Space.page
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    private(set) var renderCountForValidation = 0

    func render(_ state: State) {
        guard renderedState != state else { return }
        renderCountForValidation += 1
        let focusedID = inboxRows.first { $0.value === window?.firstResponder }?.key
        let focusedCategory = renderedSections.compactMap { entry -> InboxCategory? in
            if case let .decisions(sections) = entry.1 {
                return sections.first(where: { $0.items.contains(where: { $0.id == focusedID }) })?.category
            }
            return nil
        }.first
        let oldInboxIDs = renderedSections.flatMap { entry -> [String] in
            if case let .decisions(sections) = entry.1 { return sections.flatMap(\.items).map(\.id) }
            return []
        }
        let retainsDetail: Bool
        if case let .loaded(snapshot) = state, snapshot.workspaceOwner == detailWorkspaceOwner {
            if let item = detailInboxItem {
                retainsDetail = snapshot.inbox.flatMap(\.items).contains(item)
            } else if let id = detailMeetingID {
                retainsDetail = snapshot.upcomingMeetings.contains(where: { $0.eventIdentifier == id })
            } else { retainsDetail = false }
        } else { retainsDetail = false }
        if !retainsDetail {
            decisionDetail?.removeFromSuperview()
            decisionDetail = nil
            detailInboxItem = nil
            detailMeetingID = nil
            detailWorkspaceOwner = nil
        }
        renderedState = state
        switch state {
        case .loading:
            lastRenderedState = "loading"
            replaceWithState(makeContentState(symbol: "◷", title: "Loading Today", message: "Reading workspace…", actionTitle: "Try Again", action: { [weak self] in self?.onRetry() }))
        case let .loaded(snapshot):
            lastRenderedState = "loaded"
            lastRenderedRowCount = snapshot.inbox.reduce(0) { $0 + $1.items.count }
                + snapshot.queue.count
                + snapshot.upcomingMeetings.count
            render(snapshot)
        case let .unavailable(message):
            lastRenderedState = "unavailable"
            lastRenderedRowCount = 0
            replaceWithState(makeContentState(
                symbol: "○",
                title: "Today is not configured",
                message: message,
                actionTitle: "Open Settings",
                action: { [weak self] in self?.onSelectArea(.settings) }
            ))
        case let .failed(message):
            lastRenderedState = "failed"
            lastRenderedRowCount = 0
            replaceWithState(makeContentState(
                symbol: "!",
                title: "Today could not be loaded",
                message: message,
                actionTitle: "Try Again",
                action: { [weak self] in self?.onRetry() }
            ))
        }
        unavailableInboxMessage?.removeFromSuperview()
        unavailableInboxMessage = nil
        if let id = unavailableInboxItemID {
            if inboxRows[id] == nil { appendUnavailableInboxMessage() }
            else { unavailableInboxItemID = nil }
        }
        if let focusedID {
            let position = oldInboxIDs.firstIndex(of: focusedID) ?? 0
            let replacement = inboxRows[focusedID] ?? inboxRowsForFocus(at: position)
                ?? focusedCategory.flatMap { emptyInboxRows[$0] }
            if let replacement { window?.makeFirstResponder(replacement) }
        }
    }

    private func inboxRowsForFocus(at position: Int) -> NSButton? {
        for entry in renderedSections {
            if case let .decisions(sections) = entry.1 {
                let ids = sections.flatMap(\.items).map(\.id)
                if !ids.isEmpty { return inboxRows[ids[min(position, ids.count - 1)]] }
            }
        }
        return nil
    }

    private func replaceWithState(_ view: NSView) {
        renderedSections.removeAll()
        inboxRows.removeAll()
        emptyInboxRows.removeAll()
        meetingRows.removeAll()
        contentStack.removeAllArrangedSubviews()
        addFullWidth(view, to: contentStack)
    }

    private func updateSections(_ sections: [(String, SectionValue, () -> NSView)]) {
        // The old section remains attached when its projection is identical. In particular,
        // a status-only change never recreates a focused decision or queue row.
        for (index, entry) in sections.enumerated() {
            if index < renderedSections.count,
               renderedSections[index].0 == entry.0,
               renderedSections[index].1 == entry.1 { continue }
            let view = entry.2()
            if index < renderedSections.count {
                let old = renderedSections[index].2
                contentStack.removeArrangedSubview(old)
                old.removeFromSuperview()
                renderedSections[index] = (entry.0, entry.1, view)
            } else {
                renderedSections.append((entry.0, entry.1, view))
            }
            contentStack.insertArrangedSubview(view, at: index)
            view.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true
        }
        while renderedSections.count > sections.count {
            let old = renderedSections.removeLast().2
            contentStack.removeArrangedSubview(old)
            old.removeFromSuperview()
        }
    }

    func render(_ snapshot: TodayDashboardSnapshot) {
        var sections: [(String, SectionValue, () -> NSView)] = [
            ("decisions", .decisions(snapshot.inbox), { [self] in makeDecisions(snapshot.inbox) }),
            ("queue", .queue(snapshot.queue), { [self] in makeQueue(snapshot.queue, owner: snapshot.workspaceOwner) }),
            ("meetings", .meetings(snapshot.upcomingMeetings), { [self] in makeMeetings(snapshot.upcomingMeetings, owner: snapshot.workspaceOwner) })
        ]
        if snapshot.recordingStatus != "Not recording" || snapshot.jobStatus != "Jobs idle" {
            sections.insert(("status", .status(snapshot.recordingStatus, snapshot.jobStatus), { [self] in
                let label = NSTextField(wrappingLabelWithString: "\(snapshot.recordingStatus)  ·  \(snapshot.jobStatus)")
                label.font = GraphiteFocusPresentation.Typography.metadata
                label.textColor = colors.textSecondary
                return label
            }), at: 0)
        }
        if contentStack.arrangedSubviews.count == 1 && renderedSections.isEmpty {
            contentStack.removeAllArrangedSubviews()
        }
        updateSections(sections)
    }

    private func makeDecisions(_ sections: [TodayInboxSection]) -> NSView {
        inboxRows.removeAll()
        emptyInboxRows.removeAll()
        let inboxStack = NSStackView()
        inboxStack.orientation = .vertical
        inboxStack.alignment = .leading
        inboxStack.spacing = GraphiteFocusPresentation.Space.panel
        for section in sections {
            let rows = section.items.map { item in
                let row = GraphiteFocusCollectionRow(
                    symbol: inboxSymbol(for: item.kind),
                    title: item.title,
                    metadata: inboxMetadata(for: item),
                    emphasis: item.kind == .proposal ? .proposal : .standard,
                    actionTitle: item.kind == .proposal ? "Review" :
                        ([InboxItemKind.failedJob, .cleanupProposal].contains(item.kind) ? "View record" : "Open"),
                    action: { [weak self] in
                        guard let self = self else { return }
                        if item.kind == .proposal {
                            self.onReviewProposals(item)
                        } else if item.kind == .titleReview {
                            self.onReviewTitle(item)
                        } else {
                            self.onOpenDecision(item)
                        }
                    }
                )
                row.setAccessibilityIdentifier("today-inbox-\(item.id)")
                inboxRows[item.id] = row
                return row
            }
            let empty = TodayClosureButton(title: "No \(section.category.displayName.lowercased()) items · Refresh", action: { [weak self] in self?.onRetry() })
            if rows.isEmpty { emptyInboxRows[section.category] = empty }
            addFullWidth(makeSection(
                title: "\(section.category.displayName) · \(section.items.count)",
                rows: rows,
                emptyMessage: "No \(section.category.displayName.lowercased()) items.",
                identifier: "today-inbox-\(section.category.rawValue)",
                emptyControl: empty
            ), to: inboxStack)
        }
        let group = makeGroup(title: "Needs your decision", content: inboxStack)
        return group
    }

    private func makeQueue(_ items: [TodoItem], owner: String?) -> NSView {
        let queueRows = items.map { item in
            GraphiteFocusCollectionRow(
                symbol: todoSymbol(for: item.status),
                title: item.title,
                metadata: todoMetadata(for: item),
                emphasis: item.status == .blocked ? .attention : .standard,
                action: { [weak self] in self?.onOpenTodo(item, owner) }
            )
        }
        return makeSection(
            title: "Your queue",
            rows: queueRows,
            emptyMessage: "No open Todo Items in the Queue.",
            identifier: "today-queue"
        )
    }

    private func makeMeetings(_ meetings: [TodayMeeting], owner: String?) -> NSView {
        meetingRows.removeAll()
        let rows = meetings.map { meeting in
            let row = GraphiteFocusCollectionRow(
                symbol: "◷",
                title: meeting.title,
                metadata: meeting.time.map { "Today at \($0)" } ?? "Time unavailable",
                action: { [weak self] in self?.onOpenMeeting(meeting, owner) }
            )
            if let id = meeting.eventIdentifier {
                row.setAccessibilityIdentifier("today-calendar-\(id)")
                meetingRows[id] = row
            }
            return row
        }
        return makeSection(
            title: "Today's meetings",
            rows: rows,
            emptyMessage: "No upcoming Meetings are available.",
            identifier: "today-meetings"
        )
    }



    private func makeGroup(title: String, content: NSView) -> NSView {
        let heading = makeHeading(title)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.dense
        stack.addArrangedSubview(heading)
        addFullWidth(content, to: stack)
        return stack
    }

    private func makePanel(title: String, content: NSView, identifier: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.dense
        stack.addArrangedSubview(makeHeading(title))
        addFullWidth(content, to: stack)
        stack.edgeInsets = NSEdgeInsets(
            top: GraphiteFocusPresentation.Space.panel,
            left: GraphiteFocusPresentation.Space.panel,
            bottom: GraphiteFocusPresentation.Space.panel,
            right: GraphiteFocusPresentation.Space.panel
        )

        let panel = NSBox()
        panel.boxType = .custom
        panel.borderWidth = GraphiteFocusPresentation.Stroke.width
        panel.borderColor = colors.structuralStroke
        panel.fillColor = colors.surfacePanel
        panel.cornerRadius = GraphiteFocusPresentation.Radius.panel
        panel.contentViewMargins = .zero
        panel.contentView = stack
        panel.setAccessibilityIdentifier(identifier)
        return panel
    }

    private func makeSection(
        title: String,
        rows: [GraphiteFocusCollectionRow],
        emptyMessage: String,
        identifier: String,
        emptyControl: NSButton? = nil
    ) -> NSView {
        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = GraphiteFocusPresentation.Space.flush
        if rows.isEmpty {
            if let emptyControl {
                addFullWidth(emptyControl, to: rowsStack)
            } else {
                let empty = NSTextField(wrappingLabelWithString: "○  \(emptyMessage)")
                empty.font = GraphiteFocusPresentation.Typography.body
                empty.textColor = colors.textMetadata
                empty.setAccessibilityLabel(emptyMessage)
                addFullWidth(empty, to: rowsStack)
            }
        } else {
            for (index, row) in rows.enumerated() {
                if index > 0 { addFullWidth(makeDivider(), to: rowsStack) }
                addFullWidth(row, to: rowsStack)
            }
        }
        let section = makeGroup(title: title, content: rowsStack)
        section.setAccessibilityIdentifier(identifier)
        return section
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func makeContentState(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> NSView {
        let titleLabel = NSTextField(labelWithString: "\(symbol)  \(title)")
        titleLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        titleLabel.textColor = colors.textPrimary
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = GraphiteFocusPresentation.Typography.body
        messageLabel.textColor = colors.textSecondary
        let button = TodayClosureButton(title: actionTitle, action: action)
        let stack = NSStackView(views: [titleLabel, messageLabel, button])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.dense
        stack.setAccessibilityIdentifier("today-content-state")
        return makePanel(title: "Today", content: stack, identifier: "today-state-panel")
    }

    private func makeHeading(_ title: String) -> NSTextField {
        let heading = NSTextField(labelWithString: title)
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        heading.textColor = colors.textPrimary
        return heading
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = colors.structuralStroke.cgColor
        divider.heightAnchor.constraint(equalToConstant: GraphiteFocusPresentation.Stroke.width).isActive = true
        return divider
    }

    private var colors: GraphiteFocusPresentation.Colors {
        GraphiteFocusPresentation.Colors(environment: GraphiteFocusEnvironment.system(window: window))
    }

    private func inboxSymbol(for kind: InboxItemKind) -> String {
        switch kind {
        case .proposal: return "◇"
        case .failedJob: return "!"
        case .titleReview: return "✎"
        case .cleanupProposal: return "△"
        }
    }

    private func inboxMetadata(for item: InboxItem) -> String {
        let kind: String
        switch item.kind {
        case .proposal: kind = "Action Item proposal — review before it becomes a Todo Item"
        case .failedJob: kind = "Failed Job — view failure; Retry if available"
        case .titleReview: kind = "Meeting title review"
        case .cleanupProposal: kind = "Cleanup proposal — view record"
        }
        return [kind, item.sourceRef, item.details].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func todoSymbol(for status: TodoStatus) -> String {
        switch status {
        case .open: return "□"
        case .done: return "✓"
        case .blocked: return "⊘"
        case .canceled: return "×"
        }
    }

    private func todoMetadata(for item: TodoItem) -> String {
        var values = ["Todo Item"]
        if item.status == .blocked { values.append("Blocked") }
        if let dueDate = item.dueDate { values.append("Due \(dueDate)") }
        if let sourceRef = item.sourceRef { values.append(sourceRef) }
        values.append("\(item.location.relativePath):\(item.location.lineNumber)")
        return values.joined(separator: "  ·  ")
    }

}

private final class GraphiteFocusCollectionRow: NSButton {
    enum Emphasis {
        case standard
        case attention
        case proposal
    }

    private let invoke: () -> Void

    init(
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
        titleLabel.font = GraphiteFocusPresentation.Typography.rowTitle
        titleLabel.textColor = colors.textPrimary
        titleLabel.maximumNumberOfLines = 2
        let metadataLabel = NSTextField(wrappingLabelWithString: metadata)
        metadataLabel.font = GraphiteFocusPresentation.Typography.metadata
        metadataLabel.textColor = colors.textMetadata
        metadataLabel.maximumNumberOfLines = 2
        let labels = NSStackView(views: [titleLabel, metadataLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = GraphiteFocusPresentation.Space.primitive
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let actionLabel = NSTextField(labelWithString: actionTitle)
        actionLabel.font = GraphiteFocusPresentation.Typography.control
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

final class TodayClosureButton: NSButton {
    private let invoke: () -> Void

    init(title: String, action: @escaping () -> Void) {
        invoke = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(activate)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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

private extension NSStackView {
    func removeAllArrangedSubviews() {
        arrangedSubviews.forEach { view in
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}
