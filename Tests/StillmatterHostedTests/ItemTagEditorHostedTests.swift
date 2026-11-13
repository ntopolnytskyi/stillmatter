import AppKit
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

final class ItemTagEditorHostedTests: XCTestCase {
    @MainActor
    func testSharedEditorPersistsMultipleTagsAndGlobalManagementAndRetainsFailedInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tag-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        _ = try MeetingNoteTodoBridge(vault: vault).saveNotes("- [ ] Note #work", at: "Meetings/test/my-notes.md", expectedNotesVersion: nil)
        let item = try XCTUnwrap(TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().first)
        let store = ItemTagStore(vault: vault)
        let editor = ItemTagEditorView(selection: try store.selection(itemID: item.id), editable: true) { mutation, completion in
            completion(Result { try store.mutate(mutation); return try store.selection(itemID: item.id) })
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = editor
        func control<T: NSView>(_ id: String, _: T.Type) throws -> T {
            func find(_ view: NSView) -> T? {
                if view.accessibilityIdentifier() == id { return view as? T }
                return view.subviews.compactMap(find).first
            }
            return try XCTUnwrap(find(editor), id)
        }
        let name = try control("tag-name", NSTextField.self)
        name.stringValue = "bad tag"
        try control("tag-create", NSButton.self).performClick(nil)
        XCTAssertEqual(name.stringValue, "bad tag")
        XCTAssertTrue(try control("tag-feedback", NSTextField.self).stringValue.contains("not saved"))
        name.stringValue = "team"
        window.makeFirstResponder(name)
        try control("tag-create", NSButton.self).performClick(nil)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate as? NSTextField === name)
        let popup = try control("tag-catalog", NSPopUpButton.self)
        popup.selectItem(withTitle: "team"); popup.sendAction(popup.action, to: popup.target)
        try control("tag-add", NSButton.self).performClick(nil)
        XCTAssertEqual(try store.selection(itemID: item.id).tags, ["work", "team"])
        popup.selectItem(withTitle: "work")
        name.stringValue = "bad tag"
        try control("tag-rename", NSButton.self).performClick(nil)
        XCTAssertEqual(popup.titleOfSelectedItem, "work")
        XCTAssertEqual(name.stringValue, "bad tag")
        popup.selectItem(withTitle: "team")
        name.stringValue = "group"
        try control("tag-rename", NSButton.self).performClick(nil)
        XCTAssertEqual(Set(try store.selection(itemID: item.id).tags), ["work", "group"])
        try control("tag-delete", NSButton.self).performClick(nil)
        XCTAssertEqual(try store.selection(itemID: item.id).tags, ["work"])
        try control("tag-remove-work", NSButton.self).performClick(nil)
        XCTAssertTrue(try store.selection(itemID: item.id).tags.isEmpty)
        popup.selectItem(withTitle: "work"); popup.sendAction(popup.action, to: popup.target)
        try control("tag-add", NSButton.self).performClick(nil)
        XCTAssertEqual(try store.selection(itemID: item.id).tags, ["work"])
    }
    @MainActor
    func testEditorDisablesMutationsWhileSavingAndForReadOnlyItems() throws {
        let selection = ItemTagSelection(itemID: "id", tags: ["work", "ai-gen", "need-approve"], catalog: ["work"])
        var complete: ((Result<ItemTagSelection, Error>) -> Void)?
        let editor = ItemTagEditorView(selection: selection, editable: true) { _, callback in complete = callback }
        func find<T: NSView>(_ id: String, in view: NSView, _: T.Type) throws -> T {
            if view.accessibilityIdentifier() == id, let result = view as? T { return result }
            for child in view.subviews { if let result = try? find(id, in: child, T.self) { return result } }
            throw NSError(domain: id, code: 1)
        }
        let remove = try find("tag-remove-work", in: editor, NSButton.self)
        remove.performClick(nil)
        XCTAssertFalse(remove.isEnabled)
        XCTAssertFalse(try find("tag-create", in: editor, NSButton.self).isEnabled)
        XCTAssertNil(try? find("tag-remove-ai-gen", in: editor, NSButton.self))
        try XCTUnwrap(complete)(.success(.init(itemID: "id", tags: ["ai-gen", "need-approve"], catalog: ["work"])))
        XCTAssertTrue(try find("tag-add", in: editor, NSButton.self).isEnabled)
        let readOnly = ItemTagEditorView(selection: .init(itemID: "id", tags: selection.tags, catalog: selection.catalog, isEditable: false), editable: true) { _, _ in XCTFail("Read-only mutation") }
        XCTAssertFalse(try find("tag-create", in: readOnly, NSButton.self).isEnabled)
        XCTAssertFalse(try find("tag-remove-work", in: readOnly, NSButton.self).isEnabled)
        let empty = ItemTagEditorView(selection: .init(itemID: "id", tags: [], catalog: []), editable: true) { _, _ in XCTFail("Empty selection") }
        XCTAssertFalse(try find("tag-add", in: empty, NSButton.self).isEnabled)
        XCTAssertFalse(try find("tag-delete", in: empty, NSButton.self).isEnabled)
        XCTAssertFalse(try find("tag-rename", in: empty, NSButton.self).isEnabled)
        XCTAssertTrue(try find("tag-create", in: empty, NSButton.self).isEnabled)
    }

}
