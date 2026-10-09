import XCTest
@testable import StillmatterCore

final class TodoItemsTests: XCTestCase {
    func testParserRecognizesStatusesMetadataNestedItemsAndComments() {
        let markdown = """
        # Todos

        ## Queue

        - [ ] Send proposal due: 2026-01-10 [[Meetings/2026-01-01/summary#My action items|ref]]
          Capture client constraints before sending.
          - [B] Waiting on pricing due: 2026-01-02
        - [C] Skip obsolete follow-up

        ## Done

        - [x] File notes due: 2026-01-03
        """

        let items = TodoItemParser().parse(markdown: markdown, relativePath: "Todos/todo.md")

        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0].status, .open)
        XCTAssertEqual(items[0].title, "Send proposal")
        XCTAssertEqual(items[0].dueDate, "2026-01-10")
        XCTAssertEqual(items[0].sourceRef, "[[Meetings/2026-01-01/summary#My action items|ref]]")
        XCTAssertEqual(items[0].comments, ["Capture client constraints before sending."])
        XCTAssertEqual(items[1].status, .blocked)
        XCTAssertEqual(items[1].parentID, items[0].id)
        XCTAssertTrue(items[1].isNested)
        XCTAssertEqual(items[2].status, .canceled)
        XCTAssertEqual(items[3].status, .done)
        XCTAssertEqual(items[3].section, "Done")
    }

    func testTaskViewsComeFromMainTodoAndDiscoverCheckboxesOutsideIt() throws {
        let fixture = try TodoFixture()
        try fixture.write("Todos/todo.md", """
        # Todos

        ## Queue

        - [ ] Open queue item due: 2026-01-10
        - [B] Blocked queue item due: 2026-01-01

        ## Done

        - [x] Finished queue item due: 2026-01-01
        """)
        try fixture.write("Projects/General.md", """
        # General

        ## Todos

        - [ ] Project side task due: 2026-01-02 [[Meetings/kickoff/summary#My action items|ref]]
        """)

        let views = try TodoItemIndex(workspaceRootURL: fixture.workspaceRoot).loadTaskViews(today: "2026-01-05")

        XCTAssertEqual(views.queue.map(\.title), ["Open queue item", "Blocked queue item"])
        XCTAssertEqual(views.done.map(\.title), ["Finished queue item"])
        XCTAssertEqual(views.blocked.map(\.title), ["Blocked queue item"])
        XCTAssertEqual(views.overdue.map(\.title), ["Blocked queue item", "Project side task"])
        XCTAssertEqual(views.sourceFiltered("kickoff").map(\.title), ["Project side task"])
        XCTAssertTrue(views.allIndexed.contains { $0.location.relativePath == "Projects/General.md" })
    }

    func testCreatingTodoInsertsAtTopOfQueue() throws {
        let fixture = try TodoFixture()
        let vault = fixture.vault()
        let version = try vault.writeMarkdown(Data("""
        # Todos

        ## Queue

        - [ ] Existing top
        - [ ] Existing second

        ## Done
        """.utf8), relativePath: TodoItemIndex.mainTodoRelativePath, expectedVersion: nil)

        _ = try TodoItemMutator(vault: vault).createInQueue(
            title: "New priority",
            dueDate: "2026-01-10",
            sourceRef: "[[Meetings/kickoff/summary#My action items|ref]]",
            expectedVersion: version
        )

        XCTAssertEqual(try fixture.read(TodoItemIndex.mainTodoRelativePath), """
        # Todos

        ## Queue

        - [ ] New priority due: 2026-01-10 [[Meetings/kickoff/summary#My action items|ref]]
        - [ ] Existing top
        - [ ] Existing second

        ## Done
        """ + "\n")
    }

    func testMarkingDoneMovesItemBlockUnderDatedDoneSection() throws {
        let fixture = try TodoFixture()
        let vault = fixture.vault()
        let version = try vault.writeMarkdown(Data("""
        # Todos

        ## Queue

        - [ ] First task due: 2026-01-09
          Keep this note.
          - [ ] Child task
        - [ ] Second task

        ## Done

        ### 2026-01-18

        - [x] Newer task done: 2026-01-18

        ### 2026-01-17

        - [x] Older same-day task done: 2026-01-17
        """.utf8), relativePath: TodoItemIndex.mainTodoRelativePath, expectedVersion: nil)
        let item = try TodoItemIndex(workspaceRootURL: fixture.workspaceRoot).loadTaskViews(today: "2026-01-17").queue[0]

        _ = try TodoItemMutator(vault: vault, today: { "2026-01-17" }).updateStatus(item: item, status: .done, expectedVersion: version)

        XCTAssertEqual(try fixture.read(TodoItemIndex.mainTodoRelativePath), """
        # Todos

        ## Queue

        - [ ] Second task

        ## Done

        ### 2026-01-18

        - [x] Newer task done: 2026-01-18

        ### 2026-01-17

        - [x] First task due: 2026-01-09 done: 2026-01-17
          Keep this note.
          - [ ] Child task

        - [x] Older same-day task done: 2026-01-17
        """ + "\n")
    }

    func testMarkingNestedTaskDoneMovesItAsTopLevelDoneItem() throws {
        let fixture = try TodoFixture()
        let vault = fixture.vault()
        let version = try vault.writeMarkdown(Data("""
        # Todos

        ## Queue

        - [ ] Parent task
          - [ ] Nested task
            Keep nested note.

        ## Done
        """.utf8), relativePath: TodoItemIndex.mainTodoRelativePath, expectedVersion: nil)
        let item = try TodoItemIndex(workspaceRootURL: fixture.workspaceRoot).loadTaskViews(today: "2026-01-17").queue[1]

        _ = try TodoItemMutator(vault: vault, today: { "2026-01-17" }).updateStatus(item: item, status: .done, expectedVersion: version)

        XCTAssertEqual(try fixture.read(TodoItemIndex.mainTodoRelativePath), """
        # Todos

        ## Queue

        - [ ] Parent task

        ## Done

        ### 2026-01-17

        - [x] Nested task done: 2026-01-17
          Keep nested note.
        """ + "\n")
    }

    func testBlockedCanceledAndDueDateEditsStayInPlaceAndPreserveOrder() throws {
        let fixture = try TodoFixture()
        let vault = fixture.vault()
        var version = try vault.writeMarkdown(Data("""
        # Todos

        ## Queue

        - [ ] First task due: 2026-01-09
        - [ ] Second task
        - [ ] Third task
        """.utf8), relativePath: TodoItemIndex.mainTodoRelativePath, expectedVersion: nil)
        var views = try TodoItemIndex(workspaceRootURL: fixture.workspaceRoot).loadTaskViews(today: "2026-01-17")

        version = try TodoItemMutator(vault: vault).updateStatus(item: views.queue[1], status: .blocked, expectedVersion: version)
        views = try TodoItemIndex(workspaceRootURL: fixture.workspaceRoot).loadTaskViews(today: "2026-01-17")
        version = try TodoItemMutator(vault: vault).updateStatus(item: views.queue[2], status: .canceled, expectedVersion: version)
        views = try TodoItemIndex(workspaceRootURL: fixture.workspaceRoot).loadTaskViews(today: "2026-01-17")
        _ = try TodoItemMutator(vault: vault).updateDueDate(item: views.queue[0], dueDate: "2026-01-20", expectedVersion: version)

        XCTAssertEqual(try fixture.read(TodoItemIndex.mainTodoRelativePath), """
        # Todos

        ## Queue

        - [ ] First task due: 2026-01-20
        - [B] Second task
        - [C] Third task
        """ + "\n")
    }

    func testExternalConflictsPreventBlindTodoMutations() throws {
        let fixture = try TodoFixture()
        let vault = fixture.vault()
        let staleVersion = try vault.writeMarkdown(Data("""
        # Todos

        ## Queue

        - [ ] First task
        """.utf8), relativePath: TodoItemIndex.mainTodoRelativePath, expectedVersion: nil)
        let item = try TodoItemIndex(workspaceRootURL: fixture.workspaceRoot).loadTaskViews(today: "2026-01-17").queue[0]
        _ = try vault.writeMarkdown(Data("""
        # Todos

        ## Queue

        - [ ] External edit
        - [ ] First task
        """.utf8), relativePath: TodoItemIndex.mainTodoRelativePath, expectedVersion: staleVersion)

        XCTAssertThrowsError(try TodoItemMutator(vault: vault).updateStatus(item: item, status: .blocked, expectedVersion: staleVersion)) { error in
            guard case WorkspaceVaultError.conflict(let relativePath, _, _) = error else {
                return XCTFail("Expected conflict, got \(error)")
            }
            XCTAssertEqual(relativePath, TodoItemIndex.mainTodoRelativePath)
        }
    }

    func testManualValidationFixtureProducesExpectedTaskViews() throws {
        let fixture = try TodoFixture()
        try fixture.write("todos/todo.md", """
        # Todos

        ## Queue

        - [ ] Send proposal due: 2026-01-10 [[Meetings/kickoff/summary#My action items|ref]]
          Remember to include pricing notes.
          - [B] Waiting on legal review due: 2026-01-02
        - [C] Skip obsolete follow-up

        ## Done

        - [x] File meeting notes due: 2026-01-03
        """)
        try fixture.write("Projects/General.md", """
        # General Project

        ## Todos

        - [ ] Project side task due: 2026-01-02 [[Meetings/kickoff/summary#My action items|ref]]
        """)

        let views = try TodoItemIndex(workspaceRootURL: fixture.workspaceRoot).loadTaskViews(today: "2026-01-05")

        XCTAssertEqual(views.queue.map(\.title), [
            "Send proposal",
            "Waiting on legal review",
            "Skip obsolete follow-up"
        ])
        XCTAssertEqual(views.done.map(\.title), ["File meeting notes"])
        XCTAssertEqual(views.blocked.map(\.title), ["Waiting on legal review"])
        XCTAssertEqual(views.overdue.map(\.title), ["Waiting on legal review", "Project side task"])
        XCTAssertEqual(views.sourceFiltered("kickoff").map(\.title), ["Send proposal", "Project side task"])
        XCTAssertEqual(views.queue.first?.comments, ["Remember to include pricing notes."])
        XCTAssertEqual(views.queue[1].parentID, views.queue[0].id)
        XCTAssertEqual(views.queue[0].location.relativePath, "todos/todo.md")
        XCTAssertEqual(views.sourceFiltered("Projects/General.md").first?.title, "Project side task")
    }
}

private struct TodoFixture {
    let workspaceRoot: URL

    init() throws {
        workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterTodoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = workspaceRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (contents + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ relativePath: String) throws -> String {
        try String(contentsOf: workspaceRoot.appendingPathComponent(relativePath))
    }

    func vault() -> WorkspaceVault {
        WorkspaceVault(
            workspaceRootURL: workspaceRoot,
            appSupportRootURL: workspaceRoot.appendingPathComponent(".stillmatter", isDirectory: true)
        )
    }
}
