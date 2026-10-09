import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Area-scoped, read-only search over the canonical Search Index.
final class SearchResultsView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    override var isFlipped: Bool { true }

    enum State {
        case emptyQuery
        case loading
        case unavailable
        case results([SearchResult])
        case noResults
        case failed(String)
    }

    private var onOpenResult: (SearchResult) -> Void
    private let onOpenSettings: () -> Void
    private let onRetry: () -> Void
    private let onDismiss: () -> Void
    private let contextLabel = NSTextField(labelWithString: "")
    private let tableView = SearchResultsTableView()
    private let scrollView = NSScrollView()
    private let stateContainer = NSView()
    private var results: [SearchResult] = []
    private var selectionContext: (query: String, scope: String, type: String)?
    private var selectedResult: SearchResult?
    private var renderedState = ""

    init(
        onOpenResult: @escaping (SearchResult) -> Void,
        onOpenSettings: @escaping () -> Void,
        onRetry: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onOpenResult = onOpenResult
        self.onOpenSettings = onOpenSettings
        self.onRetry = onRetry
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func render(query: String, scope: String, type: String, state: State) {
        let focusedResultsForSameSearch = resultsHaveKeyboardFocus
            && selectionContext?.query == query
            && selectionContext?.scope == scope
            && selectionContext?.type == type
        if let context = selectionContext,
           context.query == query && context.scope == scope && context.type == type {
            if results.indices.contains(tableView.selectedRow) {
                selectedResult = results[tableView.selectedRow]
            }
        } else {
            selectedResult = nil
        }
        selectionContext = (query, scope, type)
        contextLabel.stringValue = "Query: \(query.isEmpty ? "None" : "“\(query)”")   •   Scope: \(scope)   •   Type: \(type)"
        contextLabel.setAccessibilityValue(contextLabel.stringValue)
        results = []
        stateContainer.subviews.forEach { $0.removeFromSuperview() }

        switch state {
        case .emptyQuery:
            renderedState = "empty-query"
            showState(
                symbol: "⌕",
                title: "Search this area",
                message: "Enter a query in Area Search to find indexed workspace content.",
                actionTitle: "Close Search",
                action: #selector(dismiss(_:))
            )
        case .loading:
            renderedState = "loading"
            showState(symbol: "…", title: "Searching", message: "Searching the current area…")
        case .unavailable:
            renderedState = "unavailable"
            showState(
                symbol: "○",
                title: "Search Index unavailable",
                message: "Choose an Stillmatter root or rebuild the Search Index in Settings.",
                actionTitle: "Open Settings",
                action: #selector(openSettings(_:))
            )
        case let .results(newResults):
            renderedState = "results"
            results = newResults
        case .noResults:
            renderedState = "no-results"
            showState(symbol: "○", title: "No results", message: "Try another query, area, or result type.")
        case let .failed(message):
            renderedState = "failed"
            showState(
                symbol: "!",
                title: "Search failed",
                message: message,
                actionTitle: "Try Again",
                action: #selector(retry(_:))
            )
        }

        tableView.reloadData()
        tableView.isHidden = results.isEmpty
        scrollView.isHidden = results.isEmpty
        stateContainer.isHidden = !results.isEmpty
        if !results.isEmpty {
            let row = selectedResult.flatMap { results.firstIndex(of: $0) } ?? 0
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if focusedResultsForSameSearch { focusResults() }
        }
    }

    @discardableResult
    func focusResults() -> Bool {
        guard !results.isEmpty else { return false }
        if tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        return window?.makeFirstResponder(tableView) ?? false
    }

    var resultsHaveKeyboardFocus: Bool { window?.firstResponder === tableView }
    var resultCountForValidation: Int { results.count }

    func validateEscapeDismissesResults() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        )!
        tableView.keyDown(with: event)
    }

    func validateArrowNavigationKeepsFocus() {
        for (keyCode, character, expectedRow) in [(125, "\u{F701}", 1), (125, "\u{F701}", 1), (126, "\u{F700}", 0)] {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: UInt16(keyCode)
            )!
            tableView.keyDown(with: event)
            precondition(tableView.selectedRow == expectedRow && resultsHaveKeyboardFocus,
                         "Arrow navigation must keep focus and selection in search results")
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 88 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let result = results[row]
        let identifier = NSUserInterfaceItemIdentifier("SearchResult")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? SearchResultCellView)
            ?? SearchResultCellView(identifier: identifier)
        cell.configure(result)
        return cell
    }

    private func buildLayout() {
        contextLabel.font = GraphiteFocusPresentation.Typography.metadata
        contextLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textSecondary
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.setAccessibilityLabel("Search context")
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.selectionHighlightStyle = .regular
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelectedResult(_:))
        tableView.onReturn = { [weak self] in self?.activateSelectedResult() }
        tableView.onEscape = { [weak self] in self?.onDismiss() }
        tableView.setAccessibilityLabel("Search results")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stateContainer.translatesAutoresizingMaskIntoConstraints = false

        addSubview(contextLabel)
        addSubview(scrollView)
        addSubview(stateContainer)
        NSLayoutConstraint.activate([
            contextLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            contextLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            contextLabel.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.panel),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stateContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            stateContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            stateContainer.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            stateContainer.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    private func showState(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: Selector? = nil
    ) {
        let symbolLabel = NSTextField(labelWithString: symbol)
        symbolLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = GraphiteFocusPresentation.Typography.body
        messageLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textSecondary

        let stack = NSStackView(views: [symbolLabel, titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.compact
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let actionTitle = actionTitle, let action = action {
            let button = NSButton(title: actionTitle, target: self, action: action)
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
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

    private func activateSelectedResult() {
        guard results.indices.contains(tableView.selectedRow) else { return }
        onOpenResult(results[tableView.selectedRow])
    }

    @objc private func openSelectedResult(_ sender: Any?) { activateSelectedResult() }
    @objc private func openSettings(_ sender: Any?) { onOpenSettings() }
    @objc private func retry(_ sender: Any?) { onRetry() }
    @objc private func dismiss(_ sender: Any?) { onDismiss() }

    /// Exercises every content state and representative row anatomy in the whole-window harness.
    func validateFixtures() {
        render(query: "", scope: "Today", type: "All types", state: .emptyQuery)
        precondition(renderedState == "empty-query" && !stateContainer.isHidden)
        render(query: "planning", scope: "Meetings", type: "Transcript", state: .loading)
        precondition(renderedState == "loading")
        render(query: "planning", scope: "Meetings", type: "Transcript", state: .unavailable)
        precondition(renderedState == "unavailable")
        render(query: "missing", scope: "Meetings", type: "All types", state: .noResults)
        precondition(renderedState == "no-results")
        render(query: "planning", scope: "Meetings", type: "Transcript", state: .failed("Fixture failure"))
        precondition(renderedState == "failed")

        let fixtures = [
            SearchResult(
                kind: .transcript,
                sourcePath: "Meetings/2026-09-23-an-extraordinarily-long-planning-meeting-name/transcript.json",
                title: "Quarterly planning and accessibility review",
                body: "A deliberately long transcript excerpt verifies that evidence truncates without overlapping the source path or neighboring controls at minimum width.",
                transcriptStartSeconds: 83.5,
                transcriptEndSeconds: 91
            ),
            SearchResult(kind: .todo, sourcePath: "Todos/todo.md", title: "Send follow-up", body: "Confirm the revised launch date.")
        ]
        render(query: "planning", scope: "Today", type: "All types", state: .results(fixtures))
        layoutSubtreeIfNeeded()
        precondition(renderedState == "results" && tableView.numberOfRows == 2)
        precondition(tableView.selectedRow == 0, "Search results must expose a keyboard selection")
        precondition(contextLabel.stringValue.contains("Scope: Today") && contextLabel.stringValue.contains("Type: All types"))
        tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        render(query: "planning", scope: "Today", type: "All types", state: .loading)
        render(query: "planning", scope: "Today", type: "All types", state: .results(fixtures))
        precondition(tableView.selectedRow == 1, "Refreshing the same search must preserve the selected result")
        render(query: "different", scope: "Today", type: "All types", state: .results(fixtures))
        precondition(tableView.selectedRow == 0, "Changing the query must start at the first result")

        var activationCount = 0
        let productionHandler = onOpenResult
        onOpenResult = { _ in activationCount += 1 }
        let returnEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        )!
        tableView.keyDown(with: returnEvent)
        NSApp.sendAction(tableView.doubleAction!, to: tableView.target, from: tableView)
        onOpenResult = productionHandler
        precondition(activationCount == 2, "Return and double-click actions must both activate the selected search result")

        var revealedURL: URL?
        let fixtureURL = URL(fileURLWithPath: "/tmp/stillmatter-search-result.md")
        WorkspaceSourceOpener.present(
            fixtureURL,
            fileExists: { _ in true },
            open: { _ in false },
            reveal: { revealedURL = $0 }
        )
        precondition(revealedURL == fixtureURL, "A source without a default application must be revealed instead of failing silently")
    }
}

enum WorkspaceSourceOpener {
    static func present(
        _ url: URL,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        open: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        reveal: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) {
        guard fileExists(url) else {
            reveal(url.deletingLastPathComponent())
            return
        }
        if !open(url) {
            reveal(url)
        }
    }
}


private final class SearchResultsTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onReturn?()
        case 53: onEscape?()
        default: super.keyDown(with: event)
        }
    }
}

