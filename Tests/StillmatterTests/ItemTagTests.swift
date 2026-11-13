import XCTest
@testable import StillmatterCore

final class ItemTagTests: XCTestCase {
    func testAIAddsTagsToCurrentNoteWithoutChangingConcurrentTextOrState() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/test/my-notes.md"
        _ = try MeetingNoteTodoBridge(vault: vault).saveNotes("- [ ] Original #work\n", at: path, expectedNotesVersion: nil)
        let original = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first)
        let queue = try vault.readMarkdown(relativePath: TodoItemIndex.mainTodoRelativePath)
        _ = try MeetingNoteTodoBridge(vault: vault).updateText(item: original, text: "User's concurrent edit #work", expectedQueueVersion: queue.version)
        try ItemTagStore(vault: vault).applyAIAdditions([.init(itemID: original.id, tags: ["urgent", "work"])])
        let item = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first)
        XCTAssertEqual(item.title, "User's concurrent edit #work #urgent")
        XCTAssertEqual(item.tags, ["work", "urgent"])
        XCTAssertEqual(item.status, .open)
        let metadata = try XCTUnwrap(TodoItemParser.metadata(in: item.rawText))
        XCTAssertEqual(metadata.owner, "me"); XCTAssertEqual(metadata.review, "approved"); XCTAssertEqual(metadata.origin, "note")
        XCTAssertFalse(item.rawText.contains("#ai-gen")); XCTAssertFalse(item.rawText.contains("#need-approve"))
        XCTAssertEqual(try ItemTagStore(vault: vault).tags(), ["urgent", "work"])
    }
}

extension ItemTagTests {
    func testGlobalTagManagementUpdatesCanonicalNotesAndTodoAndPreservesOtherBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-global-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/test/my-notes.md"
        _ = try MeetingNoteTodoBridge(vault: vault).saveNotes("Prose #work\n- [ ] Note #work #other [[Page#work]] `#work`\n```\n- [ ] Sample #work\n```\n", at: path, expectedNotesVersion: nil)
        let store = ItemTagStore(vault: vault)
        try store.mutate(.create("unused"))
        XCTAssertEqual(try store.tags(), ["other", "unused", "work"])
        let item = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first { $0.title.hasPrefix("Note") })
        try store.mutate(.set(itemID: item.id, expected: item.tags, tags: ["work", "other", "unused"]))
        try store.mutate(.rename("work", to: "робота"))
        try store.mutate(.delete("other"))
        let reopened = ItemTagStore(vault: vault)
        XCTAssertEqual(try reopened.tags(), ["unused", "робота"])
        let todo = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first { $0.id == item.id })
        XCTAssertEqual(todo.tags, ["unused", "робота"])
        let notes = String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self)
        XCTAssertTrue(notes.contains("Prose #work")); XCTAssertTrue(notes.contains("[[Page#work]] `#work`")); XCTAssertTrue(notes.contains("Sample #work"))
        XCTAssertThrowsError(try reopened.mutate(.set(itemID: item.id, expected: ["work"], tags: [])))
        for mutation in [ItemTagMutation.create("ai-gen"), .delete("need-approve"), .rename("unused", to: "bad tag")] {
            XCTAssertThrowsError(try reopened.mutate(mutation))
        }
        XCTAssertEqual(try vault.readMarkdown(relativePath: path).data, Data(notes.utf8))
    }
}

extension ItemTagTests {
    func testAIRejectsReservedAndUnknownMutationsAtomicallyAndMergesRepeatedAdditions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-ai-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/test/my-notes.md"
        _ = try MeetingNoteTodoBridge(vault: vault).saveNotes("- [B] Note #work\r\n", at: path, expectedNotesVersion: nil)
        let item = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first)
        let original = try vault.readMarkdown(relativePath: path).data
        let store = ItemTagStore(vault: vault)
        for bad in ["ai-gen", "need-approve", "bad tag", "#wrong", "", "x\ntext"] {
            XCTAssertThrowsError(try store.applyAIAdditions([.init(itemID: item.id, tags: ["valid"]), .init(itemID: item.id, tags: [bad])]))
            XCTAssertEqual(try vault.readMarkdown(relativePath: path).data, original)
        }
        for key in ["text", "owner", "review", "status", "remove_tags"] {
            let json: [String: Any] = ["item_id": item.id, "tags": ["valid"], key: "malicious"]
            XCTAssertThrowsError(try JSONDecoder().decode(AIItemTagAddition.self, from: JSONSerialization.data(withJSONObject: json)))
        }
        XCTAssertThrowsError(try store.applyAIAdditions([.init(itemID: UUID().uuidString, tags: ["valid"])]))
        try store.applyAIAdditions([.init(itemID: item.id, tags: ["urgent", "urgent"]), .init(itemID: item.id, tags: ["urgent", "team"])])
        let final = String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self)
        XCTAssertEqual(final.components(separatedBy: "#urgent").count - 1, 1)
        XCTAssertTrue(final.contains("- [B] Note #work #urgent #team <!-- sm-item:"))
        XCTAssertTrue(final.hasSuffix("\r\n"))
        XCTAssertEqual(TodoItemParser.metadata(in: final.components(separatedBy: "\r\n")[0])?.review, "approved")
        let patch = AIItemTagAddition(itemID: item.id, tags: ["roundtrip"])
        XCTAssertEqual(try JSONDecoder().decode(AIItemTagAddition.self, from: JSONEncoder().encode(patch)), patch)
    }
}

