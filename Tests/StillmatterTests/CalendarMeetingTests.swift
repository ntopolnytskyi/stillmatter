import XCTest
@testable import StillmatterCore

final class CalendarMeetingTests: XCTestCase {
    func testOverlappingEventSelectionIsDeterministicAndReusableWithExactTitle() {
        let start = Date(timeIntervalSince1970: 1000)
        let first = CalendarMeeting(title: "  План / 計画  ", eventIdentifier: "a", calendarIdentifier: "work",
                                    eventStart: start, eventEnd: start.addingTimeInterval(600))
        let second = CalendarMeeting(title: "Other", eventIdentifier: "b", calendarIdentifier: "work",
                                     eventStart: start, eventEnd: start.addingTimeInterval(600))
        for events in [[first, second], [second, first]] {
            XCTAssertEqual(CalendarMeetingMatcher.match(events, at: start.addingTimeInterval(10)), first)
            XCTAssertEqual(CalendarMeetingMatcher.match(events, at: start.addingTimeInterval(20)), first)
            XCTAssertNil(CalendarMeetingMatcher.match(events, at: start.addingTimeInterval(600)))
        }
    }

    func testMatchingRejectsIncompleteAndFutureEventsAndPrefersLinkThenNearestStart() {
        let now = Date(timeIntervalSince1970: 1000)
        func event(_ id: String, start: Double = 900, end: Double = 1200, link: String? = nil) -> CalendarMeeting {
            CalendarMeeting(title: id, eventIdentifier: id, calendarIdentifier: "work", eventStart: Date(timeIntervalSince1970: start), eventEnd: Date(timeIntervalSince1970: end), meetingLink: link)
        }
        let older = event("old", start: 800, link: "meeting-link")
        let recent = event("recent")
        let future = event("future", start: 1100)
        let incomplete = CalendarMeeting(title: "Incomplete", eventIdentifier: "id", calendarIdentifier: "work", eventStart: now)
        XCTAssertEqual(CalendarMeetingMatcher.match([older, recent, future, incomplete, CalendarMeeting(title: "No ID")], at: now), recent)
        XCTAssertEqual(CalendarMeetingMatcher.match([recent, older], at: now, meetingLink: "meeting-link"), older)
        XCTAssertEqual(CalendarMeetingMatcher.match([older, recent], at: now, meetingLink: "meeting-link"), older)
        XCTAssertNil(CalendarMeetingMatcher.match([future, incomplete], at: now))
    }

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
