import Foundation

/// A snapshot of the selected occurrence, independent of actual capture timing.
public struct MeetingCalendarContext: Codable, Equatable {
    public var event: CalendarMeeting?
    public var fallbackTitle: String
    public var appliedTitle: String
    public var manualTitle: Bool
    public var status: String

    public init(event: CalendarMeeting?, fallbackTitle: String, appliedTitle: String, manualTitle: Bool, status: String) {
        self.event = event
        self.fallbackTitle = fallbackTitle
        self.appliedTitle = appliedTitle
        self.manualTitle = manualTitle
        self.status = status
    }

    public static func read(from markdown: String) throws -> Self? {
        guard let line = markdown.components(separatedBy: "\n").first(where: { $0.hasPrefix("calendar_context: ") }) else { return nil }
        guard let data = Data(base64Encoded: String(line.dropFirst("calendar_context: ".count))) else {
            throw MeetingManagementError.malformed("Invalid calendar context")
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public func writing(to markdown: String) throws -> String {
        let line = "calendar_context: " + (try JSONEncoder().encode(self)).base64EncodedString()
        if let range = markdown.range(of: #"(?m)^calendar_context: .*$"#, options: .regularExpression) {
            return markdown.replacingCharacters(in: range, with: line)
        }
        guard markdown.hasPrefix("---\n") else { throw MeetingManagementError.malformed("Meeting metadata missing") }
        return "---\n" + line + "\n" + markdown.dropFirst(4)
    }

    // Keep Markdown structurally valid while the encoded context retains the verbatim title.
    static func titleLine(_ title: String) -> String {
        title.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}

extension MeetingBrowserDetail {
    /// Shared preview/commit policy keeps rename warnings aligned with the canonical mutation.
    public func calendarChange(event: CalendarMeeting?, resetTitle: Bool) throws -> MeetingCalendarContext {
        var context = try MeetingCalendarContext.read(from: doorwayText) ?? MeetingCalendarContext(
            event: nil, fallbackTitle: row.title, appliedTitle: row.title,
            manualTitle: !row.title.hasPrefix("Untitled"), status: "No linked event")
        context.manualTitle = context.manualTitle || row.title != context.appliedTitle
        if resetTitle { context.manualTitle = false }
        context.event = event
        context.status = event == nil ? "Unlinked" : "Linked calendar event"
        context.appliedTitle = context.manualTitle ? row.title : (event?.title ?? context.fallbackTitle)
        return context
    }

    public var calendarContext: MeetingCalendarContext? { try? MeetingCalendarContext.read(from: doorwayText) }
}
