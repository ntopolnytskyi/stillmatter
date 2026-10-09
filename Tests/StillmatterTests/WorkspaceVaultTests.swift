import XCTest
@testable import StillmatterCore

final class WorkspaceVaultTests: XCTestCase {
    func testWriteRequiresCurrentVersionAndRefusesBlindOverwrite() throws {
        let fixture = try VaultFixture()
        let vault = fixture.vault()

        let firstVersion = try vault.writeMarkdown(Data("# Today\n".utf8), relativePath: "Daily/today.md", expectedVersion: nil)
        _ = try vault.writeMarkdown(Data("# Today\n- planned\n".utf8), relativePath: "Daily/today.md", expectedVersion: firstVersion)

        XCTAssertThrowsError(
            try vault.writeMarkdown(Data("# stale overwrite\n".utf8), relativePath: "Daily/today.md", expectedVersion: firstVersion)
        ) { error in
            guard case WorkspaceVaultError.conflict(let relativePath, let expected, let actual) = error else {
                return XCTFail("Expected conflict, got \(error)")
            }
            XCTAssertEqual(relativePath, "Daily/today.md")
            XCTAssertEqual(expected, firstVersion)
            XCTAssertNotEqual(actual, firstVersion)
        }
    }

    func testFailedRenameRestoresDoorwayAndAllRewrittenReferencesWithoutAlias() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"),
            appSupportRootURL: root.appendingPathComponent("support"))
        let old = "Meetings/2026/01/01/09-10-old/meeting.md"
        let reference = "Projects/links.md"
        let original = Data("---\ntitle: Old\n---\n# Old\n".utf8)
        let link = Data("[[Meetings/2026/01/01/09-10-old/meeting|ref]]".utf8)
        let doorway = try vault.writeMarkdown(original, relativePath: old, expectedVersion: nil)
        let version = try vault.writeMarkdown(link, relativePath: reference, expectedVersion: nil)
        XCTAssertThrowsError(try vault.renameMeetingDirectory(from: old,
            to: "Meetings/2026/01/01/09-10-new/meeting.md", updatedDoorway: Data("# New".utf8),
            expectedVersion: doorway, referenceReplacements: [WorkspaceMarkdownReplacement(
                relativePath: reference, data: Data("[[Meetings/2026/01/01/09-10-new/meeting|ref]]".utf8),
                expectedVersion: version)]) {
            throw NSError(domain: "Injected post-move failure", code: 1)
        })
        XCTAssertEqual(try vault.readMarkdown(relativePath: old).data, original)
        XCTAssertEqual(try vault.readMarkdown(relativePath: reference).data, link)
        XCTAssertNil(try vault.versionOfMarkdown(relativePath: "Meetings/2026/01/01/09-10-new/meeting.md"))
    }

    func testDestructiveWriteCreatesAppSupportSnapshot() throws {
        let fixture = try VaultFixture()
        let vault = fixture.vault()
        let version = try vault.writeMarkdown(Data("- [ ] Follow up\n".utf8), relativePath: "Todos/todo.md", expectedVersion: nil)

        let snapshot = try vault.deleteMarkdown(relativePath: "Todos/todo.md", expectedVersion: version)

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent("Todos/todo.md").path))
        let snapshotCopy = snapshot.url.appendingPathComponent("Todos/todo.md")
        XCTAssertEqual(try String(contentsOf: snapshotCopy), "- [ ] Follow up\n")
        XCTAssertEqual(snapshot.capturedRelativePaths, ["Todos/todo.md"])
        XCTAssertTrue(snapshot.url.path.hasPrefix(fixture.appSupportRoot.appendingPathComponent("Snapshots").path))
    }

    func testMarkdownTransactionChangesNothingWhenAnyVersionConflicts() throws {
        let fixture = try VaultFixture()
        let vault = fixture.vault()
        let firstPath = "Briefs/Weekly/2026-W38.md"
        let secondPath = "Todos/todo.md"
        let firstVersion = try vault.writeMarkdown(Data("draft\n".utf8), relativePath: firstPath, expectedVersion: nil)
        let staleSecondVersion = try vault.writeMarkdown(Data("todos before\n".utf8), relativePath: secondPath, expectedVersion: nil)
        _ = try vault.writeMarkdown(
            Data("external todo edit\n".utf8),
            relativePath: secondPath,
            expectedVersion: staleSecondVersion
        )

        XCTAssertThrowsError(try vault.replaceMarkdownTransaction([
            WorkspaceMarkdownReplacement(
                relativePath: firstPath,
                data: Data("accepted\n".utf8),
                expectedVersion: firstVersion
            ),
            WorkspaceMarkdownReplacement(
                relativePath: secondPath,
                data: Data("todos after\n".utf8),
                expectedVersion: staleSecondVersion
            )
        ]))

        XCTAssertEqual(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(firstPath)), "draft\n")
        XCTAssertEqual(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent(secondPath)), "external todo edit\n")
    }

    func testSuccessfulCrossFileTransactionSnapshotsOriginalFilesBeforeReplacingThem() throws {
        let fixture = try VaultFixture()
        let vault = fixture.vault()
        let todoVersion = try vault.writeMarkdown(Data("before todo\n".utf8), relativePath: "Todos/todo.md", expectedVersion: nil)
        let briefVersion = try vault.writeMarkdown(Data("before brief\n".utf8), relativePath: "Briefs/Weekly/2026-W38.md", expectedVersion: nil)

        try vault.replaceMarkdownTransaction([
            WorkspaceMarkdownReplacement(
                relativePath: "Todos/todo.md",
                data: Data("after todo\n".utf8),
                expectedVersion: todoVersion
            ),
            WorkspaceMarkdownReplacement(
                relativePath: "Briefs/Weekly/2026-W38.md",
                data: Data("after brief\n".utf8),
                expectedVersion: briefVersion
            )
        ])

        XCTAssertEqual(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("Todos/todo.md")), "after todo\n")
        XCTAssertEqual(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("Briefs/Weekly/2026-W38.md")), "after brief\n")

        let snapshot = try fixture.onlySnapshot(in: fixture.appSupportRoot)
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("Todos/todo.md")), "before todo\n")
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("Briefs/Weekly/2026-W38.md")), "before brief\n")
    }

    func testMoveSnapshotsSourceBeforeCrossFileOperation() throws {
        let fixture = try VaultFixture()
        let vault = fixture.vault()
        let sourceVersion = try vault.writeMarkdown(Data("# Original\n".utf8), relativePath: "Meetings/original.md", expectedVersion: nil)

        let snapshot = try vault.moveMarkdown(
            from: "Meetings/original.md",
            to: "Meetings/renamed.md",
            expectedSourceVersion: sourceVersion
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent("Meetings/original.md").path))
        XCTAssertEqual(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("Meetings/renamed.md")), "# Original\n")
        XCTAssertEqual(try String(contentsOf: snapshot.url.appendingPathComponent("Meetings/original.md")), "# Original\n")
    }

    func testSnapshotRetentionIsBoundedByAgeAndSize() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let fixture = try VaultFixture()
        let vault = fixture.vault(
            retentionPolicy: WorkspaceSnapshotRetentionPolicy(maxAge: 100, maxTotalBytes: 70),
            now: { now }
        )
        let oldSnapshot = fixture.appSupportRoot.appendingPathComponent("Snapshots/old", isDirectory: true)
        try FileManager.default.createDirectory(at: oldSnapshot, withIntermediateDirectories: true)
        try Data(repeating: 65, count: 10).write(to: oldSnapshot.appendingPathComponent("old.md"))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-101)], ofItemAtPath: oldSnapshot.path)

        let firstVersion = try vault.writeMarkdown(Data(repeating: 66, count: 80), relativePath: "Meetings/a.md", expectedVersion: nil)
        _ = try vault.deleteMarkdown(relativePath: "Meetings/a.md", expectedVersion: firstVersion)

        let secondVersion = try vault.writeMarkdown(Data("small".utf8), relativePath: "Meetings/b.md", expectedVersion: nil)
        let keptSnapshot = try vault.deleteMarkdown(relativePath: "Meetings/b.md", expectedVersion: secondVersion)

        let retainedSnapshots = try FileManager.default.contentsOfDirectory(
            at: fixture.appSupportRoot.appendingPathComponent("Snapshots", isDirectory: true),
            includingPropertiesForKeys: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldSnapshot.path), "Snapshots older than the retention age are removed")
        XCTAssertEqual(retainedSnapshots.map(\.lastPathComponent), [keptSnapshot.url.lastPathComponent], "Oldest snapshots are removed until the size bound is met")
        XCTAssertTrue(FileManager.default.fileExists(atPath: keptSnapshot.url.path), "Newest bounded snapshot is retained")
    }
}

private struct VaultFixture {
    let root: URL
    let workspaceRoot: URL
    let appSupportRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterVaultTests-\(UUID().uuidString)", isDirectory: true)
        workspaceRoot = root.appendingPathComponent("Vault", isDirectory: true)
        appSupportRoot = root.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
    }

    func onlySnapshot(in appSupportRoot: URL) throws -> URL {
        let snapshots = try FileManager.default.contentsOfDirectory(
            at: appSupportRoot.appendingPathComponent("Snapshots", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        guard snapshots.count == 1, let snapshot = snapshots.first else {
            throw NSError(domain: "WorkspaceVaultTests", code: 1, userInfo: nil)
        }
        return snapshot
    }

    func vault(
        retentionPolicy: WorkspaceSnapshotRetentionPolicy = WorkspaceSnapshotRetentionPolicy(),
        now: @escaping () -> Date = Date.init
    ) -> WorkspaceVault {
        WorkspaceVault(
            workspaceRootURL: workspaceRoot,
            appSupportRootURL: appSupportRoot,
            retentionPolicy: retentionPolicy,
            now: now
        )
    }
}
