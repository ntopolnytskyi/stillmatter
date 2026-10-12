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
              "launchAtLoginEnabled": false
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
              "selectedCalendarIdentifiers": ["work", "personal"]
            }
            """.utf8)

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.calendarSourceSelection, .selected(["work", "personal"]))
    }


}
