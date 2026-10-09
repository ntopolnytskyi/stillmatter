import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Structured Workbench presentation for the read-only Today projection.
final class TodayWorkbenchView: NSView {
    override var isFlipped: Bool { true }

    enum State {
        case loaded(TodayDashboardSnapshot)
        case unavailable(String)
        case failed(String)
    }

    private let stateProvider: () -> State
    private let onSelectArea: (ShellTab) -> Void
    private let onOpenDailyBrief: (String) -> Void
    private let onReviewProposals: () -> Void
    private let onReviewTitle: (InboxItem) -> Void
    private let contentStack = NSStackView()
    private var lastRenderedState = ""
    private var lastRenderedRowCount = 0
    private var inboxRows: [String: NSButton] = [:]
    private var unavailableInboxItemID: String?

    init(
        stateProvider: @escaping () -> State,
        onSelectArea: @escaping (ShellTab) -> Void,
        onOpenDailyBrief: @escaping (String) -> Void,
        onReviewProposals: @escaping () -> Void,
        onReviewTitle: @escaping (InboxItem) -> Void = { _ in }
    ) {
        self.stateProvider = stateProvider
        self.onSelectArea = onSelectArea
        self.onOpenDailyBrief = onOpenDailyBrief
        self.onReviewProposals = onReviewProposals
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
        row.scrollToVisible(row.bounds)
        window?.makeFirstResponder(row)
        return true
    }

    func showUnavailableInboxItem(id: String) {
        unavailableInboxItemID = id
        appendUnavailableInboxMessage()
    }

