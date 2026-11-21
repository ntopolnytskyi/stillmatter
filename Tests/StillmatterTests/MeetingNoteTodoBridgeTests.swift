import XCTest
@testable import StillmatterCore

final class MeetingNoteTodoBridgeTests: XCTestCase {
    func testSavedNoteCheckboxIsAdoptedOnceAndProjectedIntoPersonalTodo() throws {
        let fixture = try NoteTodoFixture()
        defer { fixture.remove() }
        try fixture.write("Meetings/one/my-notes.md", "## Notes\n- [ ] Send the recap #work\n")
        try fixture.write("Todos/todo.md", "## Queue\n- [ ] Existing task\n\n## Done\n")

        let bridge = MeetingNoteTodoBridge(vault: fixture.vault)
        try bridge.adoptSavedNotes(at: "Meetings/one/my-notes.md")
        let adoptedNotes = try fixture.read("Meetings/one/my-notes.md")
        let item = try XCTUnwrap(TodoItemParser().parse(markdown: adoptedNotes, relativePath: "Meetings/one/my-notes.md").first)
        let queue = try fixture.index.loadTaskViews(today: "2026-01-01").queue

        XCTAssertEqual(queue.map(\.title), ["Send the recap #work", "Existing task"])
        XCTAssertEqual(queue.first?.id, item.id)
        XCTAssertEqual(queue.first?.canonicalLocation?.relativePath, "Meetings/one/my-notes.md")
        XCTAssertTrue(item.rawText.contains("origin\":\"note\""))
        XCTAssertTrue(item.rawText.contains("owner\":\"me\""))
        XCTAssertTrue(item.rawText.contains("review\":\"approved\""))

        try bridge.adoptSavedNotes(at: "Meetings/one/my-notes.md")
        XCTAssertEqual(try fixture.read("Meetings/one/my-notes.md"), adoptedNotes)
        XCTAssertEqual(try fixture.read("Todos/todo.md").components(separatedBy: "[[item:\(item.id)").count - 1, 1)
    }

    func testTextAndCompletionEditsFromTodoWriteBackToMyNotesAndSurviveReload() throws {
        let fixture = try NoteTodoFixture()
        defer { fixture.remove() }
        try fixture.write("Meetings/one/my-notes.md", "- [ ] Original note task\n")
        let bridge = MeetingNoteTodoBridge(vault: fixture.vault)
        try bridge.adoptSavedNotes(at: "Meetings/one/my-notes.md")
        var item = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-01").queue.first)
        _ = try bridge.updateText(item: item, text: "Edited in Todo", expectedQueueVersion: fixture.queueVersion())
        item = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-01").queue.first)
        XCTAssertEqual(item.title, "Edited in Todo")
        XCTAssertTrue(try fixture.read("Todos/todo.md").contains("[[item:\(item.id)|Edited in Todo]]"))
        XCTAssertFalse(try fixture.read("Todos/todo.md").contains("[[item:\(item.id)|Original note task]]"))
        _ = try TodoItemMutator(vault: fixture.vault, today: { "2026-01-02" })
            .updateStatus(item: item, status: .done, expectedVersion: fixture.queueVersion())

        let reopened = try fixture.index.loadTaskViews(today: "2026-01-03")
        XCTAssertEqual(reopened.done.map(\.id), [item.id])
        XCTAssertTrue(try fixture.read("Meetings/one/my-notes.md").contains("- [x] Edited in Todo done: 2026-01-02 <!-- sm-item:"))
        XCTAssertEqual(reopened.allIndexed.filter { $0.id == item.id }.count, 1)
    }

    func testSourceRemovalHidesNoteTaskFromPersonalQueue() throws {
        let fixture = try NoteTodoFixture()
        defer { fixture.remove() }
        try fixture.write("Meetings/one/my-notes.md", "- [ ] Remove this\n")
        let bridge = MeetingNoteTodoBridge(vault: fixture.vault)
        try bridge.adoptSavedNotes(at: "Meetings/one/my-notes.md")
        XCTAssertEqual(try fixture.index.loadTaskViews(today: "2026-01-01").queue.count, 1)

        try fixture.write("Meetings/one/my-notes.md", "The source checkbox was removed.\n")
        XCTAssertTrue(try fixture.index.loadTaskViews(today: "2026-01-01").queue.isEmpty)
        XCTAssertTrue(try fixture.index.loadAllItems().isEmpty)
    }

