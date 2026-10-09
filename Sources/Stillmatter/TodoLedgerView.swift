import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Dense, read-only Precision Ledger for canonical Todo Items.
final class TodoLedgerView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    override var isFlipped: Bool { true }

    enum State {
        case loaded(TodoTaskViews)
        case unavailable(String)
        case failed(String)
    }

    private enum Mode: Int, CaseIterable {
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

    private let stateProvider: () -> State
    private var onOpenItem: (TodoItem) -> Void
    private let onOpenSettings: () -> Void
    private let modeControl = NSSegmentedControl(labels: Mode.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let sourceFilterField = NSSearchField()
    private let contextLabel = NSTextField(labelWithString: "")
    private let tableView = TodoLedgerTableView()
    private let scrollView = NSScrollView()
    private let stateContainer = NSView()
    private var loadedViews: TodoTaskViews?
    private var visibleItems: [TodoItem] = []
    private var parentTitles: [String: String] = [:]
    private var renderedState = ""

    init(
        stateProvider: @escaping () -> State,
        onOpenItem: @escaping (TodoItem) -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.stateProvider = stateProvider
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
            ?? TodoLedgerCellView(identifier: identifier)
        cell.configure(item, parentTitle: item.parentID.flatMap { parentTitles[$0] })
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

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(modeControl)
        addSubview(sourceFilterField)
        addSubview(contextLabel)
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
            contextLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            contextLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            contextLabel.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.panel),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            stateContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            stateContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stateContainer.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            stateContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    private func render(_ state: State) {
        stateContainer.subviews.forEach { $0.removeFromSuperview() }
        switch state {
        case let .loaded(views):
            let selectedID = visibleItems.indices.contains(tableView.selectedRow) ? visibleItems[tableView.selectedRow].id : nil
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

    private func applyFilter(preserving selectedID: String? = nil) {
        guard let views = loadedViews else { return }
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
            let index = selectedID.flatMap { id in visibleItems.firstIndex(where: { $0.id == id }) } ?? 0
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
            stack.addArrangedSubview(NSButton(title: actionTitle, target: self, action: action))
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

    private func activateSelectedItem() {
        guard visibleItems.indices.contains(tableView.selectedRow) else { return }
        onOpenItem(visibleItems[tableView.selectedRow])
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) { applyFilter() }
    @objc private func sourceFilterChanged(_ sender: NSSearchField) { applyFilter() }
    @objc private func openSelectedItem(_ sender: Any?) { activateSelectedItem() }
    @objc private func openSettings(_ sender: Any?) { onOpenSettings() }
    @objc private func retry(_ sender: Any?) { render(stateProvider()) }

    /// Covers status anatomy, canonical order, nesting, filtering, empty/error states, and keyboard activation.
    func validateFixtures() {
        let parent = fixtureItem(id: "parent", title: "A very long parent Todo Item title that must truncate cleanly at minimum window width", status: .open, dueDate: "2026-09-30", sourceRef: "[[Meetings/planning/summary#My action items|ref]]", line: 4)
        let child = fixtureItem(id: "child", title: "Waiting on legal", status: .blocked, dueDate: "2026-09-20", sourceRef: nil, line: 5, parentID: parent.id, indentation: 2)
        let canceled = fixtureItem(id: "canceled", title: "Obsolete follow-up", status: .canceled, dueDate: nil, sourceRef: nil, line: 6)
        let done = fixtureItem(id: "done", title: "Filed notes", status: .done, dueDate: "2026-09-19", sourceRef: nil, line: 12, section: "Done")
        let external = TodoItem(id: "external", title: "Project task", rawText: "Project task", status: .open, dueDate: "2026-09-18", sourceRef: "[[Meetings/planning/summary|ref]]", location: TodoSourceLocation(relativePath: "Projects/General.md", lineNumber: 9), section: "Todos", indentation: 0, parentID: nil)
        let views = TodoTaskViews(queue: [parent, child, canceled], done: [done], blocked: [child], overdue: [child, external], allIndexed: [parent, child, canceled, done, external])

        render(.loaded(views))
        precondition(renderedState == "items" && visibleItems.map(\.id) == ["parent", "child", "canceled"], "Queue order must remain physical canonical order")
        precondition(tableView.selectedRow == 0, "Todo ledger must expose a keyboard selection")
        modeControl.selectedSegment = Mode.done.rawValue
        applyFilter()
        precondition(visibleItems.map(\.id) == ["done"])
        modeControl.selectedSegment = Mode.blocked.rawValue
        applyFilter()
        precondition(visibleItems.map(\.id) == ["child"])
        modeControl.selectedSegment = Mode.overdue.rawValue
        applyFilter()
        precondition(visibleItems.map(\.id) == ["child", "external"])
        sourceFilterField.stringValue = "planning"
        applyFilter()
        precondition(visibleItems.map(\.id) == ["external"] && contextLabel.stringValue.contains("Overdue") && contextLabel.stringValue.contains("Source filter"))
        sourceFilterField.stringValue = "no-such-source"
        applyFilter()
        precondition(renderedState == "no-matches" && !stateContainer.isHidden)
        sourceFilterField.stringValue = ""
        render(.loaded(TodoTaskViews(queue: [], done: [], blocked: [], overdue: [], allIndexed: [])))
        precondition(renderedState == "empty")
        render(.unavailable("Choose an Stillmatter root in Settings."))
        precondition(renderedState == "unavailable")
        render(.failed("Fixture read failure"))
        precondition(renderedState == "failed")

        var activationCount = 0
        let originalHandler = onOpenItem
        onOpenItem = { _ in activationCount += 1 }
        modeControl.selectedSegment = Mode.queue.rawValue
        render(.loaded(views))
        let returnEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        tableView.keyDown(with: returnEvent)
        onOpenItem = originalHandler
        precondition(activationCount == 1, "Return must activate the selected Todo Item")
        render(stateProvider())
    }

    private func fixtureItem(id: String, title: String, status: TodoStatus, dueDate: String?, sourceRef: String?, line: Int, parentID: String? = nil, indentation: Int = 0, section: String = "Queue") -> TodoItem {
        TodoItem(id: id, title: title, rawText: title, status: status, dueDate: dueDate, sourceRef: sourceRef, location: TodoSourceLocation(relativePath: "Todos/todo.md", lineNumber: line), section: section, indentation: indentation, parentID: parentID)
    }
}

private final class TodoLedgerTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class TodoLedgerCellView: NSTableCellView {
    private let statusLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let meaningLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ item: TodoItem, parentTitle: String?) {
        let presentation = Self.presentation(for: item.status)
        statusLabel.stringValue = presentation.symbol
        statusLabel.textColor = presentation.color
        meaningLabel.stringValue = presentation.name.uppercased()
        meaningLabel.textColor = presentation.color
        titleLabel.stringValue = item.title

        var metadata: [String] = []
        if let dueDate = item.dueDate { metadata.append("Due \(dueDate)") }
        if let sourceRef = item.sourceRef { metadata.append("Source \(sourceRef)") }
        if let parentTitle = parentTitle { metadata.append("Child of \(parentTitle)") }
        metadata.append("\(item.location.relativePath):\(item.location.lineNumber)")
        metadataLabel.stringValue = metadata.joined(separator: "  •  ")
        setAccessibilityLabel("\(presentation.name) Todo Item: \(item.title). \(metadataLabel.stringValue)")
    }

    private func buildLayout() {
        statusLabel.font = GraphiteFocusPresentation.Typography.control
        statusLabel.alignment = .center
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        titleLabel.font = GraphiteFocusPresentation.Typography.body
        titleLabel.lineBreakMode = .byTruncatingTail
        meaningLabel.font = GraphiteFocusPresentation.Typography.caption
        meaningLabel.setContentHuggingPriority(.required, for: .horizontal)
        metadataLabel.font = GraphiteFocusPresentation.Typography.metadata
        metadataLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textMetadata
        metadataLabel.lineBreakMode = .byTruncatingMiddle

        let heading = NSStackView(views: [meaningLabel, titleLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = GraphiteFocusPresentation.Space.compact
        let detail = NSStackView(views: [heading, metadataLabel])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = GraphiteFocusPresentation.Space.primitive
        let row = NSStackView(views: [statusLabel, detail])
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

    private static func presentation(for status: TodoStatus) -> (symbol: String, name: String, color: NSColor) {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: nil))
        switch status {
        case .open: return ("☐", "Open", colors.textSecondary)
        case .done: return ("☑", "Done", colors.success)
        case .blocked: return ("⊘", "Blocked", colors.attention)
        case .canceled: return ("⊗", "Canceled", colors.textMetadata)
        }
    }
}
