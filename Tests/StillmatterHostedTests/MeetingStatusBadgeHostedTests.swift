import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingStatusBadgeHostedTests: XCTestCase {
    @MainActor
    func testArchivedMeetingUsesOneLineBadgeWithoutProgressBarOrDuplicateArchiveMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("badge-hosted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
                                   appSupportRootURL: root.appendingPathComponent("support"))
        _ = try vault.writeMarkdown(Data("---\ntitle: Archived fixture\ncapture_session_id: fixture\n---\n# Archived fixture\n".utf8),
                                    relativePath: "Meetings/fixture/meeting.md", expectedVersion: nil)
        _ = try vault.writeMarkdown(Data("{\"archived\":true}".utf8),
                                    relativePath: "Meetings/fixture/archive.json", expectedVersion: nil)
        let service = MeetingManagementService(vault: vault)
        let model = MeetingReadModel(workspaceID: "badge", sourceFactory: {
            MeetingManagementReadSource(serviceProvider: { service })
        })
        let view = MeetingManagementView(readModelProvider: { model }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        defer { view.refresh(isVisible: false); model.stop() }
        view.archiveFilter.selectItem(at: 1)
        view.filtersChanged(nil)
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in
            view.displayedDetail?.row.isArchived == true
        }, evaluatedWith: nil)], timeout: 5)
        XCTAssertFalse(view.statusBadge.isHidden)
        XCTAssertEqual(view.processingStatus.accessibilityLabel(), "Archived")
        XCTAssertEqual(view.processingStatus.maximumNumberOfLines, 1)
        XCTAssertTrue(view.processingStatus.usesSingleLineMode)
        XCTAssertEqual(view.statusBadge.subviews.count, 1)
        XCTAssertFalse(view.overview.stringValue.contains("Archived"))
    }
}
