import XCTest
@testable import StillmatterCore

final class AdaptiveShellLayoutTests: XCTestCase {
    func testCollapseOrderAcrossValidationWidths() {
        let spacious = layout(width: 1440)
        XCTAssertTrue(spacious.showsInspector)
        XCTAssertTrue(spacious.showsSidebar)
        XCTAssertEqual(spacious.detailMode, .listAndDetail)

        let reference = layout(width: 1200)
        XCTAssertFalse(reference.showsInspector)
        XCTAssertTrue(reference.showsSidebar)
        XCTAssertEqual(reference.detailMode, .listAndDetail)

        let minimum = layout(width: 720)
        XCTAssertFalse(minimum.showsInspector)
        XCTAssertFalse(minimum.showsSidebar)
        XCTAssertEqual(minimum.detailMode, .listOnly)
        XCTAssertTrue(minimum.isNarrowNavigation)
    }

    func testSimpleCanvasKeepsFixedSidebarWhenDetailRemainsUseful() {
        let layout = AdaptiveShellLayout(
            availableWidth: 720,
            hasContentList: false,
            hasInspector: false,
            prefersSidebar: true,
            prefersInspector: false
        )

        XCTAssertTrue(layout.showsSidebar)
        XCTAssertEqual(layout.detailMode, .detailOnly)
    }

    func testPreferencesAreRespectedWithoutChangingCollapseRules() {
        let layout = AdaptiveShellLayout(
            availableWidth: 1440,
            hasContentList: true,
            hasInspector: true,
            prefersSidebar: false,
            prefersInspector: false
        )

        XCTAssertFalse(layout.showsSidebar)
        XCTAssertFalse(layout.showsInspector)
        XCTAssertEqual(layout.detailMode, .listAndDetail)
    }

    private func layout(width: CGFloat) -> AdaptiveShellLayout {
        AdaptiveShellLayout(
            availableWidth: width,
            hasContentList: true,
            hasInspector: true,
            prefersSidebar: true,
            prefersInspector: true
        )
    }
}
