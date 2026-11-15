import AppKit
import EventKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingCalendarHostedTests: XCTestCase {
    @MainActor
    func testFailedRenameRetainsDraftForRetryAndCancelPreservesCanonicalMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rename-hosted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/original/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Original\ncapture_session_id: rename-fixture\n---\n# Original\n".utf8), relativePath: path, expectedVersion: nil)
        _ = try vault.writeMarkdown(Data("---\ntitle: Taken\ncapture_session_id: taken\n---\n# Taken\n".utf8), relativePath: "Meetings/taken/meeting.md", expectedVersion: nil)
        var invalidate: ([String]) -> Void = { _ in }
        let service = MeetingManagementService(vault: vault, onMeetingChanged: { invalidate($0) })
        let read = MeetingReadModel(workspaceID: root.path, sourceFactory: { MeetingManagementReadSource(serviceProvider: { service }) })
        invalidate = { read.invalidate(.appMutation(paths: $0)) }
        let executor = MeetingMutationExecutor(searchIndex: nil, captureSnapshot: nil, serviceFactory: { _, _ in service })
        let other = MeetingReadModel(workspaceID: "other", sourceFactory: { MeetingManagementReadSource(serviceProvider: { service }) })
        var provided = read
        var attempts = 0
        let view = MeetingManagementView(readModelProvider: { provided }, mutationExecutorProvider: { executor }, playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in }, presentConfirmationAlert: { alert in
            let input = alert.accessoryView as! NSTextField
            attempts += 1
            if attempts == 1 {
                input.stringValue = "Taken"
                return .alertFirstButtonReturn
            }
            if attempts == 2 {
                XCTAssertEqual(input.stringValue, "Taken", "Failure must preserve the entered title")
                return .alertSecondButtonReturn
            }
            if attempts == 3 {
                XCTAssertEqual(input.stringValue, "Original", "Cancel discards the rejected draft")
                input.stringValue = "Renamed"
            } else {
                provided = other
                input.stringValue = "Expired selection"
            }
            return .alertFirstButtonReturn
        })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.refresh(isVisible: false); read.stop(); other.stop(); window.orderOut(nil) }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail != nil && view.renameButton.isEnabled }, evaluatedWith: nil)], timeout: 10)
        _ = view.meetingsModel.select(meetingID: "rename-fixture", selectedIDs: ["rename-fixture"])
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail?.row.id == "rename-fixture" && view.renameButton.isEnabled }, evaluatedWith: nil)], timeout: 10)
        view.confirmRename()
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.retryFeedback?.1.contains("Could not rename") == true }, evaluatedWith: nil)], timeout: 10)
        XCTAssertTrue(view.status.stringValue.contains("choose an unused title"))
        view.confirmRename()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(try service.detail(for: "rename-fixture").row.meetingRelativePath, path)
        XCTAssertEqual(try service.detail(for: "rename-fixture").row.title, "Original")
        view.confirmRename()
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail?.row.title == "Renamed" }, evaluatedWith: nil)], timeout: 10)
        XCTAssertEqual(try service.detail(for: "rename-fixture").row.meetingRelativePath, "Meetings/renamed/meeting.md")
        XCTAssertEqual(view.retryFeedback?.message, "Meeting renamed.")
        view.confirmRename()
        XCTAssertEqual(attempts, 4)
        XCTAssertEqual(try service.detail(for: "rename-fixture").row.title, "Renamed")
    }

    @MainActor
    func testRelinkResetCancelUnavailableAndExpiredWorkspaceUseRealMutationPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-hosted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        _ = try vault.writeMarkdown(Data("---\ntitle: Manual title\ncapture_session_id: calendar-fixture\nstarted_at: 2026-11-15T10:03:00Z\n---\n# Manual title\n".utf8), relativePath: "Meetings/fixture/meeting.md", expectedVersion: nil)
        var invalidate: ([String]) -> Void = { _ in }
        let service = MeetingManagementService(vault: vault, onMeetingChanged: { invalidate($0) })
        let read = MeetingReadModel(workspaceID: root.path, sourceFactory: { MeetingManagementReadSource(serviceProvider: { service }) })
        invalidate = { read.invalidate(.appMutation(paths: $0)) }
        let other = MeetingReadModel(workspaceID: "other", sourceFactory: { MeetingManagementReadSource(serviceProvider: { service }) })
        var provided: MeetingReadModel? = read
        let executor = MeetingMutationExecutor(searchIndex: nil, captureSnapshot: nil, serviceFactory: { _, _ in service })
        let event = CalendarMeeting(title: "План / 計画", eventIdentifier: "event", calendarIdentifier: "calendar", eventStart: Date(timeIntervalSince1970: 1000), eventEnd: Date(timeIntervalSince1970: 2000))
        var events = [event, event]
        var confirmation = NSApplication.ModalResponse.alertFirstButtonReturn
        var requestedDate: Date?
        let view = MeetingManagementView(readModelProvider: { provided }, mutationExecutorProvider: { executor }, playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in }, presentConfirmationAlert: { alert in
            XCTAssertTrue(alert.informativeText.contains("External links may break"))
            return confirmation
        }, calendarSnapshot: { date in requestedDate = date; return CalendarMeetingSnapshot(events: events, status: "Test calendar context") })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.calendarEditor.cancel(); view.refresh(isVisible: false); read.stop(); other.stop(); window.orderOut(nil) }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail != nil && view.canEditCalendar }, evaluatedWith: nil)], timeout: 10)
        func waitForEvent(_ expected: CalendarMeeting?) async {
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail?.calendarContext?.event == expected }, evaluatedWith: nil)], timeout: 10)
        }
        window.makeFirstResponder(view.moreButton)
        view.editCalendar()
        XCTAssertTrue(view.calendarEditor.isOpen)
        XCTAssertEqual(requestedDate, ISO8601DateFormatter().date(from: "2026-11-15T10:03:00Z"))
        XCTAssertEqual(view.calendarEditor.picker.numberOfItems, 2)
        XCTAssertTrue(view.calendarEditor.link.isEnabled)
        XCTAssertFalse(view.calendarEditor.unlink.isEnabled)
        view.editCalendar() // Repeated presentation preserves the one sheet.
        view.calendarEditor.link.performClick(nil)
        await waitForEvent(event)
        XCTAssertEqual(view.displayedDetail?.row.title, "Manual title")
        view.editCalendar()
        view.calendarEditor.reset.state = .on
        view.calendarEditor.link.performClick(nil)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail?.row.title == event.title }, evaluatedWith: nil)], timeout: 10)
        XCTAssertTrue(view.calendarStatus.stringValue.contains("Scheduled:"))
        XCTAssertEqual(try service.detail(for: "calendar-fixture").row.startedAt, requestedDate)
        let original = try service.detail(for: "calendar-fixture").doorwayText
        let previousResponder = window.firstResponder
        view.editCalendar()
        view.calendarEditor.cancelButton.performClick(nil)
        XCTAssertFalse(view.calendarEditor.isOpen)
        XCTAssertTrue(window.firstResponder === previousResponder)
        XCTAssertEqual(try service.detail(for: "calendar-fixture").doorwayText, original)
        // Cancel the separate folder/title confirmation as well.
        confirmation = .alertSecondButtonReturn
        view.editCalendar(); view.calendarEditor.reset.state = .on
        view.calendarEditor.unlink.performClick(nil)
        XCTAssertEqual(try service.detail(for: "calendar-fixture").doorwayText, original)
        confirmation = .alertFirstButtonReturn
        view.editCalendar(); provided = other
        view.calendarEditor.unlink.performClick(nil)
        XCTAssertEqual(try service.detail(for: "calendar-fixture").doorwayText, original)
        provided = read; events = []
        view.editCalendar()
        XCTAssertFalse(view.calendarEditor.link.isEnabled)
        view.calendarEditor.reset.state = .on
        view.calendarEditor.unlink.performClick(nil)
        await waitForEvent(nil)
        XCTAssertEqual(view.displayedDetail?.row.title, "Manual title", "Explicit reset on unlink restores original fallback")
        XCTAssertEqual(view.calendarStatus.stringValue, "Unlinked")
        view.canEditCalendar = false
        view.editCalendar()
        XCTAssertFalse(view.calendarEditor.isOpen)
    }

    @MainActor
    func testLegacyTitleIsPreservedUntilExplicitResetAndCancelledFolderWarningPreservesFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("calendar-legacy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/legacy/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Untitled Meeting at 10:00\ncapture_session_id: legacy\n---\n# Untitled Meeting at 10:00\n".utf8), relativePath: path, expectedVersion: nil)
        let service = MeetingManagementService(vault: vault)
        let read = MeetingReadModel(workspaceID: root.path, sourceFactory: { MeetingManagementReadSource(serviceProvider: { service }) })
        let executor = MeetingMutationExecutor(searchIndex: nil, captureSnapshot: nil, serviceFactory: { _, _ in service })
        let event = CalendarMeeting(title: "Calendar title", eventIdentifier: "event", calendarIdentifier: "calendar")
        var warnings = 0
        let view = MeetingManagementView(readModelProvider: { read }, mutationExecutorProvider: { executor }, playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in }, presentConfirmationAlert: { alert in
            warnings += 1
            XCTAssertTrue(alert.informativeText.contains("External links may break"))
            return .alertSecondButtonReturn
        }, calendarSnapshot: { _ in CalendarMeetingSnapshot(events: [event], status: "Available") })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 850, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.calendarEditor.cancel(); view.refresh(isVisible: false); read.stop(); window.orderOut(nil) }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail != nil && view.canEditCalendar }, evaluatedWith: nil)], timeout: 10)
        view.editCalendar()
        XCTAssertEqual(view.calendarEditor.reset.state, .off)
        view.calendarEditor.link.performClick(nil)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail?.calendarContext?.event == event }, evaluatedWith: nil)], timeout: 10)
        XCTAssertEqual(warnings, 0)
        XCTAssertEqual(view.displayedDetail?.row.title, "Untitled Meeting at 10:00")
        let before = try vault.readMarkdown(relativePath: path).data
        view.editCalendar()
        view.calendarEditor.reset.state = .on
        view.calendarEditor.link.performClick(nil)
        XCTAssertEqual(warnings, 1)
        XCTAssertEqual(try vault.readMarkdown(relativePath: path).data, before)
    }

    @available(macOS 14.0, *)
    func testProviderHonorsDisabledDeniedAndPermittedSourcesWithoutReadingRealCalendars() {
        let store = FixtureEventStore()
        let calendar = EKCalendar(for: .event, eventStore: store)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar; event.title = "  План / 計画  "
        event.startDate = Date(timeIntervalSince1970: 1000); event.endDate = Date(timeIntervalSince1970: 2000)
        store.fixtureCalendars = [calendar]; store.fixtureEvents = [event]
        XCTAssertTrue(CalendarMeetingProvider(eventStore: store, calendarSelection: .none).snapshot().status.contains("disabled"))
        for denied in [EKAuthorizationStatus.denied, .restricted, .notDetermined, .writeOnly] {
            let snapshot = CalendarMeetingProvider(eventStore: store, authorizationStatus: { denied }).snapshot()
            XCTAssertTrue(snapshot.events.isEmpty)
            XCTAssertTrue(snapshot.status.contains("access unavailable"))
        }
        let provider = CalendarMeetingProvider(eventStore: store, authorizationStatus: { .fullAccess })
        XCTAssertEqual(provider.snapshot().events.first?.title, "  План / 計画  ")
        XCTAssertEqual(provider.snapshot().events.first?.eventEnd, event.endDate)
        XCTAssertEqual(provider.meetingsToday().count, 1)
        XCTAssertEqual(CalendarMeetingProvider(eventStore: store, calendarSelection: .selected(["missing"]), authorizationStatus: { .fullAccess }).snapshot().events.count, 0)
        let selected = CalendarMeetingProvider(eventStore: store, calendarSelection: .selected([calendar.calendarIdentifier]), authorizationStatus: { .fullAccess })
        XCTAssertEqual(selected.snapshot().events.count, 1)
        let historical = Date(timeIntervalSince1970: 1000)
        _ = selected.snapshot(on: historical)
        XCTAssertEqual(store.queryStart, Calendar.current.startOfDay(for: historical))
    }
}

private final class FixtureEventStore: EKEventStore {
    var fixtureCalendars: [EKCalendar] = []
    var fixtureEvents: [EKEvent] = []
    var queryStart: Date?
    override func predicateForEvents(withStart startDate: Date, end endDate: Date, calendars: [EKCalendar]?) -> NSPredicate {
        queryStart = startDate
        return NSPredicate(value: true)
    }
    override func calendars(for entityType: EKEntityType) -> [EKCalendar] { fixtureCalendars }
    override func events(matching predicate: NSPredicate) -> [EKEvent] { fixtureEvents }
}
