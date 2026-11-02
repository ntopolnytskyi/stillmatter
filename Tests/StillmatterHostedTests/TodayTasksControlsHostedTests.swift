import AppKit
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

final class TodayTasksControlsHostedTests: XCTestCase {
    @MainActor
    func testSharedStyleNavigationFiltersAndCompletionKeepCanonicalIdentity() throws {
        let fixture = try TodayTasksFixture()
        defer { fixture.cleanup() }
        let controls = GraphiteFocusControls(style: .init(font: .monospacedSystemFont(ofSize: 18, weight: .medium), controlSize: .small))
        var opens: [String] = []
        let ledger = fixture.ledger(controls: controls, onOpen: { opens.append($0.id) })
        let window = fixture.window(ledger)
        ledger.refresh(isVisible: true)
        XCTAssertEqual(ledger.modeControl.font, controls.style.font)
        XCTAssertEqual(ledger.sourceFilterField.controlSize, .small)
        let item = try XCTUnwrap(ledger.visibleItems.first)
        let cell = try XCTUnwrap(ledger.tableView(ledger.tableView, viewFor: nil, row: 0) as? TodoLedgerCellView)
        XCTAssertEqual(cell.completionButton.font, controls.style.font)
        let today = fixture.today(controls: controls) { todo, _ in opens.append(todo.id) }
        today.refresh(isVisible: true)
        let row: NSButton = try control("today-todo-\(item.id)", in: today)
        XCTAssertEqual(row.font, controls.style.font)
        row.performClick(nil)
        XCTAssertEqual(opens, [item.id])
        let before = try fixture.text()
        ledger.sourceFilterField.stringValue = "notes"
        ledger.sourceFilterField.sendAction(try XCTUnwrap(ledger.sourceFilterField.action), to: ledger.sourceFilterField.target)
        XCTAssertEqual(ledger.visibleItems.map(\.id), [item.id])
        ledger.refresh(isVisible: false)
        ledger.refresh(isVisible: true)
        XCTAssertEqual(ledger.sourceFilterField.stringValue, "notes")
        XCTAssertEqual(try fixture.text(), before)
        cell.completionButton.performClick(nil)
        XCTAssertEqual(try fixture.views().done.map(\.id), [item.id])
        XCTAssertEqual(try fixture.views().allIndexed.filter { $0.id == item.id }.count, 1)
        XCTAssertTrue(window.firstResponder === ledger.stateContainer)
        XCTAssertTrue(try fixture.sourceText().contains("- [x] Personal task"))
        XCTAssertEqual(try fixture.text().components(separatedBy: "[[item:\(item.id)").count - 1, 1)
        ledger.sourceFilterField.stringValue = ""
        ledger.applyFilter()
        XCTAssertEqual(ledger.visibleItems.map(\.title), ["Second", "Third"])
        ledger.modeControl.selectedSegment = TodoLedgerView.Mode.done.rawValue
        ledger.modeControl.sendAction(try XCTUnwrap(ledger.modeControl.action), to: ledger.modeControl.target)
        let done = try XCTUnwrap(ledger.tableView(ledger.tableView, viewFor: nil, row: 0) as? TodoLedgerCellView)
        XCTAssertFalse(done.completionButton.isEnabled)
        done.completionButton.performClick(nil)
        XCTAssertEqual(try fixture.views().done.count, 1)
    }

    @MainActor
    func testKeyboardCompletionKeepsNearestRowAndRejectsStaleOrForeignWorkspace() throws {
        let fixture = try TodayTasksFixture()
        defer { fixture.cleanup() }
        let ledger = fixture.ledger()
        let window = fixture.window(ledger)
        ledger.refresh(isVisible: true)
        ledger.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        window.makeFirstResponder(ledger.tableView)
        ledger.tableView.keyDown(with: try key(49, " "))
        XCTAssertEqual(ledger.visibleItems.map(\.title), ["Personal task", "Third"])
        XCTAssertEqual(ledger.tableView.selectedRow, 1)
        XCTAssertTrue(window.firstResponder === ledger.tableView)
        ledger.render(.loaded(try fixture.views()))
        XCTAssertEqual(ledger.tableView.selectedRow, 1)
        // A valid external edit wins; stale row activation leaves it unchanged.
        try fixture.text().replacingOccurrences(of: "Third", with: "Externally changed").write(to: fixture.queue, atomically: true, encoding: .utf8)
        let external = try fixture.text()
        ledger.tableView.keyDown(with: try key(49, " "))
        XCTAssertEqual(try fixture.text(), external)
        let error: NSTextField = try control("tasks-completion-error", in: ledger)
        XCTAssertFalse(error.isHidden)
        XCTAssertTrue(window.firstResponder === ledger.tableView)
        let service = fixture.completion
        let item = try XCTUnwrap(fixture.views().queue.first)
        XCTAssertThrowsError(try service.complete(item, displayedRoot: fixture.root.appendingPathComponent("foreign")))
        XCTAssertThrowsError(try service.complete(item, displayedRoot: nil))
        let absent = TodoCompletion(appSupportRoot: fixture.support, workspaceRoot: { nil })
        XCTAssertThrowsError(try absent.complete(item, displayedRoot: fixture.workspace))
        XCTAssertEqual(try fixture.text(), external)
    }