extension ItemTagTests {
    func testGeneratedLifecycleRetainsTagsThroughEditApprovalCompletionAndRegeneration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-lifecycle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let meeting = "Meetings/test/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Test\ncapture_session_id: test\n---\n".utf8), relativePath: meeting, expectedVersion: nil)
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/test/transcript.json", decisions: [], myActionItems: [.init(id: "a", text: "Generated", citations: [])], otherActionItems: [], openQuestions: [])
        _ = try vault.writeMarkdown(JSONEncoder().encode(extraction), relativePath: "Meetings/test/summary-extraction.json", expectedVersion: nil)
        let artifacts = MeetingArtifactStore(vault: vault, inbox: nil)
        var item = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        XCTAssertEqual(item.tags, ["ai-gen", "need-approve"])
        try ItemTagStore(vault: vault).mutate(.set(itemID: item.id, expected: item.tags, tags: ["work"]))
        item = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        try artifacts.editReviewItem(item, text: "Edited task", owner: "me", dueDate: nil, status: .open, meetingPath: meeting, meetingID: "test")
        item = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        XCTAssertEqual(Set(item.tags), ["ai-gen", "need-approve", "work"])
        let base = try artifacts.load(meetingPath: meeting, meetingID: "test")
        try artifacts.publishGenerated(summary: Data("## Summary\nUpdated".utf8), extraction: extraction, extractionData: JSONEncoder().encode(extraction), base: base, meetingPath: meeting, meetingID: "test", expectedExtraction: vault.versionOfMarkdown(relativePath: "Meetings/test/summary-extraction.json"))
        item = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        XCTAssertTrue(item.tags.contains("work"))
        try artifacts.reviewItems([item], accept: true, meetingPath: meeting, meetingID: "test")
        item = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        XCTAssertFalse(item.tags.contains("need-approve")); XCTAssertTrue(item.tags.contains("ai-gen"))
        try artifacts.editReviewItem(item, text: "Completed task", owner: "me", dueDate: nil, status: .done, meetingPath: meeting, meetingID: "test")
        let completed = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        XCTAssertEqual(Set(completed.tags), ["ai-gen", "work"])
        let completedBase = try artifacts.load(meetingPath: meeting, meetingID: "test")
        try artifacts.publishGenerated(summary: Data("## Summary\nAgain".utf8), extraction: extraction, extractionData: JSONEncoder().encode(extraction), base: completedBase, meetingPath: meeting, meetingID: "test", expectedExtraction: vault.versionOfMarkdown(relativePath: "Meetings/test/summary-extraction.json"))
        XCTAssertEqual(try artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first?.rawLine, completed.rawLine)
    }
}

