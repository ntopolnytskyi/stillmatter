import EventKit
import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

final class CalendarMeetingProvider {
    private let eventStore: EKEventStore
    private let calendar: Calendar
    private let timeFormatter: DateFormatter
    private let now: () -> Date
    private let authorizationStatus: () -> EKAuthorizationStatus
    private let calendarSelection: CalendarSourceSelection

    init(
        eventStore: EKEventStore = EKEventStore(),
        calendar: Calendar = .current,
        calendarSelection: CalendarSourceSelection = .all,
        now: @escaping () -> Date = Date.init,
        authorizationStatus: @escaping () -> EKAuthorizationStatus = { EKEventStore.authorizationStatus(for: .event) }
    ) {
        self.authorizationStatus = authorizationStatus
        self.eventStore = eventStore
        self.calendar = calendar
        self.now = now
        self.calendarSelection = calendarSelection
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        self.timeFormatter = formatter
    }

    /// Explicit validation diagnostic: counts only the one user-selected source.
    /// Never queries events across all readable calendars or returns event titles.
    func selectedSourceDiagnostic() -> String {
        guard calendarSelection.mode == .selected,
              calendarSelection.selectedCalendarIdentifiers.count == 1 else {
            return "Select exactly one test calendar before running this check."
        }
        switch authorizationStatus() {
        case .authorized, .fullAccess: break
        case .writeOnly, .denied, .restricted, .notDetermined:
            return "Readable Calendar permission is unavailable."
        @unknown default: return "Calendar authorization is unknown."
        }
        let matches = eventStore.calendars(for: .event).filter {
            calendarSelection.includes(calendarIdentifier: $0.calendarIdentifier)
        }
        guard matches.count == 1 else {
            return "Selected calendar matches in EventKit: \(matches.count); no events queried."
        }
        let start = calendar.startOfDay(for: now())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            return "Could not calculate today's Calendar date range."
        }
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: matches)
        let count = eventStore.events(matching: predicate).count
        return "Selected calendar matches: 1; events today: \(count)."
    }

    func meetingsToday() -> [CalendarMeeting] { snapshot().events }

    func snapshot() -> CalendarMeetingSnapshot {
        if calendarSelection.mode == .none {
            return CalendarMeetingSnapshot(events: [], status: "Calendar sources disabled. Configure Calendar in Settings.")
        }
        switch authorizationStatus() {
        case .authorized, .fullAccess:
            break
        case .writeOnly, .denied, .restricted, .notDetermined:
            return CalendarMeetingSnapshot(events: [], status: "Calendar access unavailable. Enable read access in Settings > Privacy & Security > Calendars.")
        @unknown default:
            return CalendarMeetingSnapshot(events: [], status: "Calendar access unavailable. Enable read access in Settings > Privacy & Security > Calendars.")
        }

        let start = calendar.startOfDay(for: now())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return CalendarMeetingSnapshot(events: [], status: "Calendar access unavailable. Enable read access in Settings > Privacy & Security > Calendars.") }
        let selectedCalendars: [EKCalendar]?
        switch calendarSelection.mode {
        case .all:
            selectedCalendars = nil
        case .selected:
            let matches = eventStore.calendars(for: .event).filter {
                calendarSelection.includes(calendarIdentifier: $0.calendarIdentifier)
            }
            guard !matches.isEmpty else { return CalendarMeetingSnapshot(events: [], status: "Calendar access unavailable. Enable read access in Settings > Privacy & Security > Calendars.") }
            selectedCalendars = matches
        case .none:
            return CalendarMeetingSnapshot(events: [], status: "Calendar access unavailable. Enable read access in Settings > Privacy & Security > Calendars.")
        }
        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: selectedCalendars
        )
        let events = eventStore.events(matching: predicate).map { event in
            let title = event.title ?? ""
            return CalendarMeetingEvent(
                calendarIdentifier: event.calendar.calendarIdentifier,
                title: title,
                time: event.isAllDay ? nil : timeFormatter.string(from: event.startDate),
                eventIdentifier: event.eventIdentifier,
                eventStart: event.startDate, eventEnd: event.endDate, meetingLink: event.url?.absoluteString
            )
        }
        return CalendarMeetingSnapshot(events: CalendarMeetingSelector(selection: calendarSelection).meetings(from: events), status: "No overlapping calendar event. You can link an event later.")
    }
}
