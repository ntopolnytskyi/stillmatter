import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

#if DEBUG
extension TodoLedgerView {
    /// Covers status anatomy, canonical order, nesting, filtering, empty/error states, and keyboard activation.
    func validateFixtures() {
        let parent = fixtureItem(id: "parent", title: "A very long parent Todo Item title that must truncate cleanly at minimum window width and still be available through tooltip and VoiceOver", status: .open, dueDate: "2026-09-30", sourceRef: "[[Meetings/2026/09/20/дуже-довга-назва-наради-з-перекладеним-шляхом/summary#My action items|ref]]", line: 4)
        let child = fixtureItem(id: "child", title: "Waiting on legal", status: .blocked, dueDate: "2026-09-20", sourceRef: nil, line: 5, parentID: parent.id, indentation: 2)
        let canceled = fixtureItem(id: "canceled", title: "Obsolete follow-up", status: .canceled, dueDate: nil, sourceRef: nil, line: 6)
        let done = fixtureItem(id: "done", title: "Filed notes", status: .done, dueDate: "2026-09-19", sourceRef: nil, line: 12, section: "Done")
        let external = TodoItem(id: "external", title: "Project task", rawText: "Project task", status: .open, dueDate: "2026-09-18", sourceRef: "[[Meetings/planning/summary|ref]]", location: TodoSourceLocation(relativePath: "Projects/General.md", lineNumber: 9), section: "Todos", indentation: 0, parentID: nil)
        let views = TodoTaskViews(queue: [parent, child, canceled], done: [done], blocked: [child], overdue: [child, external], allIndexed: [parent, child, canceled, done, external])

        render(.loaded(views))
        precondition(renderedState == "items" && visibleItems.map(\.id) == ["parent", "child", "canceled"], "Queue order must remain physical canonical order")
        precondition(tableView.selectedRow == 0, "Todo ledger must expose a keyboard selection")
        let overflowCell = TodoLedgerCellView(identifier: NSUserInterfaceItemIdentifier("TodoOverflowFixture"))
        overflowCell.configure(parent, parentTitle: nil)
        precondition(overflowCell.hasFullOverflowTextForValidation(parent.title), "Todo rows must expose full long titles outside the truncated visual line")
        let canceledCell = TodoLedgerCellView(identifier: NSUserInterfaceItemIdentifier("TodoCanceledFixture"))
        canceledCell.configure(canceled, parentTitle: nil)
        precondition(canceledCell.hasCanceledDomainPresentationForValidation(),
                     "Canceled Todo Items must use domain status presentation rather than disabled-control styling")
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
        precondition(contextLabel.toolTip?.contains("no-such-source") == true, "Filtered empty state must expose the full active filter")
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
#endif
