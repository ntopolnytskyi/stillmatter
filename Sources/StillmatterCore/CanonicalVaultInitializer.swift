import Foundation

public final class CanonicalVaultInitializer {
    private let vault: WorkspaceVault

    public init(vault: WorkspaceVault) {
        self.vault = vault
    }

    public func initialize() throws {
        for directory in Self.canonicalDirectories {
            try vault.createDirectory(relativePath: directory)
        }

        for file in Self.starterFiles {
            if try vault.versionOfMarkdown(relativePath: file.relativePath) == nil {
                _ = try vault.writeMarkdown(Data(file.contents.utf8), relativePath: file.relativePath, expectedVersion: nil)
            }
        }
    }

    public static let canonicalDirectories = [
        "Todos",
        "Projects",
        "Meetings"
    ]

    private static let starterFiles: [(relativePath: String, contents: String)] = [
        (
            "Todos/todo.md",
            """
            # Todos

            ## Queue

            ## Done
            """ + "\n"
        ),
        (
            "Projects/General.md",
            """
            # General

            ## Purpose

            Catch-all project for work that does not belong to a more specific Project.

            ## Current focus

            ## Knowledge

            ## Meetings

            ## Todos

            ## Decisions

            """ + "\n"
        ),
        (
            "Meetings/README.md",
            """
            # Meetings

            Meeting folders created by Stillmatter live here.
            """ + "\n"
        )
    ]
}
