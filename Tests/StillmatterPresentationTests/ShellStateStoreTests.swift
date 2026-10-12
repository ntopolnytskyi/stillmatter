import XCTest
import StillmatterCore
@testable import StillmatterPresentation

final class ShellStateStoreTests: XCTestCase {
    func testStatusEventsNeverPublishNavigationOrSearch() {
        let store = ShellStateStore()
        var events: [ShellChange] = []
        let observation = store.observe([.navigation, .search, .recordingStatus, .jobStatus, .teamsStatus], initial: .navigation) { events.append($0) }
        XCTAssertEqual(events, [.navigation])
        store.publish(.recordingStatus)
        store.publish(.jobStatus)
        store.publish(.teamsStatus)
        XCTAssertEqual(events, [.navigation, .recordingStatus, .jobStatus, .teamsStatus])
        XCTAssertEqual(store.state.selectedTab, .today)
        XCTAssertEqual(store.state.searchText, "")
        observation.cancel()
    }

    func testRepeatedObservationDisposalDoesNotGrowCallbackCount() {
        let store = ShellStateStore()
        var notifications = 0
        for _ in 0..<100 {
            let observation = store.observe([.jobStatus], initial: .jobStatus) { _ in notifications += 1 }
            XCTAssertEqual(store.observerCount, 1)
            observation.cancel()
            XCTAssertEqual(store.observerCount, 0)
        }
        store.publish(.jobStatus)
        XCTAssertEqual(notifications, 100)
    }

    func testNavigationAndSearchPublishOnlyWhenValuesChange() {
        let store = ShellStateStore()
        var events: [ShellChange] = []
        let observation = store.observe([.navigation, .search], initial: .navigation) { events.append($0) }
        store.state.select(.today)
        store.state.searchText = "draft"
        store.state.searchText = "draft"
        store.state.select(.meetings)
        XCTAssertEqual(events, [.navigation, .search, .navigation])
        observation.cancel()
    }

    func testExternalPathsInvalidateOnlyOwningFeature() {
        XCTAssertEqual(ShellChange.workspaceChanges(for: "Todos/todo.md"), [.tasks])
        XCTAssertEqual(ShellChange.workspaceChanges(for: "Meetings/ready/meeting.md"), [])
        XCTAssertEqual(ShellChange.workspaceChanges(for: "Todos-old/todo.md"), [])
    }

    func testScopedSubscribersDoNotReceiveUnrelatedEvents() {
        let store = ShellStateStore()
        var status = 0
        var navigation = 0
        let statusToken = store.observe([.recordingStatus, .jobStatus]) { _ in status += 1 }
        let navigationToken = store.observe([.navigation, .search], initial: .navigation) { _ in navigation += 1 }
        store.publish(.recordingStatus)
        store.publish(.tasks)
        store.state.searchText = "A"
        XCTAssertEqual(status, 1)
        XCTAssertEqual(navigation, 2)
        statusToken.cancel()
        navigationToken.cancel()
    }
}