extension ItemTagTests {
    func testAnalysisPublishesAdditiveTagsAgainstCurrentNotesWithoutAnotherApproval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-analysis-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let meeting = "Meetings/test/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Test\ncapture_session_id: test\n---\n## Notes\n- [ ] Original #work\n".utf8), relativePath: meeting, expectedVersion: nil)
        let artifacts = MeetingArtifactStore(vault: vault, inbox: nil)
        let base = try artifacts.load(meetingPath: meeting, meetingID: "test")
        let note = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        try artifacts.editReviewItem(note, text: "Concurrent edit", owner: "Olena", dueDate: nil, status: .blocked, meetingPath: meeting, meetingID: "test")
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/test/transcript.json", decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [], tagAdditions: [.init(itemID: note.id, tags: ["team"])])
        try artifacts.publishGenerated(summary: Data("## Summary\nUpdated".utf8), extraction: extraction, extractionData: JSONEncoder().encode(extraction), base: base, meetingPath: meeting, meetingID: "test", expectedExtraction: vault.versionOfMarkdown(relativePath: "Meetings/test/summary-extraction.json"))
        let final = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        XCTAssertEqual(final.text, "Concurrent edit #work #team")
        XCTAssertEqual(final.owner, "Olena"); XCTAssertEqual(final.status, .blocked); XCTAssertEqual(final.review, "approved")
        XCTAssertFalse(final.tags.contains("ai-gen")); XCTAssertFalse(final.tags.contains("need-approve"))
        XCTAssertEqual(try JSONDecoder().decode(MeetingSummaryExtraction.self, from: JSONEncoder().encode(extraction)).tagAdditions, extraction.tagAdditions)
    }
}

extension ItemTagTests {
    func testSelectionAndStandaloneTagsAndArchivedMutationGuards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-selection-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        _ = try vault.writeMarkdown(Data("# Todos\n\n## Queue\n- [ ] Standalone #work\n".utf8), relativePath: "Todos/todo.md", expectedVersion: nil)
        let item = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first)
        let store = ItemTagStore(vault: vault)
        XCTAssertEqual(try store.selection(itemID: item.id).tags, ["work"])
        try store.mutate(.set(itemID: item.id, expected: ["work"], tags: ["team"]))
        XCTAssertEqual(try store.selection(itemID: item.id).tags, ["team"])
        XCTAssertThrowsError(try store.selection(itemID: "missing"))
        XCTAssertThrowsError(try store.mutate(.set(itemID: "missing", expected: [], tags: [])))
        XCTAssertThrowsError(try store.mutate(.rename("missing", to: "valid")))
        _ = try MeetingNoteTodoBridge(vault: vault).saveNotes("- [ ] Archived #team", at: "Meetings/test/my-notes.md", expectedNotesVersion: nil)
        _ = try vault.writeMarkdown(Data("{\"archived\":true}".utf8), relativePath: "Meetings/test/archive.json", expectedVersion: nil)
        let archived = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first { $0.title.hasPrefix("Archived") })
        XCTAssertFalse(try store.selection(itemID: archived.id).isEditable)
        XCTAssertThrowsError(try store.mutate(.delete("team")))
        let standalone = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first { $0.title.hasPrefix("Standalone") })
        XCTAssertEqual(try store.selection(itemID: standalone.id).tags, ["team"])
        XCTAssertTrue(try store.tags().contains("team"))
    }
}

extension ItemTagTests {
    func testMeetingServiceReturnsSameTagsAndCatalogAndRejectsArchivedEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-service-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let meeting = "Meetings/test/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Test\ncapture_session_id: test\n---\n## Notes\n- [ ] Original #work\n".utf8), relativePath: meeting, expectedVersion: nil)
        let service = MeetingManagementService(vault: vault)
        let note = try XCTUnwrap(service.detail(for: meeting).reviewItems.first)
        let updated = try service.mutateTags(meetingID: meeting, mutation: .set(itemID: note.id, expected: note.tags, tags: ["work", "team"]))
        XCTAssertEqual(updated.tagCatalog, ["team", "work"])
        XCTAssertEqual(updated.reviewItems.first?.tags, ["work", "team"])
        let created = try service.mutateTags(meetingID: meeting, mutation: .create("unused"))
        XCTAssertEqual(created.tagCatalog, ["team", "unused", "work"])
        _ = try service.mutateTags(meetingID: meeting, mutation: .rename("team", to: "group"))
        _ = try service.mutateTags(meetingID: meeting, mutation: .delete("group"))
        _ = try vault.writeMarkdown(Data("{\"archived\":true}".utf8), relativePath: "Meetings/test/archive.json", expectedVersion: nil)
        XCTAssertThrowsError(try service.mutateTags(meetingID: meeting, mutation: .create("blocked")))
    }
}

