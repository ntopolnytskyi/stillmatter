import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingOutcomeEditingHostedTests: XCTestCase {
    @MainActor
    func testNativeEditorEmptyValidationCancelConflictRetryAndReadOnlyStates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("outcome-hosted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace"), support = root.appendingPathComponent("support")
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support)
        let path = "Meetings/test/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Outcome fixture\ncapture_session_id: test\n---\n# Outcome fixture\n".utf8), relativePath: path, expectedVersion: nil)
        func service() -> MeetingManagementService { MeetingManagementService(vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support)) }
        let read = MeetingReadModel(workspaceID: "test", sourceFactory: { MeetingManagementReadSource(serviceProvider: service) })
        let executor = MeetingMutationExecutor(searchIndex: nil, captureSnapshot: nil, serviceFactory: { _, _ in service() })
        let meeting = MeetingManagementView(readModelProvider: { read }, mutationExecutorProvider: { executor }, playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 680), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = meeting
        defer { meeting.refresh(isVisible: false); read.stop(); window.orderOut(nil) }
        meeting.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in meeting.displayedDetail != nil }, evaluatedWith: meeting)], timeout: 10)
        let model = meeting.meetingsModel.detail
        func find<T: NSView>(_ identifier: String, in target: NSView) throws -> T {
            if target.accessibilityIdentifier() == identifier, let typed = target as? T { return typed }
            for child in target.subviews { if let result: T = try? find(identifier, in: child) { return result } }
            throw NSError(domain: "Missing native control", code: 1)
        }
        let addDecision: NSButton = try find("meeting-decisions-add", in: meeting)
        addDecision.performClick(nil)
        let parentText: NSTextField = try find("meeting-decisions-text", in: meeting)
        parentText.stringValue = "Preserved parent draft"
        meeting.decisionEditor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: parentText))
        window.makeFirstResponder(parentText)
        (window.firstResponder as? NSTextView)?.setSelectedRange(NSRange(location: 2, length: 4))
        let summaryPath = "Meetings/test/summary.md"
        let summarySource = try vault.readMarkdown(relativePath: summaryPath)
        _ = try vault.writeMarkdown(summarySource.data + Data("\nExternal Summary refresh\n".utf8), relativePath: summaryPath, expectedVersion: summarySource.version)
        model.refreshSelectedDetail()
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in model.detail?.summary?.summary.contains("External Summary refresh") == true }, evaluatedWith: model)], timeout: 10)
        let refreshedField: NSTextField = try find("meeting-decisions-text", in: meeting)
        XCTAssertTrue((window.firstResponder as? NSTextView)?.delegate as? NSTextField === refreshedField)
        XCTAssertEqual((window.firstResponder as? NSTextView)?.selectedRange(), NSRange(location: 2, length: 4))
        XCTAssertEqual(refreshedField.stringValue, "Preserved parent draft")
        model.cancelOutcome()
        let view = MeetingOutcomeEditorView()
        view.confirmDelete = { _ in true }
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        host.contentView = view
        defer { host.orderOut(nil) }
        func configure(_ kind: MeetingOutcomeKind = .question, detail: MeetingBrowserDetail? = nil) throws {
            view.configure(detail: try detail ?? service().detail(for: path), kind: kind, model: model, sources: { _, _ in })
        }
        func element<T: NSView>(_ id: String, _ type: T.Type) throws -> T {
            func find(_ current: NSView) -> T? {
                if current.accessibilityIdentifier() == id { return current as? T }
                return current.subviews.compactMap(find).first
            }
            return try XCTUnwrap(find(view), id)
        }
        func click(_ suffix: String) throws { try element("meeting-open-items-" + suffix, NSButton.self).performClick(nil) }
        func waitSaved(_ count: Int) async {
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in
                !model.isMutationInFlight && model.outcomeDraft == nil && ((try? MeetingOutcomeDocument.entries(in: model.detail?.summary?.openQuestions ?? "", defaultKind: .question).count) == count)
            }, evaluatedWith: model)], timeout: 10)
        }
        try configure()
        XCTAssertTrue(try element("meeting-open-items-add", NSButton.self).isEnabled)
        try click("add")
        XCTAssertTrue(model.hasDirtyDrafts)
        let text = try element("meeting-open-items-text", NSTextField.self)
        XCTAssertTrue((host.firstResponder as? NSTextView)?.delegate as? NSTextField === text)
        text.stringValue = "Open question"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: text))
        let owner = try element("meeting-open-items-owner", NSTextField.self); owner.stringValue = "Alice"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: owner))
        let type = try element("meeting-open-items-type", NSPopUpButton.self); type.selectItem(at: 1); type.sendAction(type.action, to: type.target)
        let source = try element("meeting-open-items-source", NSPopUpButton.self); source.selectItem(at: 1); source.sendAction(source.action, to: source.target)
        try click("save")
        XCTAssertFalse(try element("meeting-open-items-text", NSTextField.self).isEnabled)
        var racing = model.outcomeDraft!.entry; racing.text = "Must not replace the submitted draft"
        model.updateOutcome(racing)
        XCTAssertEqual(model.outcomeDraft?.entry.text, "Open question")
        await waitSaved(1)
        var entry = try XCTUnwrap(MeetingOutcomeDocument.entries(in: model.detail!.summary!.openQuestions, defaultKind: .question).first)
        XCTAssertEqual(entry.owner, "Alice"); XCTAssertEqual(entry.kind, .issue); XCTAssertTrue(entry.citations.isEmpty)
        try click("edit-" + entry.id)
        let local = try element("meeting-open-items-text", NSTextField.self); local.stringValue = "Local draft"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: local))
        entry.text = "External edit"
        _ = try service().saveOutcome(entry, for: path, expectedVersion: service().detail(for: path).summaryVersion!)
        model.refreshSelectedDetail()
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in model.detail?.summary?.openQuestions.contains("External edit") == true }, evaluatedWith: model)], timeout: 10)
        try configure(); try click("save")
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in
            (try? element("meeting-open-items-feedback", NSTextField.self).stringValue.contains("Save failed")) == true
        }, evaluatedWith: view)], timeout: 10)
        XCTAssertEqual(try element("meeting-open-items-text", NSTextField.self).stringValue, "Local draft")
        XCTAssertTrue(try service().detail(for: path).summary!.openQuestions.contains("External edit"))
        try click("retry"); await waitSaved(1)
        XCTAssertTrue(try service().detail(for: path).summary!.openQuestions.contains("Local draft"))
        try click("edit-" + entry.id)
        try click("cancel"); XCTAssertFalse(model.hasDirtyDrafts)
        try click("edit-" + entry.id)
        XCTAssertEqual(try element("meeting-open-items-text", NSTextField.self).stringValue, "Local draft")
        let revised = try element("meeting-open-items-text", NSTextField.self); revised.stringValue = "Retried edit"
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: revised))
        model.saveDirtyDrafts { if case let .failure(error) = $0 { XCTFail(error.localizedDescription) } }
        await waitSaved(1)
        XCTAssertTrue(try service().detail(for: path).summary!.openQuestions.contains("Retried edit"))
        try click("edit-" + entry.id)
        try click("resolved"); try click("save"); await waitSaved(1)
        try click("edit-" + entry.id)
        XCTAssertFalse(try element("meeting-open-items-resolved", NSButton.self).isEnabled)
        try click("cancel")
        view.confirmDelete = { _ in false }
        try click("delete-" + entry.id)
        XCTAssertTrue(try service().detail(for: path).summary!.openQuestions.contains(entry.id))
        view.confirmDelete = { _ in true }
        try click("delete-" + entry.id); await waitSaved(0)
        try click("add")
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: host.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertTrue(view.performKeyEquivalent(with: event)); XCTAssertFalse(model.hasDirtyDrafts)
        XCTAssertFalse(view.performKeyEquivalent(with: event))
        var archived = try service().detail(for: path)
        // Real archive files are authoritative; the refreshed row controls editing.
        _ = try vault.writeMarkdown(Data("{\"archived\":true}".utf8), relativePath: "Meetings/test/archive.json", expectedVersion: nil)
        archived = try service().detail(for: path)
        try configure(detail: archived)
        XCTAssertFalse(try element("meeting-open-items-add", NSButton.self).isEnabled)
        XCTAssertThrowsError(try service().saveOutcome(MeetingOutcomeEntry(text: "Archived", kind: .question), for: path, expectedVersion: archived.summaryVersion!))
        model.select(nil)
        model.saveOutcome { if case .success = $0 { XCTFail("No selected draft") } }
    }
}
