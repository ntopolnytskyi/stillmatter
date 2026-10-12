import XCTest
@testable import StillmatterCore

final class CalendarMeetingTests: XCTestCase {
    func testSelectionIncludesOnlyConfiguredCalendarSources() {
        let events = [
            CalendarMeetingEvent(calendarIdentifier: "work", title: "Work planning", time: "10:00"),
            CalendarMeetingEvent(calendarIdentifier: "personal", title: "Dentist", time: "15:00")
        ]
        XCTAssertEqual(CalendarMeetingSelector(selection: .selected(["work"])).meetings(from: events).map(\.title), ["Work planning"])
        XCTAssertEqual(CalendarMeetingSelector(selection: .all).meetings(from: events).map(\.title), ["Work planning", "Dentist"])
        XCTAssertTrue(CalendarMeetingSelector(selection: .selected(["missing"])).meetings(from: events).isEmpty)
        XCTAssertTrue(CalendarMeetingSelector(selection: .none).meetings(from: events).isEmpty)
    }
}