private final class SearchResultCellView: NSTableCellView {
    private let kindLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let excerptLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ result: SearchResult) {
        kindLabel.stringValue = result.displayKindName.uppercased()
        titleLabel.stringValue = result.title
        let timestamp = result.transcriptStartSeconds.map { " • \(Self.timestamp($0))" } ?? ""
        sourceLabel.stringValue = result.sourcePath + timestamp
        excerptLabel.stringValue = result.body.replacingOccurrences(of: "\n", with: " ")
        setAccessibilityLabel("\(result.displayKindName): \(result.title). \(result.sourcePath)\(timestamp). \(excerptLabel.stringValue)")
    }

    private func buildLayout() {
        kindLabel.font = GraphiteFocusPresentation.Typography.caption
        kindLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).accent
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = GraphiteFocusPresentation.Typography.control
        titleLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.font = GraphiteFocusPresentation.Typography.metadata
        sourceLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textMetadata
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        excerptLabel.font = GraphiteFocusPresentation.Typography.body
        excerptLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textSecondary
        excerptLabel.lineBreakMode = .byTruncatingTail
        excerptLabel.maximumNumberOfLines = 2

        let heading = NSStackView(views: [kindLabel, titleLabel])
        heading.orientation = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = GraphiteFocusPresentation.Space.compact
        let stack = NSStackView(views: [heading, sourceLabel, excerptLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.primitive
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphiteFocusPresentation.Space.panel),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GraphiteFocusPresentation.Space.panel),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: GraphiteFocusPresentation.Space.compact),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -GraphiteFocusPresentation.Space.compact),
            heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
            sourceLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            excerptLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
