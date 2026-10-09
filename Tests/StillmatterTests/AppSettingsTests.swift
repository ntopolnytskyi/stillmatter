import XCTest
@testable import StillmatterCore

final class AppSettingsTests: XCTestCase {
    func testDefaultSettingsMatchMvpWorkingTimeAndPreferences() {
        let settings = AppSettings()

        XCTAssertNil(settings.stillmatterRootURL)
        XCTAssertNil(settings.recordingMediaURL)
        XCTAssertFalse(settings.launchAtLoginEnabled)
        XCTAssertEqual(settings.calendarSourceSelection, .all)
        XCTAssertTrue(settings.calendarSourceSelection.includes(calendarIdentifier: "any-calendar"))
        XCTAssertEqual(settings.searchExcludedPatterns, [])
        XCTAssertEqual(settings.transcriptionModelChoice, .recommended)
        XCTAssertEqual(settings.teamsRecordingMode, .ask)
        XCTAssertEqual(settings.workingHours.weekdays, [.monday, .tuesday, .wednesday, .thursday, .friday])
        XCTAssertEqual(settings.workingHours.startTime, TimeOfDay(hour: 9, minute: 0))
        XCTAssertEqual(settings.workingHours.endTime, TimeOfDay(hour: 19, minute: 0))
        XCTAssertEqual(settings.workingHours.endOfWeekDay, .friday)
        XCTAssertEqual(settings.workingHours.endOfWeekTime, TimeOfDay(hour: 19, minute: 0))
    }

    func testSettingsPersistAcrossStoreInstances() {
        let suiteName = "StillmatterTests.SettingsStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let storageKey = "settings"
        let firstStore = SettingsStore(userDefaults: defaults, storageKey: storageKey)
        firstStore.settings = AppSettings(
            stillmatterRootURL: URL(fileURLWithPath: "/Users/example/Stillmatter"),
            recordingMediaURL: URL(fileURLWithPath: "/Users/example/Stillmatter Media"),
            launchAtLoginEnabled: true,
            calendarSourceSelection: .selected(["work", "personal"]),
            workingHours: WorkingHoursSettings(
                startTime: TimeOfDay(hour: 8, minute: 30),
                endTime: TimeOfDay(hour: 18, minute: 15),
                endOfWeekDay: .thursday,
                endOfWeekTime: TimeOfDay(hour: 16, minute: 45)
            ),
            searchExcludedPatterns: ["Private/**", "Vendors/**"],
            transcriptionModelChoice: .full,
            teamsRecordingMode: .automatic
        )

        let reloadedStore = SettingsStore(userDefaults: defaults, storageKey: storageKey)

        XCTAssertEqual(reloadedStore.settings, firstStore.settings)
    }

    func testCalendarSelectionFiltersToSelectedCalendars() {
        let selection = CalendarSourceSelection.selected(["work", "personal"])

        XCTAssertTrue(selection.includes(calendarIdentifier: "work"))
        XCTAssertTrue(selection.includes(calendarIdentifier: "personal"))
        XCTAssertFalse(selection.includes(calendarIdentifier: "holidays"))
        XCTAssertFalse(CalendarSourceSelection.none.includes(calendarIdentifier: "work"))
        XCTAssertTrue(CalendarSourceSelection.all.includes(calendarIdentifier: "holidays"))
    }

    func testOlderStoredSettingsDecodeWithAllCalendarsSelected() throws {
        let data = Data("""
            {
              "launchAtLoginEnabled": false,
              "workingHours": {
                "weekdays": [2, 3, 4, 5, 6],
                "startTime": {"hour": 9, "minute": 0},
                "endTime": {"hour": 19, "minute": 0},
                "endOfWeekDay": 6,
                "endOfWeekTime": {"hour": 19, "minute": 0}
              }
            }
            """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.calendarSourceSelection, .all)
        XCTAssertTrue(settings.calendarSourceSelection.includes(calendarIdentifier: "work"))
        XCTAssertEqual(settings.transcriptionModelChoice, .recommended)
        XCTAssertEqual(settings.teamsRecordingMode, .ask)
    }

    func testRetiredTranscriptionModelChoiceMigratesToRecommended() throws {
        let encoded = try JSONEncoder().encode(AppSettings())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["transcriptionModelChoice"] = "large-v3-v20240930-626MB"

        let settings = try JSONDecoder().decode(
            AppSettings.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(settings.transcriptionModelChoice, .recommended)
    }

    func testLegacySelectedCalendarIdentifiersMigrateToExplicitSelection() throws {
        let data = Data("""
            {
              "launchAtLoginEnabled": false,
              "selectedCalendarIdentifiers": ["work", "personal"],
              "workingHours": {
                "weekdays": [2, 3, 4, 5, 6],
                "startTime": {"hour": 9, "minute": 0},
                "endTime": {"hour": 19, "minute": 0},
                "endOfWeekDay": 6,
                "endOfWeekTime": {"hour": 19, "minute": 0}
              }
            }
            """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.calendarSourceSelection, .selected(["work", "personal"]))
    }

    func testTimeOfDayParsesAndRejectsInvalidValues() {
        XCTAssertEqual(TimeOfDay.parse("09:00"), TimeOfDay(hour: 9, minute: 0))
        XCTAssertEqual(TimeOfDay.parse("19:30"), TimeOfDay(hour: 19, minute: 30))
        XCTAssertNil(TimeOfDay.parse("24:00"))
        XCTAssertNil(TimeOfDay.parse("12:60"))
        XCTAssertNil(TimeOfDay.parse("nope"))
    }
}
