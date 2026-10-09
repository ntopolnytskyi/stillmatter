import XCTest
@testable import StillmatterCore

final class CanonicalVaultInitializerTests: XCTestCase {
    func testInitializeCreatesCanonicalFoldersAndStarterFiles() throws {
        let fixture = try VaultFixture()
        let initializer = CanonicalVaultInitializer(vault: fixture.vault())

        try initializer.initialize()

        for directory in CanonicalVaultInitializer.canonicalDirectories {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent(directory).path, isDirectory: &isDirectory),
                "Expected \(directory) to exist"
            )
            XCTAssertTrue(isDirectory.boolValue, "Expected \(directory) to be a directory")
        }

        XCTAssertEqual(
            try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("Todos/todo.md")),
            """
            # Todos

            ## Queue

            ## Done
            """ + "\n"
        )
        XCTAssertTrue(
            try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("Projects/General.md"))
                .contains("# General")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent("Meetings/README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent("Activities/README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent("Briefs/README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent("Reports/README.md").path))
    }

    func testInitializeRepairsMissingStarterFilesWithoutReplacingExistingUserContent() throws {
        let fixture = try VaultFixture()
        let vault = fixture.vault()
        let initializer = CanonicalVaultInitializer(vault: vault)
        let userMeetingReadme = "# My Meetings\n\nKeep these notes.\n"

        _ = try vault.writeMarkdown(Data(userMeetingReadme.utf8), relativePath: "Meetings/README.md", expectedVersion: nil)

        try initializer.initialize()
        try FileManager.default.removeItem(at: fixture.workspaceRoot.appendingPathComponent("Briefs/README.md"))
        try FileManager.default.removeItem(at: fixture.workspaceRoot.appendingPathComponent("Reports/Weekly"))

        try initializer.initialize()

        XCTAssertEqual(
            try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("Meetings/README.md")),
            userMeetingReadme
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.workspaceRoot.appendingPathComponent("Briefs/README.md").path))
        var isWeeklyReportsDirectory: ObjCBool = false
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.workspaceRoot.appendingPathComponent("Reports/Weekly").path,
                isDirectory: &isWeeklyReportsDirectory
            )
        )
        XCTAssertTrue(isWeeklyReportsDirectory.boolValue)
    }

    func testInitializePreservesExistingUserFiles() throws {
        let fixture = try VaultFixture()
        let vault = fixture.vault()
        let initializer = CanonicalVaultInitializer(vault: vault)
        let existingTodo = """
        # My Todos

        ## Queue

        - [ ] Preserve this user edit

        ## Done
        """ + "\n"
        let existingGeneral = "# My General Project\n\nUser-owned notes.\n"

        _ = try vault.writeMarkdown(Data(existingTodo.utf8), relativePath: "Todos/todo.md", expectedVersion: nil)
        _ = try vault.writeMarkdown(Data(existingGeneral.utf8), relativePath: "Projects/General.md", expectedVersion: nil)

        try initializer.initialize()

        XCTAssertEqual(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("Todos/todo.md")), existingTodo)
        XCTAssertEqual(try String(contentsOf: fixture.workspaceRoot.appendingPathComponent("Projects/General.md")), existingGeneral)
    }
}

private struct VaultFixture {
    let root: URL
    let workspaceRoot: URL
    let appSupportRoot: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterInitializerTests-\(UUID().uuidString)", isDirectory: true)
        workspaceRoot = root.appendingPathComponent("Vault", isDirectory: true)
        appSupportRoot = root.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appSupportRoot, withIntermediateDirectories: true)
    }

    func vault() -> WorkspaceVault {
        WorkspaceVault(workspaceRootURL: workspaceRoot, appSupportRootURL: appSupportRoot)
    }
}
