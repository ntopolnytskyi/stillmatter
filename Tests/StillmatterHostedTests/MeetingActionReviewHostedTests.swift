import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingActionReviewHostedTests: XCTestCase {
    @MainActor
    func testControlsPersistOwnerDueStatusAndApprovalAndRetainFailedDraft() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-review-hosted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/test/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Test\ncapture_session_id: test\n---\n## Notes\n- [ ] Note task\n".utf8), relativePath: path, expectedVersion: nil)
        let extraction = MeetingSummaryExtraction(meeting: path, transcript: "Meetings/test/transcript.json", decisions: [],
            myActionItems: [.init(id: "first", text: "My task #ai-gen #need-approve", citations: []), .init(id: "second", text: "Second task", citations: [])],
            otherActionItems: [.init(id: "unknown", text: "Unknown task", citations: []), .init(id: "rejected", text: "Reject this", citations: [])], openQuestions: [])
        _ = try vault.writeMarkdown(JSONEncoder().encode(extraction), relativePath: "Meetings/test/summary-extraction.json", expectedVersion: nil)
        let service = MeetingManagementService(vault: vault)
        let view = MeetingActionReviewView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 1200), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        func configure(editable: Bool = true, id: String = "test") throws {
            let detail = try service.detail(for: path)
            view.configure(meetingID: id, items: detail.reviewItems, editable: editable,
                review: { items, accept, completion in
                    let result = Result { _ = try service.reviewMeetingItems(meetingID: path, items: items, accept: accept) }
                    if case .success = result { try? configure() }
                    completion(result)
                }, save: { item, draft, completion in
                    let result = Result { _ = try service.editMeetingItem(meetingID: path, item: item, text: draft.text, owner: draft.owner, dueDate: draft.due.isEmpty ? nil : draft.due, status: draft.status) }
                    if case .success = result { try? configure() }
                    completion(result)
                }, sources: { _, _ in })
        }
        func element<T: NSView>(_ id: String, _: T.Type) throws -> T {
            func walk(_ current: NSView) -> T? {
                if current.accessibilityIdentifier() == id { return current as? T }
                return current.subviews.compactMap(walk).first
            }
            return try XCTUnwrap(walk(view), id)
        }
        try configure()
        let unknown = try XCTUnwrap(service.detail(for: path).reviewItems.first { !$0.hasOwner })
        let rejected = try XCTUnwrap(service.detail(for: path).reviewItems.last { !$0.hasOwner })
        try element("meeting-item-reject-" + rejected.id, NSButton.self).performClick(nil)
        XCTAssertEqual(try service.detail(for: path).reviewItems.first { $0.id == rejected.id }?.review, "rejected")
        let personal = try XCTUnwrap(service.detail(for: path).reviewItems.first { $0.isPending && $0.owner == "me" })
        let acceptPersonal = try element("meeting-item-accept-" + personal.id, NSButton.self)
        window.makeFirstResponder(acceptPersonal)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        acceptPersonal.keyDown(with: enter)
        XCTAssertEqual(try service.detail(for: path).reviewItems.first { $0.id == personal.id }?.review, "approved")

        XCTAssertFalse(try element("meeting-item-accept-" + unknown.id, NSButton.self).isEnabled)
        XCTAssertFalse(try element("meeting-actions-accept-others", NSButton.self).isEnabled)
        let owner = try element("meeting-item-owner-" + unknown.id, NSTextField.self)
        owner.stringValue = "Alice"; view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: owner))
        let due = try element("meeting-item-due-" + unknown.id, NSTextField.self)
        due.stringValue = "2026-02-30"
        window.makeFirstResponder(due)
        try element("meeting-item-save-" + unknown.id, NSButton.self).performClick(nil)
        XCTAssertEqual(try element("meeting-item-owner-" + unknown.id, NSTextField.self).stringValue, "Alice")
        XCTAssertTrue(try element("meeting-actions-feedback", NSTextField.self).stringValue.contains("Save failed"))
        let focusedDue = try element("meeting-item-due-" + unknown.id, NSTextField.self)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate as? NSTextField === focusedDue)
        let fixedDue = try element("meeting-item-due-" + unknown.id, NSTextField.self)
        fixedDue.stringValue = "2026-12-03"
        try element("meeting-item-save-" + unknown.id, NSButton.self).performClick(nil)
        XCTAssertTrue(try element("meeting-actions-accept-others", NSButton.self).isEnabled)
        try element("meeting-actions-accept-others", NSButton.self).performClick(nil)
        try element("meeting-actions-accept-mine", NSButton.self).performClick(nil)
        var item = try XCTUnwrap(service.detail(for: path).reviewItems.first { $0.id == unknown.id })
        XCTAssertEqual(item.owner, "Alice"); XCTAssertEqual(item.review, "approved")
        XCTAssertEqual(item.dueDate, "2026-12-03")
        XCTAssertFalse(try TodoItemIndex(workspaceRootURL: vault.rootURL).loadAllItems().contains { $0.id == unknown.id })
        for (index, status) in [(1, TodoStatus.blocked), (0, .open), (2, .done)] {
            let popup = try element("meeting-item-status-" + unknown.id, NSPopUpButton.self)
            popup.selectItem(at: index); popup.sendAction(popup.action, to: popup.target)
            try element("meeting-item-save-" + unknown.id, NSButton.self).performClick(nil)
            item = try XCTUnwrap(service.detail(for: path).reviewItems.first { $0.id == unknown.id })
            XCTAssertEqual(item.status, status)
        }
        XCTAssertFalse(try element("meeting-item-status-" + unknown.id, NSPopUpButton.self).isEnabled)
        let note = try XCTUnwrap(service.detail(for: path).reviewItems.first { $0.origin == "note" })
        let noteField = try element("meeting-item-text-" + note.id, NSTextField.self)
        noteField.stringValue = "My draft"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: noteField))
        _ = try service.editMeetingItem(meetingID: path, item: note, text: "External note edit", owner: "me", dueDate: nil, status: .open)
        try configure()
        try element("meeting-item-save-" + note.id, NSButton.self).performClick(nil)
        XCTAssertTrue(try element("meeting-actions-feedback", NSTextField.self).stringValue.contains("Save failed"))
        XCTAssertEqual(try element("meeting-item-text-" + note.id, NSTextField.self).stringValue, "My draft")
        XCTAssertEqual(try service.detail(for: path).reviewItems.first { $0.id == note.id }?.text, "External note edit")
        try element("meeting-item-reload-" + note.id, NSButton.self).performClick(nil)
        XCTAssertEqual(try element("meeting-item-text-" + note.id, NSTextField.self).stringValue, "External note edit")
        let save = try element("meeting-item-save-" + note.id, NSButton.self)
        let menu = try XCTUnwrap(save.superview?.menu)
        view.menuNeedsUpdate(menu)
        menu.performActionForItem(at: 0)
        XCTAssertTrue(try element("meeting-actions-feedback", NSTextField.self).stringValue.contains("Changes saved"))
        try configure(editable: false)
        XCTAssertFalse(try element("meeting-item-save-" + unknown.id, NSButton.self).isEnabled)
        try configure(id: "another")
        XCTAssertTrue(try element("meeting-item-text-" + note.id, NSTextField.self).isEnabled)
        view.configure(meetingID: "empty", items: [], editable: true, review: { _, _, _ in XCTFail("Empty batch") },
            save: { _, _, _ in XCTFail("Empty save") }, sources: { _, _ in })
        XCTAssertFalse(try element("meeting-actions-accept-mine", NSButton.self).isEnabled)
        XCTAssertFalse(try element("meeting-actions-accept-others", NSButton.self).isEnabled)
    }
}
