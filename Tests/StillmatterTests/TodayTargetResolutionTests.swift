import XCTest
@testable import StillmatterCore

final class TodayTargetResolutionTests: XCTestCase {
    private func todo(_ line: Int, text: String = "Send report due: 2026-10-20") -> TodoItem {
        TodoItem(id: "Todos/todo.md:\(line)", title: "Send report", rawText: text,
                 status: .blocked, dueDate: "2026-10-20", sourceRef: "Meetings/a/summary.md",
                 location: TodoSourceLocation(relativePath: "Todos/todo.md", lineNumber: line),
                 section: "Queue", indentation: 0, parentID: nil)
    }

    func testQueueReorderResolvesUniqueCanonicalLineButNotRemovalDuplicateEditOrWorkspaceSwitch() {
        let original = todo(4)
        let moved = todo(12)
        XCTAssertEqual(TodayTargetResolution.queue(original, selectedOwner: "/A", owner: "/A",
                                                 current: [todo(3, text: "Other"), moved])?.id, moved.id)
        XCTAssertNil(TodayTargetResolution.queue(original, selectedOwner: "/A", owner: "/A", current: []))
        XCTAssertNil(TodayTargetResolution.queue(original, selectedOwner: "/A", owner: "/A",
                                               current: [moved, todo(13)]))
        XCTAssertNil(TodayTargetResolution.queue(original, selectedOwner: "/A", owner: "/A",
                                               current: [todo(4, text: "Edited")]))
        XCTAssertNil(TodayTargetResolution.queue(original, selectedOwner: "/A", owner: "/B", current: [moved]))
    }

    func testInboxReorderRefreshCompletionAndCollidingWorkspaceAreFailClosed() {
        let item = InboxItem(id: "title-review:meeting", category: .required, kind: .titleReview,
                             title: "Review title", sourceRef: nil, details: nil,
                             createdAt: "2026-10-20T00:00:00Z", workspaceOwner: "/A")
        let other = InboxItem(id: "other", category: .attention, kind: .failedJob,
                              title: "Failed", sourceRef: nil, details: nil,
                              createdAt: item.createdAt, workspaceOwner: "/A")
        XCTAssertEqual(TodayTargetResolution.inbox(item, owner: "/A", current: [other, item]), item)
        XCTAssertNil(TodayTargetResolution.inbox(item, owner: "/A", current: [other]))
        XCTAssertNil(TodayTargetResolution.inbox(item, owner: "/B", current: [item]))
        let colliding = InboxItem(id: item.id, category: item.category, kind: item.kind,
                                  title: item.title, sourceRef: nil, details: nil,
                                  createdAt: item.createdAt, workspaceOwner: "/B")
        XCTAssertNil(TodayTargetResolution.inbox(item, owner: "/B", current: [colliding]))
        XCTAssertNil(TodayTargetResolution.inbox(item, owner: "/A", current: [colliding]))
    }

    func testFailedJobRetryRequiresExactCurrentJobMeetingAndOwner() {
        let item = InboxItem(id: "job:job-2", category: .attention, kind: .failedJob,
                             title: "Summary failed", sourceRef: nil, details: "synthetic error",
                             createdAt: "2026-10-20T00:00:00Z", workspaceOwner: "/A")
        let meetings: [(meetingID: String, jobID: String, status: JobStatus)] = [
            ("unrelated", "job-1", .failed), ("wanted", "job-2", .failed)]
        func resolve(_ owner: String = "/A", _ jobOwner: String? = "/A",
                     _ status: JobStatus = .failed,
                     _ rows: [(meetingID: String, jobID: String, status: JobStatus)] = meetings) -> String? {
            TodayTargetResolution.retryableMeetingID(for: item, owner: owner, jobID: "job-2",
                jobOwner: jobOwner, jobStatus: status, meetings: rows)
        }
        XCTAssertEqual(resolve(), "wanted")
        XCTAssertNil(resolve("/B"))
        XCTAssertNil(resolve("/A", "/B"))
        XCTAssertNil(resolve("/A", "/A", .succeeded))
        XCTAssertNil(resolve("/A", "/A", .failed, [("other", "job-1", .failed)]))
        XCTAssertNil(resolve("/A", "/A", .failed, meetings + [("duplicate", "job-2", .failed)]))
    }

    func testCalendarSelectorPreservesStableEventIdentityThroughTodayProjection() {
        let selected = CalendarMeetingSelector(selection: .all).meetings(from: [
            CalendarMeetingEvent(calendarIdentifier: "c", title: "Same title", time: "14:00", eventIdentifier: "e2"),
            CalendarMeetingEvent(calendarIdentifier: "c", title: "Same title", time: "14:00", eventIdentifier: "e1")
        ])
        XCTAssertEqual(selected.map(\.eventIdentifier), ["e2", "e1"])
        XCTAssertEqual(selected.map(\.calendarIdentifier), ["c", "c"])
    }

    func testCalendarReferenceRequiresBothEventAndCalendarAndWorkspace() {
        let meeting = TodayMeeting(title: "Same title", time: "14:00", eventIdentifier: "event-a",
                                   calendarIdentifier: "calendar-a")
        XCTAssertTrue(TodayTargetResolution.calendar(meeting, selectedOwner: "/A", owner: "/A",
                                                    eventIdentifier: "event-a", calendarIdentifier: "calendar-a"))
        XCTAssertFalse(TodayTargetResolution.calendar(meeting, selectedOwner: "/A", owner: "/A",
                                                     eventIdentifier: "event-b", calendarIdentifier: "calendar-a"))
        XCTAssertFalse(TodayTargetResolution.calendar(meeting, selectedOwner: "/A", owner: "/A",
                                                     eventIdentifier: "event-a", calendarIdentifier: "calendar-b"))
        XCTAssertFalse(TodayTargetResolution.calendar(meeting, selectedOwner: "/A", owner: "/B",
                                                     eventIdentifier: "event-a", calendarIdentifier: "calendar-a"))
    }
}
