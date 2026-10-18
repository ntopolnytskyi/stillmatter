import Foundation
import XCTest
@testable import StillmatterCore

final class MeetingTitleReviewTests: XCTestCase {
    func testAcceptWithSharedJobAndInboxDatabaseDoesNotLockItself() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
                                   appSupportRootURL: root.appendingPathComponent("support"))
        let databaseURL = root.appendingPathComponent("operations.sqlite")
        let inbox = try TasksInbox(databaseURL: databaseURL)
        let jobs = try JobStore(databaseURL: databaseURL, inbox: inbox)
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let old = "Untitled Meeting at 2026-01-02 09:10"
        _ = try vault.writeMarkdown(Data("---\ntype: meeting\ntitle: \(old)\n---\n# \(old)\n".utf8),
                                    relativePath: path, expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:shared", title: "Review", sourceRef: path)
        let moved = try MeetingTitleReviewService(vault: vault, inbox: inbox, jobStore: jobs)
            .accept(id: "meeting-title:shared", title: "Project Sync")
        XCTAssertEqual(moved, "Meetings/2026/01/02/09-10-project-sync/meeting.md")
        XCTAssertTrue(try inbox.items(category: .required).isEmpty)
        XCTAssertNil(try vault.versionOfMarkdown(relativePath: path))
    }

    func testAcceptWhileTranscriptionIsQueuedUpdatesTitleWithoutMovingJobSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
                                   appSupportRootURL: root.appendingPathComponent("support"))
        let databaseURL = root.appendingPathComponent("operations.sqlite")
        let inbox = try TasksInbox(databaseURL: databaseURL)
        let jobs = try JobStore(databaseURL: databaseURL, inbox: inbox)
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let old = "Untitled Meeting at 2026-01-02 09:10"
        _ = try vault.writeMarkdown(Data("---\ntype: meeting\ntitle: \(old)\n---\n# \(old)\n".utf8),
                                    relativePath: path, expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:active", title: "Review", sourceRef: path)
        _ = try jobs.enqueue(manifest: JobManifest(type: "transcription", title: "Transcribe", executionClass: .heavy,
            stages: [JobStageDefinition(id: "transcribe", title: "Transcribe")],
            sourceArtifacts: [JobArtifactReference(relativePath: path, role: "meeting")]))
        let kept = try MeetingTitleReviewService(vault: vault, inbox: inbox, jobStore: jobs)
            .accept(id: "meeting-title:active", title: "Project Sync")
        XCTAssertEqual(kept, path)
        XCTAssertTrue(String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self).contains("title: Project Sync"))
        XCTAssertTrue(try inbox.items(category: .required).isEmpty)
        XCTAssertEqual(try jobs.jobs().first?.manifest.sourceArtifacts.first?.relativePath, path)
    }

    func testAcceptMovesDoorwayWithoutOldAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let inbox = try TasksInbox(databaseURL: root.appendingPathComponent("inbox.sqlite"))
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let old = "Untitled Meeting at 2026-01-02 09:10"
        _ = try vault.writeMarkdown(Data("---\ntype: meeting\ntitle: \(old)\n---\n# \(old)\n\n## Live notes\n".utf8), relativePath: path, expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:a", title: "Review title", sourceRef: path)
        let service = MeetingTitleReviewService(vault: vault, inbox: inbox)
        let moved = try service.accept(id: "meeting-title:a", title: "Project Sync")
        XCTAssertEqual(moved, "Meetings/2026/01/02/09-10-project-sync/meeting.md")
        XCTAssertNil(try vault.versionOfMarkdown(relativePath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace/Meetings/2026/01/02/09-10-untitled-meeting").path))
        XCTAssertTrue(String(decoding: try vault.readMarkdown(relativePath: moved).data, as: UTF8.self).contains("# Project Sync"))
        XCTAssertTrue(try inbox.items(category: .required).isEmpty)
        let snapshots = root.appendingPathComponent("support/Snapshots")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: snapshots.path).isEmpty)
    }

    func testTitleReviewRenamesFolderAfterProcessingStops() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let inbox = try TasksInbox(databaseURL: root.appendingPathComponent("inbox.sqlite"))
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let old = "Untitled Meeting at 2026-01-02 09:10"
        _ = try vault.writeMarkdown(Data("---\ntype: meeting\ntitle: \(old)\n---\n# \(old)\n".utf8), relativePath: path, expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:a", title: "Untitled meeting 09:10-09:40", sourceRef: path)
        // The capture always queues a processing Job referencing this original doorway.
        let service = MeetingTitleReviewService(vault: vault, inbox: inbox)
        let renamed = try service.accept(id: "meeting-title:a", title: "Project Sync")
        XCTAssertEqual(renamed, "Meetings/2026/01/02/09-10-project-sync/meeting.md")
        XCTAssertNil(try vault.versionOfMarkdown(relativePath: path), "No old-path alias remains")
        XCTAssertNotNil(try vault.versionOfMarkdown(relativePath: renamed))
    }

    func testWorkspaceLinkStillResolvesAfterFolderMove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let inbox = try TasksInbox(databaseURL: root.appendingPathComponent("inbox.sqlite"))
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let old = "Untitled Meeting at 2026-01-02 09:10"
        _ = try vault.writeMarkdown(Data("---\ntype: meeting\ntitle: \(old)\n---\n# \(old)\n".utf8), relativePath: path, expectedVersion: nil)
        _ = try vault.writeMarkdown(Data("See [[09-10-untitled-meeting/meeting|meeting]]".utf8), relativePath: "Projects/plan.md", expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:a", title: "Untitled meeting 09:10-09:40", sourceRef: path)
        let service = MeetingTitleReviewService(vault: vault, inbox: inbox)
        XCTAssertEqual(try service.accept(id: "meeting-title:a", title: "Project Sync"), "Meetings/2026/01/02/09-10-project-sync/meeting.md")
        XCTAssertTrue(String(decoding: try vault.readMarkdown(relativePath: "Projects/plan.md").data, as: UTF8.self).contains("09-10-project-sync/meeting"))
        XCTAssertTrue(try inbox.items(category: .required).isEmpty)
    }

    func testExistingArtifactsMoveWithFolderWithoutAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let inbox = try TasksInbox(databaseURL: root.appendingPathComponent("inbox.sqlite"))
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let old = "Untitled Meeting at 2026-01-02 09:10"
        _ = try vault.writeMarkdown(Data("---\ntype: meeting\ntitle: \(old)\n---\n# \(old)\n".utf8), relativePath: path, expectedVersion: nil)
        _ = try vault.writeMarkdown(Data("# Summary".utf8), relativePath: "Meetings/2026/01/02/09-10-untitled-meeting/summary.md", expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:a", title: "Review", sourceRef: path)
        let service = MeetingTitleReviewService(vault: vault, inbox: inbox)
        XCTAssertEqual(try service.accept(id: "meeting-title:a", title: "Planning"), "Meetings/2026/01/02/09-10-planning/meeting.md")
        XCTAssertEqual(String(decoding: try vault.readMarkdown(relativePath: "Meetings/2026/01/02/09-10-planning/summary.md").data, as: UTF8.self), "# Summary")
        XCTAssertNil(try vault.versionOfMarkdown(relativePath: "Meetings/2026/01/02/09-10-untitled-meeting/summary.md"))
        let snapshots = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("support/Snapshots"), includingPropertiesForKeys: nil)
        XCTAssertTrue(snapshots.contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Meetings/2026/01/02/09-10-untitled-meeting/summary.md").path) })
    }

    func testRenameConflictKeepsReviewAndOriginalMeetingIntact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let inbox = try TasksInbox(databaseURL: root.appendingPathComponent("inbox.sqlite"))
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let old = "Untitled Meeting at 2026-01-02 09:10"
        _ = try vault.writeMarkdown(Data("---\ntype: meeting\ntitle: \(old)\n---\n# \(old)\n".utf8), relativePath: path, expectedVersion: nil)
        _ = try vault.writeMarkdown(Data("# Another meeting".utf8), relativePath: "Meetings/2026/01/02/09-10-project-sync/meeting.md", expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:a", title: "Review", sourceRef: path)
        XCTAssertThrowsError(try MeetingTitleReviewService(vault: vault, inbox: inbox).accept(id: "meeting-title:a", title: "Project Sync"))
        XCTAssertTrue(String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self).contains("# \(old)"))
        XCTAssertEqual(try inbox.items(category: .required).map(\.id), ["meeting-title:a"])
    }

    func testTitleReviewRejectsPathSeparatorsWithoutResolvingRequiredReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
            appSupportRootURL: root.appendingPathComponent("support"))
        let inbox = try TasksInbox(databaseURL: root.appendingPathComponent("inbox.sqlite"))
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        let text = "---\ntype: meeting\ntitle: Untitled Meeting at 2026-01-02 09:10\n---\n# Untitled Meeting at 2026-01-02 09:10\n"
        _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path, expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:a", title: "Review", sourceRef: path)
        XCTAssertThrowsError(try MeetingTitleReviewService(vault: vault, inbox: inbox)
            .accept(id: "meeting-title:a", title: "Project/Sync"))
        XCTAssertEqual(String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self), text)
        XCTAssertEqual(try inbox.items(category: .required).map(\.id), ["meeting-title:a"])
    }

    func testReferencesKeepOriginalFolderAndRejectStaleTitle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let inbox = try TasksInbox(databaseURL: root.appendingPathComponent("inbox.sqlite"))
        let path = "Meetings/2026/01/02/09-10-untitled-meeting/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntype: meeting\ntitle: Untitled Meeting at 2026-01-02 09:10\n---\n# Untitled Meeting at 2026-01-02 09:10\n".utf8), relativePath: path, expectedVersion: nil)
        try inbox.requireTitleReview(id: "meeting-title:a", title: "Review", sourceRef: path)
        let service = MeetingTitleReviewService(vault: vault, inbox: inbox)
        XCTAssertEqual(try service.accept(id: "meeting-title:a", title: "Planning"), "Meetings/2026/01/02/09-10-planning/meeting.md")
        XCTAssertThrowsError(try service.accept(id: "meeting-title:a", title: "Again"))
        XCTAssertNil(try vault.versionOfMarkdown(relativePath: path))
        XCTAssertTrue(String(decoding: try vault.readMarkdown(relativePath: "Meetings/2026/01/02/09-10-planning/meeting.md").data, as: UTF8.self).contains("title: Planning"))
    }
}