    func testRemovingCheckboxDuringNotesSaveAlsoRemovesItsQueueReference() throws {
        let fixture = try NoteTodoFixture()
        defer { fixture.remove() }
        let path = "Meetings/one/my-notes.md"
        try fixture.write(path, "- [ ] Remove this task\n")
        let bridge = MeetingNoteTodoBridge(vault: fixture.vault)
        try bridge.adoptSavedNotes(at: path)
        let item = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-01").queue.first)
        try fixture.write(path, "No checkbox remains.\n")

        try bridge.adoptSavedNotes(at: path, removingItemIDs: [item.id])

        XCTAssertFalse(try fixture.read("Todos/todo.md").contains("[[item:\(item.id)"))
        XCTAssertTrue(try fixture.index.loadTaskViews(today: "2026-01-01").queue.isEmpty)
    }

    func testExternalCheckboxRemovalPrunesOnlyItsTodoReference() throws {
        let fixture = try NoteTodoFixture()
        defer { fixture.remove() }
        let path = "Meetings/one/my-notes.md"
        try fixture.write(path, "- [ ] Remove this externally\n")
        let bridge = MeetingNoteTodoBridge(vault: fixture.vault)
        try bridge.adoptSavedNotes(at: path)
        let item = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-01").queue.first)

        let externalNotes = "External prose remains authoritative.\n"
        _ = try fixture.vault.writeMarkdown(Data(externalNotes.utf8), relativePath: path,
                                             expectedVersion: fixture.vault.versionOfMarkdown(relativePath: path))
        XCTAssertTrue(try fixture.index.loadTaskViews(today: "2026-01-01").queue.isEmpty)

        XCTAssertEqual(try bridge.pruneDanglingReferences(), [item.id])
        XCTAssertEqual(try fixture.read(path), externalNotes)
        XCTAssertFalse(try fixture.read("Todos/todo.md").contains("[[item:\(item.id)"))
        XCTAssertTrue(try fixture.index.loadTaskViews(today: "2026-01-01").queue.isEmpty)
    }

    func testExternalNotesChangeWinsAndStaleTodoEditDoesNotOverwriteIt() throws {
        let fixture = try NoteTodoFixture()
        defer { fixture.remove() }
        try fixture.write("Meetings/one/my-notes.md", "- [ ] Original\n")
        let bridge = MeetingNoteTodoBridge(vault: fixture.vault)
        try bridge.adoptSavedNotes(at: "Meetings/one/my-notes.md")
        let item = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-01").queue.first)
        let external = try fixture.read("Meetings/one/my-notes.md").replacingOccurrences(of: "Original", with: "External edit")
        try fixture.write("Meetings/one/my-notes.md", external)

        XCTAssertThrowsError(try bridge.updateText(item: item, text: "Local stale edit", expectedQueueVersion: fixture.queueVersion()))
        XCTAssertEqual(try fixture.read("Meetings/one/my-notes.md"), external)
        XCTAssertEqual(try fixture.index.loadTaskViews(today: "2026-01-01").queue.first?.title, "External edit")
    }
}

private struct NoteTodoFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-note-todo-\(UUID().uuidString)")
    var workspace: URL { root.appendingPathComponent("workspace") }
    var vault: WorkspaceVault { WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support")) }
    var index: TodoItemIndex { TodoItemIndex(workspaceRootURL: workspace) }
    init() throws { try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true) }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func write(_ path: String, _ text: String) throws {
        let url = workspace.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
    func read(_ path: String) throws -> String { try String(contentsOf: workspace.appendingPathComponent(path), encoding: .utf8) }
    func queueVersion() throws -> WorkspaceFileVersion {
        try XCTUnwrap(vault.versionOfMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath))
    }
}
