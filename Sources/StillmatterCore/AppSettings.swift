import Foundation

public enum Weekday: Int, CaseIterable, Codable, Equatable {
    case sunday = 1
    case monday = 2
    case tuesday = 3
    case wednesday = 4
    case thursday = 5
    case friday = 6
    case saturday = 7

    public var displayName: String {
        switch self {
        case .sunday: return "Sunday"
        case .monday: return "Monday"
        case .tuesday: return "Tuesday"
        case .wednesday: return "Wednesday"
        case .thursday: return "Thursday"
        case .friday: return "Friday"
        case .saturday: return "Saturday"
        }
    }
}

public struct TimeOfDay: Codable, Equatable {
    public var hour: Int
    public var minute: Int

    public init(hour: Int, minute: Int) {
        precondition((0...23).contains(hour), "hour must be 0...23")
        precondition((0...59).contains(minute), "minute must be 0...59")
        self.hour = hour
        self.minute = minute
    }

    public var displayValue: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public static func parse(_ value: String) -> TimeOfDay? {
        let parts = value.split(separator: ":")
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0...23).contains(hour),
              (0...59).contains(minute) else {
            return nil
        }
        return TimeOfDay(hour: hour, minute: minute)
    }
}

public struct WorkingHoursSettings: Codable, Equatable {
    public var weekdays: [Weekday]
    public var startTime: TimeOfDay
    public var endTime: TimeOfDay
    public var endOfWeekDay: Weekday
    public var endOfWeekTime: TimeOfDay

    public init(
        weekdays: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday],
        startTime: TimeOfDay = TimeOfDay(hour: 9, minute: 0),
        endTime: TimeOfDay = TimeOfDay(hour: 19, minute: 0),
        endOfWeekDay: Weekday = .friday,
        endOfWeekTime: TimeOfDay = TimeOfDay(hour: 19, minute: 0)
    ) {
        self.weekdays = weekdays
        self.startTime = startTime
        self.endTime = endTime
        self.endOfWeekDay = endOfWeekDay
        self.endOfWeekTime = endOfWeekTime
    }
}

public struct CalendarSourceSelection: Codable, Equatable {
    public enum Mode: String, Codable {
        case all
        case selected
        case none
    }

    public let mode: Mode
    public let selectedCalendarIdentifiers: Set<String>

    public static let all = CalendarSourceSelection(mode: .all, identifiers: [])
    public static let none = CalendarSourceSelection(mode: .none, identifiers: [])

    public static func selected(_ identifiers: [String]) -> CalendarSourceSelection {
        let normalized = Set(identifiers)
        return normalized.isEmpty
            ? .none
            : CalendarSourceSelection(mode: .selected, identifiers: normalized)
    }

    public func includes(calendarIdentifier: String) -> Bool {
        switch mode {
        case .all: return true
        case .selected: return selectedCalendarIdentifiers.contains(calendarIdentifier)
        case .none: return false
        }
    }

    private init(mode: Mode, identifiers: Set<String>) {
        self.mode = mode
        self.selectedCalendarIdentifiers = identifiers
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case selectedCalendarIdentifiers
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        let identifiers = Set(try container.decodeIfPresent([String].self, forKey: .selectedCalendarIdentifiers) ?? [])
        switch mode {
        case .all: self = .all
        case .none: self = .none
        case .selected: self = identifiers.isEmpty ? .none : CalendarSourceSelection(mode: .selected, identifiers: identifiers)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(selectedCalendarIdentifiers.sorted(), forKey: .selectedCalendarIdentifiers)
    }
}

public struct AppSettings: Codable, Equatable {
    public var stillmatterRootURL: URL?
    public var recordingMediaURL: URL?
    public var launchAtLoginEnabled: Bool
    public var calendarSourceSelection: CalendarSourceSelection
    public var workingHours: WorkingHoursSettings
    public var searchExcludedPatterns: [String]
    public var transcriptionModelChoice: TranscriptionModelChoice
    public var teamsRecordingMode: TeamsRecordingMode

    public init(
        stillmatterRootURL: URL? = nil,
        recordingMediaURL: URL? = nil,
        launchAtLoginEnabled: Bool = false,
        calendarSourceSelection: CalendarSourceSelection = .all,
        workingHours: WorkingHoursSettings = WorkingHoursSettings(),
        searchExcludedPatterns: [String] = [],
        transcriptionModelChoice: TranscriptionModelChoice = .recommended,
        teamsRecordingMode: TeamsRecordingMode = .ask
    ) {
        self.stillmatterRootURL = stillmatterRootURL
        self.recordingMediaURL = recordingMediaURL
        self.launchAtLoginEnabled = launchAtLoginEnabled
        self.calendarSourceSelection = calendarSourceSelection
        self.workingHours = workingHours
        self.searchExcludedPatterns = searchExcludedPatterns
        self.transcriptionModelChoice = transcriptionModelChoice
        self.teamsRecordingMode = teamsRecordingMode
    }

    private enum CodingKeys: String, CodingKey {
        case stillmatterRootURL
        case recordingMediaURL
        case launchAtLoginEnabled
        case calendarSourceSelection
        case selectedCalendarIdentifiers
        case workingHours
        case searchExcludedPatterns
        case transcriptionModelChoice
        case teamsRecordingMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stillmatterRootURL = try container.decodeIfPresent(URL.self, forKey: .stillmatterRootURL)
        recordingMediaURL = try container.decodeIfPresent(URL.self, forKey: .recordingMediaURL)
        launchAtLoginEnabled = try container.decode(Bool.self, forKey: .launchAtLoginEnabled)
        if let selection = try container.decodeIfPresent(CalendarSourceSelection.self, forKey: .calendarSourceSelection) {
            calendarSourceSelection = selection
        } else if let legacyIdentifiers = try container.decodeIfPresent([String].self, forKey: .selectedCalendarIdentifiers) {
            calendarSourceSelection = legacyIdentifiers.isEmpty ? .all : .selected(legacyIdentifiers)
        } else {
            calendarSourceSelection = .all
        }
        workingHours = try container.decode(WorkingHoursSettings.self, forKey: .workingHours)
        searchExcludedPatterns = try container.decodeIfPresent([String].self, forKey: .searchExcludedPatterns) ?? []
        let storedTranscriptionModel = try container.decodeIfPresent(String.self, forKey: .transcriptionModelChoice)
        transcriptionModelChoice = storedTranscriptionModel.flatMap(TranscriptionModelChoice.init(rawValue:)) ?? .recommended
        let storedRecordingMode = try container.decodeIfPresent(String.self, forKey: .teamsRecordingMode)
        teamsRecordingMode = storedRecordingMode.flatMap(TeamsRecordingMode.init(rawValue:)) ?? .ask
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(stillmatterRootURL, forKey: .stillmatterRootURL)
        try container.encodeIfPresent(recordingMediaURL, forKey: .recordingMediaURL)
        try container.encode(launchAtLoginEnabled, forKey: .launchAtLoginEnabled)
        try container.encode(calendarSourceSelection, forKey: .calendarSourceSelection)
        try container.encode(workingHours, forKey: .workingHours)
        try container.encode(searchExcludedPatterns, forKey: .searchExcludedPatterns)
        try container.encode(transcriptionModelChoice, forKey: .transcriptionModelChoice)
        try container.encode(teamsRecordingMode, forKey: .teamsRecordingMode)
    }
}
