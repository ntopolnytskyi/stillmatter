import XCTest
@testable import StillmatterCore

final class TranscriptReadingPreferenceTests: XCTestCase {
    func testLegacySettingsDefaultAndSelectedViewSurviveRestart() throws {
        let legacy = Data(#"{"launchAtLoginEnabled":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(settings.transcriptReadingView, .timestamps)
        var selected = settings
        selected.transcriptReadingView = .clearText
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(selected))
        XCTAssertEqual(restored.transcriptReadingView, .clearText)
    }
}
