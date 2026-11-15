import Foundation

public struct CalendarMeeting: Codable, Equatable {
    public let title: String
    public let time: String?
    public let eventIdentifier: String?
    public let calendarIdentifier: String?
    public let eventStart: Date?
    public let eventEnd: Date?
    public let meetingLink: String?

    public init(title: String, time: String? = nil,
                eventIdentifier: String? = nil, calendarIdentifier: String? = nil, eventStart: Date? = nil, eventEnd: Date? = nil, meetingLink: String? = nil) {
        self.title = title
        self.time = time
        self.eventIdentifier = eventIdentifier
        self.calendarIdentifier = calendarIdentifier
        self.eventStart = eventStart
        self.eventEnd = eventEnd
        self.meetingLink = meetingLink
    }
}

public struct CalendarMeetingEvent: Equatable {
    public let calendarIdentifier: String
    public let title: String
    public let time: String?
    public let eventIdentifier: String?
    public let eventStart: Date?
    public let eventEnd: Date?
    public let meetingLink: String?

    public init(calendarIdentifier: String, title: String, time: String? = nil,
                eventIdentifier: String? = nil, eventStart: Date? = nil, eventEnd: Date? = nil, meetingLink: String? = nil) {
        self.calendarIdentifier = calendarIdentifier
        self.title = title
        self.time = time
        self.eventIdentifier = eventIdentifier
        self.eventStart = eventStart
        self.eventEnd = eventEnd
        self.meetingLink = meetingLink
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
                                     eventStart: event.eventStart, eventEnd: event.eventEnd, meetingLink: event.meetingLink)
        }
    }
}

/// Half-open occurrence intervals; closest start wins, then stable occurrence identity.
public enum CalendarMeetingMatcher {
    public static func match(_ events: [CalendarMeeting], at actualStart: Date, meetingLink: String? = nil) -> CalendarMeeting? {
        events.filter {
            guard $0.eventIdentifier != nil, $0.calendarIdentifier != nil,
                  let start = $0.eventStart, let end = $0.eventEnd else { return false }
            return start <= actualStart && actualStart < end
        }.sorted { left, right in
            let leftLink = meetingLink != nil && left.meetingLink == meetingLink
            let rightLink = meetingLink != nil && right.meetingLink == meetingLink
            if leftLink != rightLink { return leftLink }
            let leftDistance = abs(left.eventStart!.timeIntervalSince(actualStart))
            let rightDistance = abs(right.eventStart!.timeIntervalSince(actualStart))
            if leftDistance != rightDistance { return leftDistance < rightDistance }
            return [left.calendarIdentifier!, left.eventIdentifier!, String(left.eventStart!.timeIntervalSince1970), left.title]
                .lexicographicallyPrecedes([right.calendarIdentifier!, right.eventIdentifier!, String(right.eventStart!.timeIntervalSince1970), right.title])
        }.first
    }
}
