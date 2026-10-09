import XCTest
@testable import StillmatterCore

final class AppLifecyclePolicyTests: XCTestCase {
    func testClosingLastWindowDoesNotTerminateApplication() {
        let policy = AppLifecyclePolicy()

        XCTAssertFalse(policy.shouldTerminateAfterLastWindowClosed)
    }

    func testMainWindowCloseButtonHidesInsteadOfClosesWindow() {
        let policy = AppLifecyclePolicy()

        XCTAssertFalse(policy.shouldCloseMainWindow)
    }

    func testApplicationTerminatesOnlyAfterExplicitQuitRequest() {
        let policy = AppLifecyclePolicy()

        XCTAssertFalse(policy.shouldTerminate(quitRequested: false))
        XCTAssertTrue(policy.shouldTerminate(quitRequested: true))
    }
}
