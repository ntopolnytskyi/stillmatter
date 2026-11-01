import Foundation
import XCTest
@testable import StillmatterCore

final class CanonicalTodoReferenceTests: XCTestCase {
    private let firstID = "ee935d20-e388-4ccf-b6bd-1f5dc785fd01"
    private let secondID = "ee935d20-e388-4ccf-b6bd-1f5dc785fd02"

    func testReferencesKeepQueueOrderAndDoneViewsWithoutDuplicatingCanonicalItems() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Meetings/one/action-items.md", checkbox(firstID, title: "Підсумок due: 2020-01-01 [[Meetings/one/summary|source]]") + "\n  Preserve my comment.\n" + checkbox(secondID, title: "Finished", marker: "x"))
        try fixture.write("Todos/todo.md", "## Queue\n- [ ] Independent first\n- [[item:\(firstID.uppercased())|stale [bracket] label]]\n- [ ] Independent last\n\n## Done\n- [[item:\(secondID)|Finished]]\n")
        let views = try fixture.index.loadTaskViews(today: "2026-01-01")
        XCTAssertEqual(views.queue.map(\.title), ["Independent first", "Підсумок", "Independent last"])
        XCTAssertEqual(views.done.map(\.id), [secondID])
        XCTAssertEqual(views.allIndexed.filter { $0.id == firstID }.count, 1)
        let task = try XCTUnwrap(views.queue.first { $0.id == firstID })
        XCTAssertEqual(task.location.relativePath, "Todos/todo.md")
        XCTAssertEqual(task.canonicalLocation?.relativePath, "Meetings/one/action-items.md")
        XCTAssertEqual(task.comments, ["Preserve my comment."])
        XCTAssertEqual(task.sourceRef, "[[Meetings/one/summary|source]]")
        XCTAssertEqual(views.overdue.map(\.id), [firstID])
        XCTAssertEqual(views.sourceFiltered("action-items.md").count, 2)
    }

    func testDueAndCompletionMutateOnlyCanonicalCheckboxAndKeepMetadataLast() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("Meetings/one/action-items.md", checkbox(firstID, title: "Canonical task #work") + "\n  Keep comment.\n")
        try fixture.write("Todos/todo.md", "## Queue\n- [[item:\(firstID)|Hint]]\n- [ ] Independent\n")
        let initial = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-01").queue.first)
        let mutator = TodoItemMutator(vault: fixture.vault, today: { "2026-01-10" })
        _ = try mutator.updateDueDate(item: initial, dueDate: "2026-01-09", expectedVersion: fixture.queueVersion())
        let withDue = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-10").queue.first { $0.id == firstID })
        XCTAssertEqual(withDue.dueDate, "2026-01-09")
        XCTAssertTrue(try fixture.read("Meetings/one/action-items.md").split(separator: "\n")[0].hasSuffix(" -->"))
        _ = try mutator.updateDueDate(item: withDue, dueDate: nil, expectedVersion: fixture.queueVersion())
        let withoutDue = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-10").queue.first { $0.id == firstID })
        XCTAssertNil(withoutDue.dueDate)
        _ = try mutator.updateStatus(item: withoutDue, status: .blocked, expectedVersion: fixture.queueVersion())
        let blocked = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-10").blocked.first)
        _ = try mutator.updateStatus(item: blocked, status: .done, expectedVersion: fixture.queueVersion())
        let final = try fixture.index.loadTaskViews(today: "2026-01-10")
        XCTAssertEqual(final.queue.map(\.title), ["Independent"])
        XCTAssertEqual(final.done.map(\.id), [firstID])
        XCTAssertEqual(final.done.first?.comments, ["Keep comment."])
        let canonical = try fixture.read("Meetings/one/action-items.md")
        XCTAssertTrue(canonical.contains("- [x] Canonical task #work done: 2026-01-10 <!-- sm-item:"))
        XCTAssertEqual(canonical.components(separatedBy: "<!-- sm-item:").count - 1, 1)
        let queue = try fixture.read("Todos/todo.md")
        XCTAssertFalse(queue.contains("sm-item:"))
        XCTAssertEqual(queue.components(separatedBy: "[[item:\(firstID)").count - 1, 1)
        XCTAssertTrue(queue.contains("## Done"))
    }

    func testExternalRenameAndUnrelatedSourceEditsPreserveUUIDResolution() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldPath = "Meetings/one/action-items.md"
        try fixture.write(oldPath, checkbox(firstID, title: "Task"))
        try fixture.write("Todos/todo.md", "## Queue\n- [[item:\(firstID)|Task]]\n")
        let task = try XCTUnwrap(fixture.index.loadAllItems().first)
        let newPath = "Meetings/one/renamed-actions.md"
        try FileManager.default.moveItem(at: fixture.workspace.appendingPathComponent(oldPath), to: fixture.workspace.appendingPathComponent(newPath))
        try fixture.write(newPath, "Unrelated external prose.\n" + fixture.read(newPath))
        _ = try TodoItemMutator(vault: fixture.vault).updateDueDate(item: task, dueDate: "2026-02-01", expectedVersion: fixture.queueVersion())
        let current = try XCTUnwrap(fixture.index.loadAllItems().first)
        XCTAssertEqual(current.id, firstID)
        XCTAssertEqual(current.canonicalLocation?.relativePath, newPath)
        XCTAssertEqual(current.dueDate, "2026-02-01")
        XCTAssertTrue(try fixture.read(newPath).hasPrefix("Unrelated external prose."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.appendingPathComponent(oldPath).path))
    }

    func testCRLFNestedReferencesRetainHierarchyAndUnicodeDuringCompletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = "Meetings/one/action-items.md"
        let original = checkbox(firstID, title: "Parent") + "  " + checkbox(secondID, title: "Child\u{2028}Unicode\u{2029} #робота")
        try fixture.write(path, original.replacingOccurrences(of: "\n", with: "\r\n"))
        try fixture.write("Todos/todo.md", "## Queue\r\n- [[item:\(firstID)|Parent]]\r\n  - [[item:\(secondID)|Child]]\r\n")
        let before = try fixture.index.loadTaskViews(today: "2026-01-01")
        XCTAssertEqual(before.queue.map(\.id), [firstID, secondID])
        let child = try XCTUnwrap(before.queue.last)
        XCTAssertEqual(child.parentID, firstID)
        XCTAssertTrue(child.isNested)
        _ = try TodoItemMutator(vault: fixture.vault, today: { "2026-01-10" }).updateDueDate(item: child,
            dueDate: "2026-04-01", expectedVersion: fixture.queueVersion())
        let withDue = try XCTUnwrap(fixture.index.loadTaskViews(today: "2026-01-10").queue.last)
        XCTAssertEqual(withDue.dueDate, "2026-04-01")
        _ = try TodoItemMutator(vault: fixture.vault, today: { "2026-01-10" }).updateStatus(item: withDue,
            status: .done, expectedVersion: fixture.queueVersion())
        let after = try fixture.index.loadTaskViews(today: "2026-01-10")
        XCTAssertEqual(after.queue.map(\.id), [firstID])
        XCTAssertEqual(after.done.map(\.id), [secondID])
        XCTAssertNil(after.done.first?.parentID)
        let saved = try fixture.read(path)
        XCTAssertTrue(saved.contains("\r\n  - [x] Child\u{2028}Unicode\u{2029} #робота due: 2026-04-01 done: 2026-01-10 <!-- sm-item:"))
        XCTAssertEqual(saved.components(separatedBy: "\r\n").count, 3)
    }

    func testCanonicalSummaryHistoricalCheckboxesDoNotDuplicateMigratedTasks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let summary = "- [ ] Historical checkbox\n"
        try fixture.write("Meetings/one/summary.md", summary)
        XCTAssertEqual(try fixture.index.loadAllItems().count, 1, "Legacy discovery remains supported before migration")
        try fixture.write("Meetings/one/summary.md", "<!-- stillmatter-artifact:summary:v1 -->\n" + summary)
        try fixture.write("Meetings/one/action-items.md", checkbox(firstID, title: "Canonical task"))
        try fixture.write("Todos/todo.md", "## Queue\n- [[item:\(firstID)|Task]]\n")
        XCTAssertEqual(try fixture.index.loadAllItems().map(\.id), [firstID])
    }

    func testExternalCanonicalEditAndQueueEditRejectStaleMutationsWithoutWrites() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = "Meetings/one/action-items.md"
        try fixture.write(path, checkbox(firstID, title: "Original"))
        try fixture.write("Todos/todo.md", "## Queue\n- [[item:\(firstID)|Task]]\n")
        let task = try XCTUnwrap(fixture.index.loadAllItems().first)
        let version = try fixture.queueVersion()
        try fixture.write(path, checkbox(firstID, title: "External due: 2026-03-01", marker: "x"))
        let external = try fixture.read(path)
        XCTAssertThrowsError(try TodoItemMutator(vault: fixture.vault).updateStatus(item: task, status: .done, expectedVersion: version)) { error in
            XCTAssertEqual(error as? TodoItemMutationError, .staleCanonicalItem(self.firstID))
            XCTAssertTrue(error.localizedDescription.contains("canonical file"))
        }
        XCTAssertEqual(try fixture.read(path), external)
        let refreshed = try XCTUnwrap(fixture.index.loadAllItems().first)
        try fixture.write("Todos/todo.md", "## Queue\nExternal queue prose.\n- [[item:\(firstID)|Task]]\n")
        let queue = try fixture.read("Todos/todo.md")
        XCTAssertThrowsError(try TodoItemMutator(vault: fixture.vault).updateDueDate(item: refreshed, dueDate: nil, expectedVersion: version))
        XCTAssertEqual(try fixture.read("Todos/todo.md"), queue)
        XCTAssertEqual(try fixture.read(path), external)
    }

    func testDeletedOrReassignedCanonicalTasksDisappearAndDuplicateReferencesAreActionable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = "Meetings/one/action-items.md"
        try fixture.write(path, checkbox(firstID, title: "Task"))
        try fixture.write("Todos/todo.md", "## Queue\n- [[item:\(firstID)|Task]]\n")
        let task = try XCTUnwrap(fixture.index.loadAllItems().first)
        try fixture.write(path, "Task removed externally.\n")
        XCTAssertTrue(try fixture.index.loadAllItems().isEmpty)
        XCTAssertThrowsError(try TodoItemMutator(vault: fixture.vault).updateStatus(item: task, status: .done, expectedVersion: fixture.queueVersion())) { error in
            XCTAssertEqual(error as? TodoItemMutationError, .itemNotFound(self.firstID))
            XCTAssertTrue(error.localizedDescription.contains("no longer exists"))
        }
        try fixture.write(path, checkbox(firstID, title: "Other owner", owner: "person-other"))
        XCTAssertTrue(try fixture.index.loadAllItems().isEmpty)
        try fixture.write(path, checkbox(firstID, title: "Pending", review: "pending"))
        XCTAssertTrue(try fixture.index.loadAllItems().isEmpty)
        try fixture.write(path, checkbox(firstID, title: "Task"))
        try fixture.write("Todos/todo.md", "## Queue\n- [[item:\(firstID)|Task]]\n- [[item:\(firstID)|Duplicate]]\n")
        XCTAssertThrowsError(try fixture.index.loadAllItems()) { error in
            XCTAssertEqual(error as? TodoItemMutationError, .duplicateIdentity(self.firstID))
            XCTAssertTrue(error.localizedDescription.contains("one canonical checkbox"))
        }
        try fixture.write("Todos/todo.md", "## Queue\n- [[item:not-a-uuid|Broken]]\n")
        XCTAssertThrowsError(try fixture.index.loadAllItems()) { error in
            XCTAssertTrue(error.localizedDescription.contains("Restore its item UUID"))
        }
        try fixture.write("Todos/todo.md", "## Queue\n- [[item:\(firstID)]]\n")
        try fixture.write("Meetings/one/duplicate.md", checkbox(firstID, title: "Duplicate checkbox"))
        XCTAssertThrowsError(try fixture.index.loadAllItems()) { error in
            XCTAssertEqual(error as? TodoItemMutationError, .duplicateIdentity(self.firstID))
        }
    }

    private func checkbox(_ id: String, title: String, marker: String = " ", owner: String = "me", review: String = "approved") -> String {
        let item = MeetingItemMetadata(v: 1, id: id, owner: owner, review: review, origin: "legacy-todo", legacyID: nil, citations: [])
        let metadata = String(decoding: try! JSONEncoder().encode(item), as: UTF8.self)
        return "- [\(marker)] \(title) <!-- sm-item:\(metadata) -->\n"
    }
}

private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-todo-references-\(UUID().uuidString)")
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
    func queueVersion() throws -> WorkspaceFileVersion { try vault.readMarkdown(relativePath: "Todos/todo.md").version }
}