    @MainActor
    func testEmptyFailedUnavailableRetryAndTodayDetailActions() throws {
        let fixture = try TodayTasksFixture()
        defer { fixture.cleanup() }
        var retries = 0
        var settings = 0
        let ledger = TodoLedgerView(stateProvider: { .failed("Controlled read failure") }, onRetry: { retries += 1 }, onOpenItem: { _ in }, onOpenSettings: { settings += 1 })
        ledger.refresh(isVisible: true)
        let retry: NSButton = try control("tasks-state-action", in: ledger)
        retry.performClick(nil)
        XCTAssertEqual(retries, 1)
        ledger.render(.unavailable("Choose a workspace"))
        let settingsButton: NSButton = try control("tasks-state-action", in: ledger)
        settingsButton.performClick(nil)
        XCTAssertEqual(settings, 1)
        ledger.render(.loaded(.init(queue: [], done: [], blocked: [], overdue: [], allIndexed: [])))
        XCTAssertEqual(ledger.renderedState, "empty")
        let today = fixture.today()
        let window = fixture.window(today)
        for state in [TodayWorkbenchView.State.loading, .failed("Read failed"), .unavailable("Configure workspace")] {
            today.render(state)
            let action: NSButton = try control("today-state-action", in: today)
            action.performClick(nil)
        }
        today.refresh(isVisible: true)
        let item = InboxItem(id: "failure", category: .attention, kind: .failedJob, title: "Failed job", sourceRef: nil, details: nil, createdAt: "2026-11-02")
        var actions = 0
        today.showDecisionDetail(item, actionTitle: "Retry", onAction: { actions += 1 })
        let action: NSButton = try control("today-decision-action", in: today)
        action.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(actions, 1)
        let close: NSButton = try control("today-return-decisions", in: today)
        close.performClick(nil)
        today.showMeetingDetail(.init(title: "Calendar", eventIdentifier: "event"), currentTitle: "Current title", currentTime: "10:00")
        let back: NSButton = try control("today-return-meetings", in: today)
        back.performClick(nil)
        today.showUnavailableInboxItem(id: "gone")
        let refresh: NSButton = try control("today-inbox-item-unavailable", in: today)
        XCTAssertTrue(window.firstResponder === refresh)
        refresh.performClick(nil)
    }

    @MainActor
    func testTodayQueueRefreshPreservesFocusAndSharedRowActivation() throws {
        let fixture = try TodayTasksFixture()
        defer { fixture.cleanup() }
        var opened: [String] = []
        let today = fixture.today { item, _ in opened.append(item.id) }
        let window = fixture.window(today)
        today.refresh(isVisible: true)
        let row: NSButton = try control("today-todo-\(fixture.itemID)", in: today)
        window.makeFirstResponder(row)
        try fixture.sourceText().replacingOccurrences(of: "Personal task", with: "Edited title").write(to: fixture.source, atomically: true, encoding: .utf8)
        today.refresh(isVisible: true)
        let refreshed: NSButton = try control("today-todo-\(fixture.itemID)", in: today)
        XCTAssertTrue(window.firstResponder === refreshed)
        refreshed.keyDown(with: try key(36, "\r"))
        XCTAssertEqual(opened, [fixture.itemID])
        window.setContentSize(NSSize(width: 660, height: 460))
        today.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(refreshed.frame.width, 0)
    }

