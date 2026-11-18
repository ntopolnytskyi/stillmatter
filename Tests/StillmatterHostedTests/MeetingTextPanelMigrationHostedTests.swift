import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

/// Regression seams migrated from native UI permutations. Uses real views, services and Markdown.
final class MeetingTextPanelMigrationHostedTests: XCTestCase {
    @MainActor
    func testPanelFocusKeyboardConflictReloadAndLongText() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 650),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let panel = MeetingTextEditPanel()
        defer { panel.finish(); window.orderOut(nil) }
        var changed = "", saved = "", cancellations = 0, reloads = 0
        panel.present(over: window, field: "My notes", meeting: "Fixture", text: "",
                      onChange: { changed = $0 }, onSave: { saved = $0 },
                      onCancel: { cancellations += 1; panel.finish() }, onReload: { reloads += 1 })
        let sheet = try XCTUnwrap(window.attachedSheet)
        let editor: NSTextView = try control("meeting-text-editor", in: XCTUnwrap(sheet.contentView))
        XCTAssertTrue(sheet.firstResponder === editor)
        let longText = String(repeating: "Readable Unicode notes — 計画\n", count: 300)
        editor.string = longText
        NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
        XCTAssertEqual(changed, longText)
        XCTAssertTrue(editor.enclosingScrollView?.hasVerticalScroller == true)
        panel.setSaving(true)
        XCTAssertFalse(editor.isEditable)
        let save: NSButton = try control("meeting-text-save", in: XCTUnwrap(sheet.contentView))
        XCTAssertFalse(save.isEnabled)
        panel.showError("my-notes.md changed; draft preserved", conflict: true)
        XCTAssertEqual(panel.text, longText)
        XCTAssertTrue(editor.isEditable)
        let reload: NSButton = try control("meeting-text-reload", in: XCTUnwrap(sheet.contentView))
        XCTAssertFalse(reload.isHidden)
        reload.performClick(nil)
        XCTAssertEqual(reloads, 1)
        panel.showLatest("External notes")
        XCTAssertEqual(panel.text, "External notes")
        XCTAssertTrue(reload.isHidden)
        XCTAssertTrue(sheet.firstResponder === editor)
        XCTAssertTrue(save.toolTip?.contains("Command-Return") == true)
        XCTAssertEqual(save.keyEquivalentModifierMask, [.command])
        save.performClick(nil)
        XCTAssertEqual(saved, "External notes")
        let cancel: NSButton = try control("meeting-text-cancel", in: XCTUnwrap(sheet.contentView))
        XCTAssertEqual(cancel.keyEquivalent, "\u{1b}")
        cancel.performClick(nil)
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(panel.isOpen)
    }

    @MainActor
    func testSummarySaveDoesNotWriteNotes() async throws {
        try await withMeeting { view, window, vault, _ in
            let notes = try vault.readMarkdown(relativePath: "Meetings/panel/my-notes.md").data
            let doorway = try vault.readMarkdown(relativePath: "Meetings/panel/meeting.md").data
            let summary = try self.summarySection(in: view)
            XCTAssertTrue(summary.rootView.canEdit)
            summary.rootView.edit()
            let content = try XCTUnwrap(window.attachedSheet?.contentView)
            let editor: NSTextView = try self.control("meeting-text-editor", in: content)
            editor.string = "Summary saved independently"
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
            let save: NSButton = try self.control("meeting-text-save", in: content)
            XCTAssertEqual(save.keyEquivalentModifierMask, [.command])
            save.performClick(nil)
            await self.until { !view.textEditPanel.isOpen }
            XCTAssertTrue(try self.markdown(vault, "Meetings/panel/summary.md").contains("Summary saved independently"))
            XCTAssertEqual(try vault.readMarkdown(relativePath: "Meetings/panel/my-notes.md").data, notes)
            XCTAssertEqual(try vault.readMarkdown(relativePath: "Meetings/panel/meeting.md").data, doorway)
        }
    }

    @MainActor
    func testCleanNotesEditorFollowsExternalChanges() async throws {
        try await withMeeting { view, _, vault, _ in
            view.editNotesTool.performClick(nil)
            try self.write("Clean external update", to: vault)
            view.meetingsModel.detail.refreshSelectedDetail()
            await self.until { view.textEditPanel.text == "Clean external update" }
            XCTAssertTrue(view.textEditPanel.isOpen)
            XCTAssertEqual(try self.markdown(vault, "Meetings/panel/my-notes.md"), "Clean external update")
        }
    }

    @MainActor
    func testDirtyNotesConflictCancelReloadAndRepair() async throws {
        try await withMeeting { view, window, vault, _ in
            view.editNotesTool.performClick(nil)
            func content() throws -> NSView { try XCTUnwrap(window.attachedSheet?.contentView) }
            let editor: NSTextView = try self.control("meeting-text-editor", in: content())
            editor.string = "Local unsaved draft"
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: editor)
            try self.write("External canonical notes", to: vault)
            view.meetingsModel.detail.refreshSelectedDetail()
            await self.until { view.displayedDetail?.humanNotes == "External canonical notes" }
            XCTAssertEqual(view.textEditPanel.text, "Local unsaved draft")
            let save: NSButton = try self.control("meeting-text-save", in: content())
            save.performClick(nil)
            await self.until { !view.meetingsModel.detail.isMutationInFlight }
            XCTAssertEqual(try self.markdown(vault, "Meetings/panel/my-notes.md"), "External canonical notes")
            let reload: NSButton = try self.control("meeting-text-reload", in: content())
            XCTAssertFalse(reload.isHidden)
            let cancel: NSButton = try self.control("meeting-text-cancel", in: content())
            cancel.performClick(nil)
            view.editNotesTool.performClick(nil)
            XCTAssertEqual(view.textEditPanel.text, "External canonical notes")
            let reopened: NSTextView = try self.control("meeting-text-editor", in: content())
            reopened.string = "Second draft"
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: reopened)
            let file = vault.rootURL.appendingPathComponent("Meetings/panel/my-notes.md")
            try Data([0xFF, 0xFE]).write(to: file)
            view.meetingsModel.detail.refreshSelectedDetail()
            let feedback: NSTextField = try self.control("meeting-text-error", in: content())
            await self.until { !feedback.isHidden }
            XCTAssertTrue(feedback.stringValue.contains("my-notes.md"))
            XCTAssertEqual(view.textEditPanel.text, "Second draft")
            XCTAssertEqual(try Data(contentsOf: file), Data([0xFF, 0xFE]))
            try "Repaired canonical notes".write(to: file, atomically: true, encoding: .utf8)
            let repairedReload: NSButton = try self.control("meeting-text-reload", in: content())
            repairedReload.performClick(nil)
            await self.until { view.textEditPanel.text == "Repaired canonical notes" }
            let repairedEditor: NSTextView = try self.control("meeting-text-editor", in: content())
            repairedEditor.string = "Saved after explicit reload"
            NotificationCenter.default.post(name: NSText.didChangeNotification, object: repairedEditor)
            let repairedSave: NSButton = try self.control("meeting-text-save", in: content())
            repairedSave.performClick(nil)
            await self.until { !view.textEditPanel.isOpen }
            XCTAssertTrue(try String(contentsOf: file).contains("Saved after explicit reload"))
        }
    }

    @MainActor
    func testMeetingPagesAndArchivedTools() async throws {
        try await withMeeting { view, _, vault, read in
            XCTAssertEqual(view.pageSelector.segmentCount, 5)
            XCTAssertTrue(view.editNotesTool.isEnabled)
            let summary = try self.summarySection(in: view)
            XCTAssertTrue(summary.rootView.canEdit)
            _ = try vault.writeMarkdown(Data("{\"archived\":true}".utf8), relativePath: "Meetings/panel/archive.json", expectedVersion: nil)
            read.invalidate(.rescanRequired(reason: "External archive marker written by fixture"))
            view.archiveFilter.selectItem(at: 1)
            view.filtersChanged(nil)
            view.meetingsModel.detail.refreshSelectedDetail()
            await self.until { view.displayedDetail?.row.isArchived == true && !view.editNotesTool.isEnabled }
            XCTAssertFalse(view.editNotesTool.isEnabled)
            XCTAssertFalse(view.editSummaryTool.isEnabled)
            XCTAssertFalse(try self.summarySection(in: view).rootView.canEdit)
            view.editNotesTool.performClick(nil)
            XCTAssertFalse(view.textEditPanel.isOpen)
            XCTAssertTrue(try self.markdown(vault, "Meetings/panel/my-notes.md").contains("Original notes"))
        }
    }

    @MainActor
    private func withMeeting(_ body: (MeetingManagementView, NSWindow, WorkspaceVault, MeetingReadModel) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("panel-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let vault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("workspace"), appSupportRootURL: root.appendingPathComponent("support"))
        let path = "Meetings/panel/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Panel fixture\ncapture_session_id: panel\n---\n# Panel fixture\n".utf8), relativePath: path, expectedVersion: nil)
        let service = MeetingManagementService(vault: vault)
        _ = try service.detail(for: path)
        try write("Original notes", to: vault)
        let summaryPath = "Meetings/panel/summary.md"
        _ = try vault.writeMarkdown(Data("# Summary\n\nOriginal summary\n".utf8), relativePath: summaryPath, expectedVersion: vault.readMarkdown(relativePath: summaryPath).version)
        let read = MeetingReadModel(workspaceID: root.path, sourceFactory: { MeetingManagementReadSource(serviceProvider: { service }) })
        let executor = MeetingMutationExecutor(searchIndex: nil, captureSnapshot: nil, serviceFactory: { _, _ in service })
        let view = MeetingManagementView(readModelProvider: { read }, mutationExecutorProvider: { executor },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.textEditPanel.finish(); view.refresh(isVisible: false); read.stop(); window.orderOut(nil) }
        view.refresh(isVisible: true)
        await until { view.displayedDetail != nil && view.editNotesTool.isEnabled }
        try await body(view, window, vault, read)
    }

    @MainActor
    private func until(_ predicate: @escaping () -> Bool) async {
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in predicate() }, evaluatedWith: nil)], timeout: 10)
    }

    private func markdown(_ vault: WorkspaceVault, _ path: String) throws -> String {
        String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self)
    }

    private func write(_ text: String, to vault: WorkspaceVault) throws {
        let path = "Meetings/panel/my-notes.md"
        let version = try vault.readMarkdown(relativePath: path).version
        _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path, expectedVersion: version)
    }

    @MainActor
    private func summarySection(in view: NSView) throws -> MeetingOverviewHostingView {
        if let section = view as? MeetingOverviewHostingView, section.rootView.title == "Summary" { return section }
        for child in view.subviews { if let section = try? summarySection(in: child) { return section } }
        throw NSError(domain: "Missing Summary section", code: 1)
    }

    @MainActor
    private func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
        if view.accessibilityIdentifier() == identifier, let result = view as? T { return result }
        for child in view.subviews { if let result: T = try? control(identifier, in: child) { return result } }
        throw NSError(domain: "Missing migration control: \(identifier)", code: 1)
    }
}
