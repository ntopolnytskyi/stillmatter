import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Dense Precision Ledger for canonical Todo Items.
final class TodoLedgerView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    override var isFlipped: Bool { true }

    enum State {
        case loaded(TodoTaskViews)
        case unavailable(String)
        case failed(String)
    }

    enum Mode: Int, CaseIterable {
        case queue
        case done
        case blocked
        case overdue

        var title: String {
            switch self {
            case .queue: return "Queue"
            case .done: return "Done"
            case .blocked: return "Blocked"
            case .overdue: return "Overdue"
            }
        }
    }

    private let controls: GraphiteFocusControls
    private let completion: TodoCompletion?
    private let onChange: () -> Void
    private var displayedRoot: URL?
    private lazy var completionRetry = controls.button("Refresh Tasks", identifier: "tasks-completion-retry", target: self, action: #selector(retry(_:)))
    private let completionError = NSTextField(wrappingLabelWithString: "")
    let stateProvider: () -> State
    private let onRetry: () -> Void
    var onOpenItem: (TodoItem) -> Void
    private let onOpenSettings: () -> Void
    let modeControl: NSSegmentedControl
    let sourceFilterField: NSSearchField
    let contextLabel = NSTextField(labelWithString: "")
    let tableView = TodoLedgerTableView()
    private let scrollView = NSScrollView()
    let stateContainer = TodoLedgerStateView()
    private var loadedViews: TodoTaskViews?
    var visibleItems: [TodoItem] = []
    private var parentTitles: [String: String] = [:]
    var renderedState = ""

    init(
        controls: GraphiteFocusControls = GraphiteFocusControls(),
        completion: TodoCompletion? = nil,
        onChange: @escaping () -> Void = {},
        stateProvider: @escaping () -> State,
        onRetry: @escaping () -> Void,
        onOpenItem: @escaping (TodoItem) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.controls = controls
        self.completion = completion
        self.onChange = onChange
        modeControl = controls.segments(Mode.allCases.map(\.title), identifier: "tasks-mode")
        sourceFilterField = controls.searchField(identifier: "tasks-source-filter")
        self.stateProvider = stateProvider
        self.onRetry = onRetry
        self.onOpenItem = onOpenItem
        self.onOpenSettings = onOpenSettings
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

    func numberOfRows(in tableView: NSTableView) -> Int { visibleItems.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 68 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = visibleItems[row]
        let identifier = NSUserInterfaceItemIdentifier("TodoLedgerRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TodoLedgerCellView)
            ?? TodoLedgerCellView(identifier: identifier, controls: controls)
        cell.configure(item, parentTitle: item.parentID.flatMap { parentTitles[$0] })
        cell.completionButton.isHidden = completion == nil
        cell.completionButton.target = self
        cell.completionButton.action = #selector(completeRow(_:))
        cell.completionButton.tag = row
        return cell
    }

    private func buildLayout() {
        modeControl.selectedSegment = Mode.queue.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setAccessibilityLabel("Todo view")
        modeControl.translatesAutoresizingMaskIntoConstraints = false

        sourceFilterField.placeholderString = "Filter by source or reference"
        sourceFilterField.sendsSearchStringImmediately = true
        sourceFilterField.target = self
        sourceFilterField.action = #selector(sourceFilterChanged(_:))
        sourceFilterField.delegate = self
        sourceFilterField.setAccessibilityLabel("Filter Todo Items by source")
        sourceFilterField.translatesAutoresizingMaskIntoConstraints = false

        contextLabel.font = GraphiteFocusPresentation.Typography.metadata
        contextLabel.textColor = colors.textSecondary
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.setAccessibilityLabel("Todo ledger context")
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("todo"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedItem(_:))
        tableView.onReturn = { [weak self] in self?.activateSelectedItem() }
        tableView.setAccessibilityLabel("Todo Items")
        tableView.setAccessibilityIdentifier("tasks-listing")
        tableView.onComplete = { [weak self] in
            guard let self, self.visibleItems.indices.contains(self.tableView.selectedRow) else { return }
            self.completeItem(at: self.tableView.selectedRow)
        }
        completionError.isHidden = true
        completionRetry.isHidden = true
        completionError.textColor = colors.destructive
        completionError.setAccessibilityIdentifier("tasks-completion-error")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.translatesAutoresizingMaskIntoConstraints = false

        let feedback = NSStackView(views: [contextLabel, completionError, completionRetry])
        feedback.orientation = .vertical
        feedback.alignment = .leading
        feedback.translatesAutoresizingMaskIntoConstraints = false
        addSubview(feedback)
        addSubview(modeControl)
        addSubview(sourceFilterField)
        addSubview(scrollView)
        addSubview(stateContainer)
        NSLayoutConstraint.activate([
            modeControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            modeControl.topAnchor.constraint(equalTo: topAnchor),
            sourceFilterField.leadingAnchor.constraint(greaterThanOrEqualTo: modeControl.trailingAnchor, constant: GraphiteFocusPresentation.Space.panel),
            sourceFilterField.trailingAnchor.constraint(equalTo: trailingAnchor),
            sourceFilterField.centerYAnchor.constraint(equalTo: modeControl.centerYAnchor),
            sourceFilterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            sourceFilterField.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            feedback.leadingAnchor.constraint(equalTo: leadingAnchor),
            feedback.trailingAnchor.constraint(equalTo: trailingAnchor),
            feedback.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: feedback.bottomAnchor, constant: GraphiteFocusPresentation.Space.panel),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            stateContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            stateContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stateContainer.topAnchor.constraint(equalTo: feedback.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            stateContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    /// Locate a Today row against the current canonical projection, not its old line number.
    @discardableResult
    func focusCanonicalItem(_ item: TodoItem, selectedOwner: String?, owner: String) -> Bool {
        guard let views = loadedViews,
              let match = TodayTargetResolution.queue(item, selectedOwner: selectedOwner,
                                                      owner: owner, current: views.queue) else { return false }
        modeControl.selectedSegment = Mode.queue.rawValue
        sourceFilterField.stringValue = ""
        applyFilter(preserving: match.id)
        guard let index = visibleItems.firstIndex(where: { $0.id == match.id }) else { return false }
        tableView.scrollRowToVisible(index)
        window?.makeFirstResponder(tableView)
        return true
    }

    var visibleTitlesForValidation: [String] { visibleItems.map(\.title) }
    private(set) var renderCountForValidation = 0

    func render(_ state: State) {
        renderCountForValidation += 1
        completionError.isHidden = true
        completionRetry.isHidden = true
        stateContainer.subviews.forEach { $0.removeFromSuperview() }
        switch state {
        case let .loaded(views):
            displayedRoot = completion?.workspaceRoot()
            let selected = visibleItems.indices.contains(tableView.selectedRow) ? visibleItems[tableView.selectedRow] : nil
            let selectedID = selected.flatMap { TodoSelection.resolve($0, in: views.allIndexed)?.id }
            loadedViews = views
            parentTitles = Dictionary(uniqueKeysWithValues: views.allIndexed.map { ($0.id, $0.title) })
            applyFilter(preserving: selectedID)
        case let .unavailable(message):
            loadedViews = nil
            visibleItems = []
            renderedState = "unavailable"
            contextLabel.stringValue = "Workspace unavailable"
            showState(symbol: "○", title: "Tasks are not configured", message: message, actionTitle: "Open Settings", action: #selector(openSettings(_:)))
            updateVisibility()
            tableView.reloadData()
        case let .failed(message):
            loadedViews = nil
            visibleItems = []
            renderedState = "failed"
            contextLabel.stringValue = "Todo Items could not be read"
            showState(symbol: "!", title: "Tasks could not be loaded", message: message, actionTitle: "Try Again", action: #selector(retry(_:)))
            updateVisibility()
            tableView.reloadData()
        }
    }

    func applyFilter(preserving selectedID: String? = nil) {
        guard let views = loadedViews else { return }
        let previousIndex = max(0, tableView.selectedRow)
        let query = sourceFilterField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let mode = Mode(rawValue: modeControl.selectedSegment) ?? .queue
        let items: [TodoItem]
        switch mode {
        case .queue: items = views.queue
        case .done: items = views.done
        case .blocked: items = views.blocked
        case .overdue: items = views.overdue
        }
        if !query.isEmpty {
            let matchingIDs = Set(views.sourceFiltered(query).map(\.id))
            visibleItems = items.filter { matchingIDs.contains($0.id) }
        } else {
            visibleItems = items
        }
        let filterNote = query.isEmpty ? "" : "  •  Source filter: “\(query)”"
        let orderNote = mode == .queue ? "  •  Canonical Queue order" : ""
        contextLabel.stringValue = "\(mode.title)\(filterNote)  •  \(visibleItems.count) Todo Item\(visibleItems.count == 1 ? "" : "s")\(orderNote)"
        GraphiteFocusOverflow.configureSecondaryMetadata(contextLabel, fullText: contextLabel.stringValue)
        contextLabel.setAccessibilityValue(contextLabel.stringValue)
        renderedState = visibleItems.isEmpty ? (query.isEmpty ? "empty" : "no-matches") : "items"
        stateContainer.subviews.forEach { $0.removeFromSuperview() }
        if visibleItems.isEmpty {
            showState(
                symbol: "○",
                title: query.isEmpty ? "No \(mode.title) Todo Items" : "No matching Todo Items",
                message: query.isEmpty ? emptyMessage(for: mode) : "Try a different source path or reference."
            )
        }
        updateVisibility()
        tableView.reloadData()
        if !visibleItems.isEmpty {
            let index = selectedID.flatMap { id in visibleItems.firstIndex(where: { $0.id == id }) } ?? min(previousIndex, visibleItems.count - 1)
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        }
    }

    private func emptyMessage(for mode: Mode) -> String {
        switch mode {
        case .queue: return "The canonical Queue is empty. Add Todo Items in Todos/todo.md."
        case .done: return "No completed Todo Items are available."
        case .blocked: return "No Todo Items are marked blocked."
        case .overdue: return "No open Todo Items are past their due date."
        }
    }

    private func updateVisibility() {
        let hasItems = !visibleItems.isEmpty
        scrollView.isHidden = !hasItems
        tableView.isHidden = !hasItems
        stateContainer.isHidden = hasItems
    }

    private func showState(symbol: String, title: String, message: String, actionTitle: String? = nil, action: Selector? = nil) {
        let symbolLabel = NSTextField(labelWithString: symbol)
        symbolLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = GraphiteFocusPresentation.Typography.body
        messageLabel.textColor = colors.textSecondary
        let stack = NSStackView(views: [symbolLabel, titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.compact
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let actionTitle = actionTitle, let action = action {
            stack.addArrangedSubview(controls.button(actionTitle, identifier: "tasks-state-action", target: self, action: action))
        }
        stateContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: stateContainer.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: stateContainer.trailingAnchor),
            stack.topAnchor.constraint(equalTo: stateContainer.topAnchor),
            stack.bottomAnchor.constraint(equalTo: stateContainer.bottomAnchor)
        ])
        stateContainer.setAccessibilityLabel("\(title). \(message)")
    }

    private var colors: GraphiteFocusPresentation.Colors {
        GraphiteFocusPresentation.Colors(environment: .system(window: window))
    }

    @objc private func completeRow(_ sender: NSButton) {
        completeItem(at: sender.tag)
    }

    private func completeItem(at index: Int) {
        guard let completion, visibleItems.indices.contains(index) else { return }
        let item = visibleItems[index]
        guard item.status == .open || item.status == .blocked else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        do {
            let views = try completion.complete(item, displayedRoot: displayedRoot)
            completionError.isHidden = true
            render(.loaded(views))
            window?.makeFirstResponder(visibleItems.isEmpty ? stateContainer : tableView)
            onChange()
        } catch {
            completionError.stringValue = "Could not complete this Todo Item. Refresh Tasks and try again. \(error)"
            completionError.isHidden = false
            completionRetry.isHidden = false
            tableView.reloadData()
            window?.makeFirstResponder(tableView)
        }
    }

    private func activateSelectedItem() {
        guard visibleItems.indices.contains(tableView.selectedRow) else { return }
        onOpenItem(visibleItems[tableView.selectedRow])
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) { applyFilter() }
    @objc private func sourceFilterChanged(_ sender: NSSearchField) { applyFilter() }
    @objc private func openSelectedItem(_ sender: Any?) { activateSelectedItem() }
    @objc private func openSettings(_ sender: Any?) { onOpenSettings() }
    @objc private func retry(_ sender: Any?) { onRetry() }


}

final class TodoLedgerStateView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

final class TodoLedgerTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onComplete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            onComplete?()
        } else if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

final class TodoLedgerCellView: NSTableCellView {
    let completionButton: NSButton
    private let statusLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let meaningLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier, controls: GraphiteFocusControls = GraphiteFocusControls()) {
        completionButton = controls.checkbox("", identifier: "task-complete")
        super.init(frame: .zero)
        self.identifier = identifier
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ item: TodoItem, parentTitle: String?) {
        completionButton.state = item.status == .done ? .on : .off
        completionButton.isEnabled = item.isFromMainTodoFile && (item.status == .open || item.status == .blocked)
        completionButton.setAccessibilityIdentifier("task-complete-\(item.id)")
        completionButton.setAccessibilityLabel("Complete \(item.title)")
        let presentation = Self.presentation(for: item.status)
        statusLabel.stringValue = presentation.symbol
        statusLabel.textColor = presentation.color
        meaningLabel.stringValue = presentation.name.uppercased()
        meaningLabel.textColor = presentation.color
        titleLabel.stringValue = item.title
        GraphiteFocusOverflow.configurePrimaryTitle(titleLabel, fullText: item.title)

        var metadata: [String] = []
        if let dueDate = item.dueDate { metadata.append("Due \(dueDate)") }
        if let sourceRef = item.sourceRef { metadata.append("Source \(sourceRef)") }
        if let parentTitle = parentTitle { metadata.append("Child of \(parentTitle)") }
        metadata.append("\(item.location.relativePath):\(item.location.lineNumber)")
        metadataLabel.stringValue = metadata.joined(separator: "  •  ")
        GraphiteFocusOverflow.configureSecondaryMetadata(metadataLabel, fullText: metadataLabel.stringValue)
        setAccessibilityLabel("\(presentation.name) Todo Item: \(item.title). \(metadataLabel.stringValue)")
    }

    private func buildLayout() {
        statusLabel.font = GraphiteFocusPresentation.Typography.control
        statusLabel.alignment = .center
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        titleLabel.font = GraphiteFocusPresentation.Typography.body
        GraphiteFocusOverflow.configurePrimaryTitle(titleLabel, fullText: "")
        meaningLabel.font = GraphiteFocusPresentation.Typography.caption
        meaningLabel.setContentHuggingPriority(.required, for: .horizontal)
        metadataLabel.font = GraphiteFocusPresentation.Typography.metadata
        metadataLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textMetadata
        GraphiteFocusOverflow.configureSecondaryMetadata(metadataLabel, fullText: "")

        let heading = NSStackView(views: [meaningLabel, titleLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = GraphiteFocusPresentation.Space.compact
        let detail = NSStackView(views: [heading, metadataLabel])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = GraphiteFocusPresentation.Space.primitive
        let row = NSStackView(views: [completionButton, statusLabel, detail])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = GraphiteFocusPresentation.Space.panel
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphiteFocusPresentation.Space.panel),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GraphiteFocusPresentation.Space.panel),
            row.topAnchor.constraint(equalTo: topAnchor, constant: GraphiteFocusPresentation.Space.compact),
            row.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -GraphiteFocusPresentation.Space.compact),
            heading.widthAnchor.constraint(equalTo: detail.widthAnchor),
            metadataLabel.widthAnchor.constraint(equalTo: detail.widthAnchor)
        ])
    }

    func hasFullOverflowTextForValidation(_ title: String) -> Bool {
        titleLabel.toolTip == title && titleLabel.accessibilityLabel() == title
            && metadataLabel.toolTip?.isEmpty == false
    }

    func hasCanceledDomainPresentationForValidation() -> Bool {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        return meaningLabel.stringValue == "CANCELED"
            && statusLabel.stringValue == "⊗"
            && statusLabel.textColor == GraphiteFocusStatusMeaning.destructive.color(in: colors)
            && statusLabel.textColor != colors.textDisabled
    }

    private static func presentation(for status: TodoStatus) -> (symbol: String, color: NSColor, name: String) {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: nil))
        switch status {
        case .open: return ("☐", colors.textSecondary, "Open")
        case .done: return ("☑", GraphiteFocusStatusMeaning.success.color(in: colors), "Done")
        case .blocked: return ("⊘", GraphiteFocusStatusMeaning.attention.color(in: colors), "Blocked")
        // Canceled is a domain status, not a disabled control. Keep its essential
        // label legible and use destructive meaning with a non-color marker.
        case .canceled: return ("⊗", GraphiteFocusStatusMeaning.destructive.color(in: colors), "Canceled")
        }
    }
}
