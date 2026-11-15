import Foundation

public struct CalendarMeetingSnapshot {
    public let events: [CalendarMeeting]
    public let status: String

    public init(events: [CalendarMeeting], status: String) {
        self.events = events
        self.status = status
    }
}