    private func appendUnavailableInboxMessage() {
        let message = NSTextField(wrappingLabelWithString: "This Inbox item is no longer available, or Today could not load it. Refresh Today or check Settings.")
        message.font = GraphiteFocusPresentation.Typography.body
        message.textColor = colors.textSecondary
        message.setAccessibilityIdentifier("today-inbox-item-unavailable")
        addFullWidth(message, to: contentStack)
        layoutSubtreeIfNeeded()
        message.scrollToVisible(message.bounds)
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

    private func render(_ state: State) {
        let focusedID = inboxRows.first { $0.value === window?.firstResponder }?.key
        inboxRows.removeAll()
        contentStack.removeAllArrangedSubviews()
        switch state {
        case let .loaded(snapshot):
            lastRenderedState = "loaded"
            lastRenderedRowCount = snapshot.inbox.reduce(0) { $0 + $1.items.count }
                + snapshot.queue.count
                + snapshot.upcomingMeetings.count
                + snapshot.activeActivities.count
                + 1 // Daily Brief
            render(snapshot)
        case let .unavailable(message):
            lastRenderedState = "unavailable"
            lastRenderedRowCount = 0
            addFullWidth(makeContentState(
                symbol: "○",
                title: "Today is not configured",
                message: message,
                actionTitle: "Open Settings",
                action: { [weak self] in self?.onSelectArea(.settings) }
            ), to: contentStack)
        case let .failed(message):
            lastRenderedState = "failed"
            lastRenderedRowCount = 0
            addFullWidth(makeContentState(
                symbol: "!",
                title: "Today could not be loaded",
                message: message,
                actionTitle: "Try Again",
                action: { [weak self] in self?.refresh(isVisible: true) }
            ), to: contentStack)
        }
        if let id = unavailableInboxItemID {
            if inboxRows[id] == nil { appendUnavailableInboxMessage() }
            else { unavailableInboxItemID = nil }
        }
        if let focusedID, let replacement = inboxRows[focusedID] {
            window?.makeFirstResponder(replacement)
        }
    }

    /// Exercises representative presentation data in the whole-window harness.
    func validateFixtures() {
        render(.unavailable("Choose an Stillmatter root in Settings."))
        precondition(lastRenderedState == "unavailable" && contentStack.arrangedSubviews.count == 1)

        let empty = TodayDashboardSnapshot(
            recordingStatus: "Not recording",
            jobStatus: "Jobs idle",
            inbox: InboxCategory.allDisplayCases.map { TodayInboxSection(category: $0, items: []) },
            dailyBrief: .notGenerated(relativePath: "Briefs/Daily/2026-09-23.md"),
            queue: [],
            upcomingMeetings: [],
            activeActivities: []
        )
        render(.loaded(empty))
        precondition(lastRenderedState == "loaded" && lastRenderedRowCount == 1)
        precondition(contentStack.arrangedSubviews.count == 5, "Today must keep every empty workbench section visible")

        let longTitle = "Prepare the unusually detailed quarterly planning packet with localization and accessibility review"
        let todo = TodoItem(
            id: "fixture-todo",
            title: longTitle,
            rawText: longTitle,
            status: .blocked,
            dueDate: "2026-09-24",
            sourceRef: "Meetings/very-long-source-name/meeting.md",
            location: TodoSourceLocation(relativePath: "Todos/todo.md", lineNumber: 4),
            section: "Queue",
            indentation: 0,
            parentID: nil
        )
        let populated = TodayDashboardSnapshot(
            recordingStatus: "Recording Weekly planning",
            jobStatus: "1 Job failed",
            inbox: [
                TodayInboxSection(category: .required, items: [InboxItem(
                    id: "required", category: .required, kind: .titleReview, title: longTitle,
                    sourceRef: "Meetings/planning/meeting.md", details: nil, createdAt: "2026-09-23T08:00:00Z"
                )]),
                TodayInboxSection(category: .review, items: [InboxItem(
                    id: "proposal", category: .review, kind: .proposal, title: "Send follow-up",
                    sourceRef: "Meetings/planning/summary.md", details: nil, createdAt: "2026-09-23T08:01:00Z"
                )]),
                TodayInboxSection(category: .attention, items: [InboxItem(
                    id: "failed", category: .attention, kind: .failedJob, title: "Transcription failed",
                    sourceRef: nil, details: "Worker exited", createdAt: "2026-09-23T08:02:00Z"
                )])
            ],
            dailyBrief: .available(relativePath: "Briefs/Daily/2026-09-23.md"),
            queue: [todo],
            upcomingMeetings: [TodayMeeting(title: "Planning", time: "14:00")],
            activeActivities: [TodayActivity(title: "Graphite Focus", relativePath: "Activities/graphite-focus.md", project: "Stillmatter")]
        )
        render(.loaded(populated))
        layoutSubtreeIfNeeded()
        precondition(lastRenderedRowCount == 7, "Populated Today fixture must expose every collection row")
        precondition(focusInboxItem(id: "failed"), "Notification navigation must focus the exact Inbox row")
        precondition(!focusInboxItem(id: "missing"), "Removed Inbox items must not focus another row")
        let arranged = contentStack.arrangedSubviews
        precondition(arranged.allSatisfy { abs($0.frame.width - contentStack.bounds.width) <= 4 }, "Today sections must use one aligned content column")
        let orderedFrames = arranged.map(\.frame).sorted { $0.minY < $1.minY }
        for (earlier, later) in zip(orderedFrames, orderedFrames.dropFirst()) {
            precondition(earlier.maxY <= later.minY + 1, "Today sections must not overlap")
        }

        render(.failed("Fixture failure"))
        precondition(lastRenderedState == "failed" && contentStack.arrangedSubviews.count == 1)
        render(stateProvider())
    }

    private func render(_ snapshot: TodayDashboardSnapshot) {
        let inboxStack = NSStackView()
        inboxStack.orientation = .vertical
        inboxStack.alignment = .leading
        inboxStack.spacing = GraphiteFocusPresentation.Space.panel
        for section in snapshot.inbox {
            let rows = section.items.map { item in
                let row = GraphiteFocusCollectionRow(
                    symbol: inboxSymbol(for: item.kind),
                    title: item.title,
                    metadata: inboxMetadata(for: item),
                    emphasis: item.kind == .proposal ? .proposal : .standard,
                    actionTitle: item.kind == .proposal ? "Review" : "Open",
                    action: { [weak self] in
                        guard let self = self else { return }
                        if item.kind == .proposal {
                            self.onReviewProposals()
                        } else if item.kind == .titleReview {
                            self.onReviewTitle(item)
                        } else {
                            self.onSelectArea(self.destination(for: item.kind))
                        }
                    }
                )
                inboxRows[item.id] = row
                return row
            }
            addFullWidth(makeSection(
                title: section.category.displayName,
                rows: rows,
                emptyMessage: "No \(section.category.displayName.lowercased()) items.",
                identifier: "today-inbox-\(section.category.rawValue)"
            ), to: inboxStack)
        }
        addFullWidth(makeGroup(title: "Inbox", content: inboxStack), to: contentStack)

        addFullWidth(makeDailyBrief(snapshot.dailyBrief), to: contentStack)

        let queueRows = snapshot.queue.map { item in
            GraphiteFocusCollectionRow(
                symbol: todoSymbol(for: item.status),
                title: item.title,
                metadata: todoMetadata(for: item),
                emphasis: item.status == .blocked ? .attention : .standard,
                action: { [weak self] in self?.onSelectArea(.tasks) }
            )
        }
        addFullWidth(makeSection(
            title: "Top Queue",
            rows: queueRows,
            emptyMessage: "No open Todo Items in the Queue.",
            identifier: "today-queue"
        ), to: contentStack)

        let meetingRows = snapshot.upcomingMeetings.map { meeting in
            GraphiteFocusCollectionRow(
                symbol: "◷",
                title: meeting.title,
                metadata: meeting.time.map { "Today at \($0)" } ?? "Time unavailable",
                action: { [weak self] in self?.onSelectArea(.meetings) }
            )
        }
        addFullWidth(makeSection(
            title: "Upcoming Meetings",
            rows: meetingRows,
            emptyMessage: "No upcoming Meetings are available.",
            identifier: "today-meetings"
        ), to: contentStack)

        let activityRows = snapshot.activeActivities.map { activity in
            GraphiteFocusCollectionRow(
                symbol: "◇",
                title: activity.title,
                metadata: "Project: \(activity.project)  ·  \(activity.relativePath)",
                action: { [weak self] in self?.onSelectArea(.projectsActivities) }
            )
        }
        addFullWidth(makeSection(
            title: "Active Activities",
            rows: activityRows,
            emptyMessage: "No active Activity Items.",
            identifier: "today-activities"
        ), to: contentStack)
    }

    private func makeDailyBrief(_ brief: TodayDailyBrief) -> NSView {
        let row: GraphiteFocusCollectionRow
        switch brief {
        case let .available(relativePath):
            row = GraphiteFocusCollectionRow(
                symbol: "✓",
                title: "Daily Brief ready",
                metadata: relativePath,
                actionTitle: "Open",
                action: { [weak self] in self?.onOpenDailyBrief(relativePath) }
            )
        case let .notGenerated(relativePath):
            row = GraphiteFocusCollectionRow(
                symbol: "○",
                title: "Daily Brief not generated yet",
                metadata: "Expected at \(relativePath)",
                actionTitle: "Refresh",
                action: { [weak self] in self?.refresh(isVisible: true) }
            )
        }
        return makePanel(title: "Daily Brief", content: row, identifier: "today-daily-brief")
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
        identifier: String
    ) -> NSView {
        let rowsStack = NSStackView()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = GraphiteFocusPresentation.Space.flush
        if rows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "○  \(emptyMessage)")
            empty.font = GraphiteFocusPresentation.Typography.body
            empty.textColor = colors.textMetadata
            empty.setAccessibilityLabel(emptyMessage)
            addFullWidth(empty, to: rowsStack)
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
        let button = ClosureButton(title: actionTitle, action: action)
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
        case .overdueTodo: return "◷"
        case .weeklyReport: return "▤"
        case .titleReview: return "✎"
        case .cleanupProposal: return "△"
        }
    }

    private func inboxMetadata(for item: InboxItem) -> String {
        let kind: String
        switch item.kind {
        case .proposal: kind = "Action Item proposal — review before it becomes a Todo Item"
        case .failedJob: kind = "Failed Job"
        case .overdueTodo: kind = "Overdue Todo Item"
        case .weeklyReport: kind = "Weekly Report review"
        case .titleReview: kind = "Meeting title review"
        case .cleanupProposal: kind = "Cleanup proposal"
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

    private func destination(for kind: InboxItemKind) -> ShellTab {
        switch kind {
        case .weeklyReport: return .reports
        case .titleReview: return .meetings
        case .proposal, .failedJob, .overdueTodo, .cleanupProposal: return .today
        }
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

private final class ClosureButton: NSButton {
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