    @MainActor
    func testLegacySelectionSurvivesInsertionAndTodayFocusFallsBackAfterRemoval() throws {
        let fixture = try TodayTasksFixture()
        defer { fixture.cleanup() }
        let ledger = fixture.ledger()
        let ledgerWindow = fixture.window(ledger)
        ledger.refresh(isVisible: true)
        ledger.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        ledgerWindow.makeFirstResponder(ledger.tableView)
        try fixture.text().replacingOccurrences(of: "## Queue\n", with: "## Queue\n- [ ] Inserted\n").write(to: fixture.queue, atomically: true, encoding: .utf8)
        ledger.refresh(isVisible: true)
        XCTAssertEqual(ledger.visibleItems[ledger.tableView.selectedRow].title, "Second")
        XCTAssertTrue(ledgerWindow.firstResponder === ledger.tableView)
        let today = fixture.today()
        let window = fixture.window(today)
        today.refresh(isVisible: true)
        let item = try XCTUnwrap(fixture.views().queue.first { $0.title == "Second" })
        let focused: NSButton = try control("today-todo-\(item.id)", in: today)
        window.makeFirstResponder(focused)
        try fixture.text().replacingOccurrences(of: "- [ ] Inserted\n", with: "").write(to: fixture.queue, atomically: true, encoding: .utf8)
        today.refresh(isVisible: true)
        let reordered = try XCTUnwrap(fixture.views().queue.first { $0.title == "Second" })
        let row: NSButton = try control("today-todo-\(reordered.id)", in: today)
        XCTAssertTrue(window.firstResponder === row)
        today.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(row.frame.width, 0)
        XCTAssertTrue(row.hitTest(NSPoint(x: row.frame.midX, y: row.frame.midY)) === row)
        try fixture.text().replacingOccurrences(of: "- [ ] Second\n", with: "").write(to: fixture.queue, atomically: true, encoding: .utf8)
        today.refresh(isVisible: true)
        let next = try XCTUnwrap(fixture.views().queue.last)
        let nextRow: NSButton = try control("today-todo-\(next.id)", in: today)
        XCTAssertTrue(window.firstResponder === nextRow)
        try "## Queue\n\n## Done\n".write(to: fixture.queue, atomically: true, encoding: .utf8)
        today.refresh(isVisible: true)
        let emptyAction: NSButton = try control("today-empty-queue-action", in: today)
        XCTAssertTrue(window.firstResponder === emptyAction)
        emptyAction.performClick(nil)
    }

    @MainActor
    private func control<T: NSView>(_ id: String, in view: NSView) throws -> T {
        if view.accessibilityIdentifier() == id, let found = view as? T { return found }
        for child in view.subviews { if let found: T = try? control(id, in: child) { return found } }
        throw NSError(domain: "TodayTasksTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(id)"])
    }

    private func key(_ code: UInt16, _ characters: String) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }
}

@MainActor
private final class TodayTasksFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-today-tasks-\(UUID().uuidString)")
    var workspace: URL { root.appendingPathComponent("workspace") }
    var support: URL { root.appendingPathComponent("support") }
    var queue: URL { workspace.appendingPathComponent("Todos/todo.md") }
    var source: URL { workspace.appendingPathComponent("Meetings/one/my-notes.md") }
    let itemID = "ee935d20-e388-4ccf-b6bd-1f5dc785fd01"
    var completion: TodoCompletion { TodoCompletion(appSupportRoot: support, workspaceRoot: { self.workspace }) }

    init() throws {
        for directory in [queue.deletingLastPathComponent(), source.deletingLastPathComponent(), support] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let encoded = #"{"v":1,"id":"ee935d20-e388-4ccf-b6bd-1f5dc785fd01","owner":"me","review":"approved","origin":"notes","citations":[]}"#
        try "# Notes\n- [ ] Personal task <!-- sm-item:\(encoded) -->\n".write(to: source, atomically: true, encoding: .utf8)
        try "## Queue\n- [[item:\(itemID)|Personal task]]\n- [ ] Second\n- [ ] Third\n\n## Done\n".write(to: queue, atomically: true, encoding: .utf8)
    }

    func views() throws -> TodoTaskViews { try TodoItemIndex(workspaceRootURL: workspace).loadTaskViews(today: "2026-11-02") }
    func text() throws -> String { try String(contentsOf: queue) }
    func sourceText() throws -> String { try String(contentsOf: source) }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
    func window(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        return window
    }
    func ledger(controls: GraphiteFocusControls = GraphiteFocusControls(), onOpen: @escaping (TodoItem) -> Void = { _ in }) -> TodoLedgerView {
        TodoLedgerView(controls: controls, completion: completion, stateProvider: { .loaded(try! self.views()) }, onRetry: {}, onOpenItem: onOpen, onOpenSettings: {})
    }
    func today(controls: GraphiteFocusControls = GraphiteFocusControls(), onOpen: @escaping (TodoItem, String?) -> Void = { _, _ in }) -> TodayWorkbenchView {
        TodayWorkbenchView(controls: controls, stateProvider: {
            .loaded(.init(recordingStatus: "Not recording", jobStatus: "Jobs idle", workspaceOwner: self.workspace.path,
                inbox: InboxCategory.allDisplayCases.map { .init(category: $0, items: []) }, queue: try! self.views().queue, upcomingMeetings: []))
        }, onRetry: {}, onSelectArea: { _ in }, onReviewProposals: { _ in }, onOpenDecision: { _ in }, onOpenMeeting: { _, _ in }, onOpenTodo: onOpen)
    }
}
