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
    private let calendarSelection: CalendarSourceSelection

    init(
        eventStore: EKEventStore = EKEventStore(),
        calendar: Calendar = .current,
        calendarSelection: CalendarSourceSelection = .all,
        now: @escaping () -> Date = Date.init
    ) {
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

    func meetingsToday() -> [DailyBriefMeeting] {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess:
            break
        case .writeOnly, .denied, .restricted, .notDetermined:
            return []
        @unknown default:
            return []
        }

        let start = calendar.startOfDay(for: now())
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let selectedCalendars: [EKCalendar]?
        switch calendarSelection.mode {
        case .all:
            selectedCalendars = nil
        case .selected:
            let matches = eventStore.calendars(for: .event).filter {
                calendarSelection.includes(calendarIdentifier: $0.calendarIdentifier)
            }
            guard !matches.isEmpty else { return [] }
            selectedCalendars = matches
        case .none:
            return []
        }
        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: selectedCalendars
        )
        let events = eventStore.events(matching: predicate).map { event in
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return DailyBriefCalendarEvent(
                calendarIdentifier: event.calendar.calendarIdentifier,
                title: title.isEmpty ? "Untitled meeting" : title,
                time: event.isAllDay ? nil : timeFormatter.string(from: event.startDate)
            )
        }
        return CalendarMeetingSelector(selection: calendarSelection).meetings(from: events)
    }
}
