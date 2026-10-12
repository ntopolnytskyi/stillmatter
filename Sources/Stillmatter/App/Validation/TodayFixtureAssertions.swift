#if DEBUG
import AppKit
import StillmatterCore
import StillmatterPresentation

// Executed by the isolated native shell harness; never by normal view rendering.
extension TodayWorkbenchView {
    /// Exercises representative presentation data in the whole-window harness.
    func validateFixtures() {
        render(.unavailable("Choose an Stillmatter root in Settings."))
        precondition(lastRenderedState == "unavailable" && contentStack.arrangedSubviews.count == 1)

        let empty = TodayDashboardSnapshot(
            recordingStatus: "Not recording",
            jobStatus: "Jobs idle",
            inbox: InboxCategory.allDisplayCases.map { TodayInboxSection(category: $0, items: []) },
            queue: [],
            upcomingMeetings: []
        )
        render(.loaded(empty))
        precondition(lastRenderedState == "loaded" && lastRenderedRowCount == 0)
        precondition(contentStack.arrangedSubviews.count == 3, "Today must keep every empty workbench section visible")

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
            queue: [todo],
            upcomingMeetings: [TodayMeeting(title: "Planning", time: "14:00")]
        )
        render(.loaded(populated))
        layoutSubtreeIfNeeded()
        precondition(lastRenderedRowCount == 5, "Populated Today fixture must expose every collection row")
        precondition(contentStack.arrangedSubviews.count == 4, "Live status precedes decisions")
        var keyboardActivations = 0
        let returnButton = TodayClosureButton(title: "Return to decisions") { keyboardActivations += 1 }
        if let returnKey = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
            returnButton.keyDown(with: returnKey)
        }
        precondition(keyboardActivations == 1, "Return must activate an in-place detail control exactly once")
        let unchangedRow = inboxRows["proposal"]
        let unchangedCount = renderCountForValidation
        render(.loaded(populated))
        precondition(renderCountForValidation == unchangedCount && inboxRows["proposal"] === unchangedRow,
                     "Identical Today projection must not replace rows")
        precondition(focusInboxItem(id: "failed"), "Notification navigation must focus the exact Inbox row")
        precondition(!focusInboxItem(id: "missing"), "Removed Inbox items must not focus another row")
        let statusOnly = TodayDashboardSnapshot(
            recordingStatus: "Recording Weekly planning", jobStatus: "2 Jobs failed",
            inbox: populated.inbox, queue: populated.queue,
            upcomingMeetings: populated.upcomingMeetings
        )
        render(.loaded(statusOnly))
        precondition(inboxRows["proposal"] === unchangedRow,
                     "Status-only update must retain decision row identity")
        let reviewed = TodayDashboardSnapshot(
            recordingStatus: statusOnly.recordingStatus, jobStatus: statusOnly.jobStatus,
            inbox: statusOnly.inbox.map { section in
                section.category == .review ? TodayInboxSection(category: .review, items: []) : section
            },
            queue: statusOnly.queue,
            upcomingMeetings: statusOnly.upcomingMeetings
        )
        render(.loaded(reviewed))
        precondition(inboxRows["proposal"] == nil && !focusInboxItem(id: "proposal"),
                     "Reviewed proposal must disappear without approving another item")
        layoutSubtreeIfNeeded()
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

}
#endif
