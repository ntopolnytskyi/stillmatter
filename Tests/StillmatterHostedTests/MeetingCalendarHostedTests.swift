import AppKit
import EventKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingCalendarHostedTests: XCTestCase {
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
        var response = NSApplication.ModalResponse.alertFirstButtonReturn
        var resetTitle = false
        var expire = false
        let view = MeetingManagementView(readModelProvider: { provided }, mutationExecutorProvider: { executor }, playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in }, presentConfirmationAlert: { alert in
            let stack = alert.accessoryView as! NSStackView
            let picker = stack.arrangedSubviews[0] as! NSPopUpButton
            XCTAssertEqual(picker.numberOfItems, events.count)
            XCTAssertEqual(alert.buttons[0].isEnabled, !events.isEmpty)
            XCTAssertTrue(alert.informativeText.contains("External links may break"))
            (stack.arrangedSubviews[1] as! NSButton).state = resetTitle ? .on : .off
            if expire { provided = other }
            return response
        }, calendarSnapshot: { CalendarMeetingSnapshot(events: events, status: "Test calendar context") })
        defer { view.refresh(isVisible: false); read.stop(); other.stop() }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail != nil && view.calendarButton.isEnabled }, evaluatedWith: nil)], timeout: 10)
        func waitForEvent(_ expected: CalendarMeeting?) async {
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail?.calendarContext?.event == expected }, evaluatedWith: nil)], timeout: 10)
        }
        view.editCalendar()
        await waitForEvent(event)
        XCTAssertEqual(view.displayedDetail?.row.title, "Manual title")
        resetTitle = true
        view.editCalendar()
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail?.row.title == event.title }, evaluatedWith: nil)], timeout: 10)
        XCTAssertTrue(view.calendarStatus.stringValue.contains("Scheduled:"))
        XCTAssertEqual(try service.detail(for: "calendar-fixture").row.startedAt, ISO8601DateFormatter().date(from: "2026-11-15T10:03:00Z"))
        let original = try service.detail(for: "calendar-fixture").doorwayText
        response = .alertThirdButtonReturn
        view.editCalendar()
        XCTAssertEqual(try service.detail(for: "calendar-fixture").doorwayText, original)
        expire = true; response = .alertSecondButtonReturn
        view.editCalendar()
        XCTAssertEqual(try service.detail(for: "calendar-fixture").doorwayText, original)
        expire = false; provided = read; events = []
        view.editCalendar()
        await waitForEvent(nil)
        XCTAssertEqual(view.displayedDetail?.row.title, "Manual title", "Explicit reset on unlink restores original fallback")
        XCTAssertEqual(view.calendarStatus.stringValue, "Unlinked")
        view.calendarButton.isEnabled = false
        view.editCalendar()
        XCTAssertEqual(try service.detail(for: "calendar-fixture").row.title, "Manual title")
    }

    @available(macOS 14.0, *)
    func testProviderHonorsDisabledDeniedAndPermittedSourcesWithoutReadingRealCalendars() {
        let store = FixtureEventStore()
        let calendar = EKCalendar(for: .event, eventStore: store)
        let event = EKEvent(eventStore: store)
        event.calendar = calendar; event.title = "  План / 計画  "
        event.startDate = Date(timeIntervalSince1970: 1000); event.endDate = Date(timeIntervalSince1970: 2000)
        event.url = URL(string: "https://example.invalid/meeting")
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
    }
}

private final class FixtureEventStore: EKEventStore {
    var fixtureCalendars: [EKCalendar] = []
    var fixtureEvents: [EKEvent] = []
    override func calendars(for entityType: EKEntityType) -> [EKCalendar] { fixtureCalendars }
    override func events(matching predicate: NSPredicate) -> [EKEvent] { fixtureEvents }
}
