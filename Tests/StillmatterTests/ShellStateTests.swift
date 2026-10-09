import XCTest
@testable import StillmatterCore

final class ShellStateTests: XCTestCase {
    func testDefaultLandingSurfaceIsToday() {
        let state = ShellState()
        XCTAssertEqual(state.selectedTab, .today)
        XCTAssertEqual(state.searchText, "")
    }

    func testSelectingMeetingsPreservesSearchDraft() {
        var state = ShellState(searchText: "draft")
        state.select(.meetings)
        XCTAssertEqual(state.selectedTab, .meetings)
        XCTAssertEqual(state.searchText, "draft")
    }

    func testMvpSidebarTabsArePresentInOrder() {
        XCTAssertEqual(ShellTab.allCases, [
            .today, .recording, .meetings, .tasks, .projectsActivities, .reports, .askAI, .settings
        ])
    }
}
