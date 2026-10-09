import XCTest
@testable import StillmatterCore

final class DiagnosticsTests: XCTestCase {
    func testOnlyGrantedDiagnosticsAreAvailable() {
        XCTAssertTrue(DiagnosticStatus.granted.isAvailable)
        XCTAssertFalse(DiagnosticStatus.missing.isAvailable)
        XCTAssertFalse(DiagnosticStatus.unavailable.isAvailable)
        XCTAssertFalse(DiagnosticStatus.notConfigured.isAvailable)
        XCTAssertFalse(DiagnosticStatus.unknown.isAvailable)
    }

    func testMissingFeatureSummaryNamesOnlyAffectedUnavailableFeatures() {
        let snapshot = DiagnosticsSnapshot(
            permissions: [
                DiagnosticItem(id: "microphone", title: "Microphone", status: .missing, explanation: "", affectedFeatures: ["meeting recording"]),
                DiagnosticItem(id: "notifications", title: "Notifications", status: .granted, explanation: "", affectedFeatures: ["reminders"])
            ],
            components: [
                DiagnosticItem(id: "pi", title: "Pi", status: .unavailable, explanation: "", affectedFeatures: ["AI assistance"])
            ]
        )

        XCTAssertEqual(snapshot.missingFeatureSummary, "Unavailable until configured: AI assistance, meeting recording.")
    }
}
