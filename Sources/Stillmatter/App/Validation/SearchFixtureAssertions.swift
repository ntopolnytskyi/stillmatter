#if DEBUG
import AppKit
import StillmatterCore

// Native search walkthrough, invoked by the isolated shell probe.
extension SearchResultsView {
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
        print("TASK09_SEARCH synthetic walkthrough passed (DEBUG)")
    }
}
#endif
