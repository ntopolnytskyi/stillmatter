import XCTest
@testable import StillmatterCore

final class MeetingCalendarAssociationTests: XCTestCase {
    func testContextRoundTripsVerbatimTitlesAndRejectsMalformedMetadata() throws {
        let context = MeetingCalendarContext(event: nil, fallbackTitle: "Fallback", appliedTitle: "  🌍\n計画  ", manualTitle: false, status: "Unavailable")
        let markdown = try context.writing(to: "---\ntitle: Fallback\n---\n# Fallback\n")
        XCTAssertEqual(try MeetingCalendarContext.read(from: markdown), context)
        XCTAssertEqual(try MeetingCalendarContext.read(from: context.writing(to: markdown)), context)
        XCTAssertNil(try MeetingCalendarContext.read(from: "---\n---\n"))
        XCTAssertThrowsError(try context.writing(to: "# No metadata"))
        XCTAssertThrowsError(try MeetingCalendarContext.read(from: "calendar_context: !!!"))
        XCTAssertThrowsError(try MeetingCalendarContext.read(from: "calendar_context: YQ=="))
    }

    func testCaptureAssociatesRepeatedRecordingsAndDeniedAccessStillRecords() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: vault.rootURL, withIntermediateDirectories: true)
        var now = Date(timeIntervalSince1970: 1000)
        let event = CalendarMeeting(title: "  План / 計画  ", eventIdentifier: "event", calendarIdentifier: "work", eventStart: now, eventEnd: now.addingTimeInterval(600))
        var snapshot = CalendarMeetingSnapshot(events: [event], status: "Calendar available")
        let capture = MeetingCaptureService(vault: vault, preflight: { .readyForTesting }, calendarSnapshot: { snapshot }, now: { now })
        let first = try capture.startManual()
        XCTAssertEqual(first.title, event.title)
        _ = try capture.stopManual()
        now = now.addingTimeInterval(20)
        let second = try capture.startManual()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.meetingRelativePath, second.meetingRelativePath)
        XCTAssertEqual(second.title, event.title)
        _ = try capture.stopManual()
        let service = MeetingManagementService(vault: vault)
        XCTAssertEqual(try service.detail(for: first.id).calendarContext?.event, event)
        XCTAssertEqual(try service.detail(for: second.id).row.startedAt, now)
        snapshot = CalendarMeetingSnapshot(events: [], status: "Calendar access denied. Open Settings > Calendar.")
        let fallback = try capture.startManual()
        XCTAssertTrue(fallback.title.hasPrefix("Untitled Meeting"))
        XCTAssertEqual(try service.detail(for: fallback.id).calendarContext?.status, snapshot.status)
        _ = try capture.stopManual()
    }

    func testRelinkUnlinkAndResetPreserveManualTitleActualTimeAndIdentityAfterRestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        try FileManager.default.createDirectory(at: vault.rootURL, withIntermediateDirectories: true)
        let path = "Meetings/fixture/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Fallback\nstarted_at: 2026-11-15T10:03:00Z\ncapture_session_id: stable\n---\n# Fallback\n".utf8), relativePath: path, expectedVersion: nil)
        let service = MeetingManagementService(vault: vault)
        var detail = try service.detail(for: path)
        let actualStart = detail.row.startedAt
        let event = CalendarMeeting(title: "План / 計画", eventIdentifier: "event", calendarIdentifier: "work", eventStart: Date(timeIntervalSince1970: 1000), eventEnd: Date(timeIntervalSince1970: 2000))
        detail = try service.associateCalendar(meetingID: detail.row.id, event: event, resetTitle: true, expectedVersion: detail.doorwayVersion!)
        XCTAssertEqual(detail.row.title, "План / 計画")
        XCTAssertEqual(detail.calendarContext?.event, event)
        detail = try service.rename(meetingID: detail.row.id, title: "My title", expectedVersion: detail.doorwayVersion!)
        let other = CalendarMeeting(title: "Other event", eventIdentifier: "other", calendarIdentifier: "work", eventStart: event.eventStart, eventEnd: event.eventEnd)
        detail = try service.associateCalendar(meetingID: detail.row.id, event: other, expectedVersion: detail.doorwayVersion!)
        XCTAssertEqual(detail.row.title, "My title")
        detail = try service.associateCalendar(meetingID: detail.row.id, event: nil, expectedVersion: detail.doorwayVersion!)
        XCTAssertEqual(detail.row.title, "My title")
        XCTAssertNil(detail.calendarContext?.event)
        detail = try service.associateCalendar(meetingID: detail.row.id, event: event, resetTitle: true, expectedVersion: detail.doorwayVersion!)
        let reopened = try MeetingManagementService(vault: vault).detail(for: detail.row.id)
        XCTAssertEqual(reopened.row.id, "stable")
        XCTAssertEqual(reopened.row.title, "План / 計画")
        XCTAssertEqual(reopened.row.startedAt, actualStart)
        XCTAssertEqual(reopened.calendarContext?.event, event)
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.rootURL.appendingPathComponent(path).path))
    }
}
