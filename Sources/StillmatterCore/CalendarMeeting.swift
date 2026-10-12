import Foundation

public struct CalendarMeeting: Equatable {
    public let title: String
    public let time: String?
    public let eventIdentifier: String?
    public let calendarIdentifier: String?
    public let eventStart: Date?

    public init(title: String, time: String? = nil,
                eventIdentifier: String? = nil, calendarIdentifier: String? = nil, eventStart: Date? = nil) {
        self.title = title
        self.time = time
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.eventStart = eventStart
    }
}

public struct CalendarMeetingEvent: Equatable {
    public let calendarIdentifier: String
    public let title: String
    public let time: String?
    public let eventIdentifier: String?
    public let eventStart: Date?

    public init(calendarIdentifier: String, title: String, time: String? = nil,
                eventIdentifier: String? = nil, eventStart: Date? = nil) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.time = time
        self.eventIdentifier = eventIdentifier
        self.eventStart = eventStart
    }
}

public struct CalendarMeetingSelector {
    private let selection: CalendarSourceSelection

    public init(selection: CalendarSourceSelection) {
        self.selection = selection
    }

    public func meetings(from events: [CalendarMeetingEvent]) -> [CalendarMeeting] {
        events.compactMap { event in
            guard selection.includes(calendarIdentifier: event.calendarIdentifier) else { return nil }
            return CalendarMeeting(title: event.title, time: event.time,
                                     eventIdentifier: event.eventIdentifier, calendarIdentifier: event.calendarIdentifier,
                                     eventStart: event.eventStart)
        }
    }
}