extension ItemTagTests {
    func testGlobalRenameRecoversAfterEveryFileBoundaryAndRejectsMalformedIdentity() throws {
        enum Interrupted: Error { case injected }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for stop in 0...3 {
            let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace-\(stop)"), appSupportRootURL: root.appendingPathComponent("support-\(stop)"))
            _ = try MeetingNoteTodoBridge(vault: vault).saveNotes("- [ ] First #old", at: "Meetings/first/my-notes.md", expectedNotesVersion: nil)
            _ = try MeetingNoteTodoBridge(vault: vault).saveNotes("- [ ] Second #old", at: "Meetings/second/my-notes.md", expectedNotesVersion: nil)
            let interrupted = ItemTagStore(vault: vault, checkpoint: { if $0 == stop { throw Interrupted.injected } })
            XCTAssertThrowsError(try interrupted.mutate(.rename("old", to: "new")))
            let reopened = ItemTagStore(vault: vault)
            XCTAssertEqual(try reopened.tags(), ["new"])
            XCTAssertTrue(try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().allSatisfy { $0.tags == ["new"] })
            _ = try vault.writeMarkdown(Data("- [ ] Bad <!-- sm-item:broken -->".utf8), relativePath: "Todos/bad.md", expectedVersion: nil)
            XCTAssertThrowsError(try reopened.tags())
        }
    }
    func testGeneratedActionTagPatchesAndInvalidTargetsAreAtomic() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-action-patch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let meeting = "Meetings/test/meeting.md", extractionPath = "Meetings/test/summary-extraction.json"
        _ = try vault.writeMarkdown(Data("---\ntitle: Test\ncapture_session_id: test\n---\n".utf8), relativePath: meeting, expectedVersion: nil)
        let extraction = MeetingSummaryExtraction(meeting: meeting, transcript: "Meetings/test/transcript.json", decisions: [], myActionItems: [.init(id: "a", text: "Task", citations: [])], otherActionItems: [], openQuestions: [])
        _ = try vault.writeMarkdown(JSONEncoder().encode(extraction), relativePath: extractionPath, expectedVersion: nil)
        let artifacts = MeetingArtifactStore(vault: vault, inbox: nil)
        let pending = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
        for approve in [false, true] {
            if approve { try artifacts.reviewItems([try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)], accept: true, meetingPath: meeting, meetingID: "test") }
            let base = try artifacts.load(meetingPath: meeting, meetingID: "test")
            let patched = MeetingSummaryExtraction(meeting: meeting, transcript: extraction.transcript, decisions: [], myActionItems: extraction.myActionItems, otherActionItems: [], openQuestions: [], tagAdditions: [.init(itemID: pending.id, tags: [approve ? "approved-tag" : "pending-tag"])])
            try artifacts.publishGenerated(summary: Data("## Summary\nValid".utf8), extraction: patched, extractionData: JSONEncoder().encode(patched), base: base, meetingPath: meeting, meetingID: "test", expectedExtraction: vault.versionOfMarkdown(relativePath: extractionPath))
            let current = try XCTUnwrap(artifacts.reviewItems(meetingPath: meeting, meetingID: "test").first)
            XCTAssertTrue(current.tags.contains(approve ? "approved-tag" : "pending-tag"))
            XCTAssertEqual(current.review, approve ? "approved" : "pending")
        }
        let base = try artifacts.load(meetingPath: meeting, meetingID: "test")
        let before = try vault.readMarkdown(relativePath: "Meetings/test/summary.md").data
        for patch in [AIItemTagAddition(itemID: pending.id, tags: ["need-approve"]), .init(itemID: UUID().uuidString, tags: ["valid"])] {
            let invalid = MeetingSummaryExtraction(meeting: meeting, transcript: extraction.transcript, decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [], tagAdditions: [patch])
            XCTAssertThrowsError(try artifacts.publishGenerated(summary: Data("Invalid".utf8), extraction: invalid, extractionData: JSONEncoder().encode(invalid), base: base, meetingPath: meeting, meetingID: "test", expectedExtraction: vault.versionOfMarkdown(relativePath: extractionPath)))
            XCTAssertEqual(try vault.readMarkdown(relativePath: "Meetings/test/summary.md").data, before)
        }
    }
}


extension ItemTagTests {
    func testIdenticalStandaloneRowsEditOnlySelectedCanonicalLine() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tags-identical-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        _ = try vault.writeMarkdown(Data("# Todos\n\n## Queue\n- [ ] Same #work\n- [ ] Same #work\n".utf8), relativePath: "Todos/todo.md", expectedVersion: nil)
        let items = try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems()
        XCTAssertEqual(items.count, 2)
        try ItemTagStore(vault: vault).mutate(.set(itemID: items[1].id, expected: ["work"], tags: ["team"]))
        let final = try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems()
        XCTAssertEqual(final[0].tags, ["work"])
        XCTAssertEqual(final[1].tags, ["team"])
    }
}
