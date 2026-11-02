import AppKit
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

final class MeetingsSearchShellControlsHostedTests: XCTestCase {
    @MainActor
    func testSharedStylePropagatesToMeetingListingDetailAndSearchActions() throws {
        let controls = GraphiteFocusControls(style: .init(font: .monospacedSystemFont(ofSize: 17, weight: .medium), controlSize: .small))
        let meeting = MeetingManagementView(readModelProvider: { nil }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in }, controls: controls)
        let search = SearchResultsView(onOpenResult: { _ in }, onOpenSettings: {}, onRetry: {}, onDismiss: {}, controls: controls)
        for control in [meeting.queryField, meeting.projectFilter, meeting.processingFilter, meeting.archiveFilter,
                        meeting.clearFiltersButton, meeting.advancedFiltersButton, meeting.reviewButton,
                        meeting.pageSelector, meeting.reprocessButton, meeting.renameButton] as [NSControl] {
            XCTAssertEqual(control.font, controls.style.font)
            XCTAssertEqual(control.controlSize, .small)
        }
        XCTAssertEqual(meeting.queueButtons.map(\.font), Array(repeating: controls.style.font, count: 3))
        search.render(query: "test", scope: "Meetings", type: "All types", state: .failed("Controlled error"))
        let retry: NSButton = try control("search-state-action", in: search)
        XCTAssertEqual(retry.font, controls.style.font)
        XCTAssertEqual(retry.controlSize, .small)
        XCTAssertEqual(search.renderedState, "failed")
    }

    @MainActor
    func testSearchStateActionsAndMeetingFiltersDoNotChangeWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-07-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meeting.md")
        try "# Synthetic Meeting\n".write(to: file, atomically: true, encoding: .utf8)
        var retries = 0
        var settings = 0
        var dismissals = 0
        let search = SearchResultsView(onOpenResult: { _ in }, onOpenSettings: { settings += 1 },
            onRetry: { retries += 1 }, onDismiss: { dismissals += 1 })
        search.render(query: "synthetic", scope: "Meetings", type: "All types", state: .failed("Controlled error"))
        try controlButton(in: search).performClick(nil)
        search.render(query: "synthetic", scope: "Meetings", type: "All types", state: .unavailable)
        try controlButton(in: search).performClick(nil)
        search.render(query: "", scope: "Meetings", type: "All types", state: .emptyQuery)
        try controlButton(in: search).performClick(nil)
        search.render(query: "nothing", scope: "Meetings", type: "All types", state: .noResults)
        XCTAssertEqual(search.renderedState, "no-results")
        XCTAssertEqual(retries, 1)
        XCTAssertEqual(settings, 1)
        XCTAssertEqual(dismissals, 1)
        let meeting = MeetingManagementView(readModelProvider: { nil }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        meeting.queryField.stringValue = "synthetic"
        meeting.clearFiltersButton.performClick(nil)
        XCTAssertEqual(meeting.queryField.stringValue, "")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Synthetic Meeting\n")
    }

    @MainActor
    private func controlButton(in view: NSView) throws -> NSButton {
        try control("search-state-action", in: view)
    }

    @MainActor
    private func control<T: NSView>(_ id: String, in view: NSView) throws -> T {
        if view.accessibilityIdentifier() == id, let found = view as? T { return found }
        for child in view.subviews { if let found: T = try? control(id, in: child) { return found } }
        throw NSError(domain: "MeetingsSearchShellControls", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing \(id)"])
    }
}
