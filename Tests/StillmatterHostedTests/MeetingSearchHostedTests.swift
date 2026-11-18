import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingSearchHostedTests: XCTestCase {
    @MainActor
    func testSearchKeyboardDismissalTodoRouteAndArchiveSessionState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-keyboard-migration-\(UUID().uuidString)")
        let suite = "works.stillmatter.search-keyboard.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let file = workspace.appendingPathComponent("Todos/todo.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "## Queue\n- [ ] Search target\n".write(to: file, atomically: true, encoding: .utf8)
        let index = try SearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"), workspaceRootURL: workspace)
        let settings = SettingsStore(userDefaults: defaults)
        settings.settings.stillmatterRootURL = workspace
        let state = ShellStateStore(state: ShellState(selectedTab: .meetings))
        let installer = TranscriptionComponentInstaller(paths: .init(applicationSupportURL: root.appendingPathComponent("support")), acquirer: SearchNoAcquirer())
        func shell() -> ShellViewController {
            ShellViewController(stateStore: state, settingsStore: settings, tasksInbox: nil,
                searchIndexProvider: { index }, captureServiceProvider: { nil }, teamsDetectionProvider: { nil },
                teamsRecordingDiagnosticProvider: { "" }, onManualCapture: {}, jobRecordsProvider: { [] }, jobStatusProvider: { "Idle" },
                transcriptionComponentInstaller: installer, onRebuildIndex: { $0(.success(())) })
        }
        let controller = shell()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.contentViewController = nil; window.orderOut(nil) }
        controller.searchRunner = { _, _, _ in [
            .init(kind: .todo, sourcePath: "Todos/todo.md", title: "Search target", body: "Search target"),
            .init(kind: .todo, sourcePath: "Todos/todo.md", title: "Second result", body: "Second result")
        ] }
        controller.navigationButtons[.today]?.performClick(nil)
        XCTAssertEqual(state.state.selectedTab, .today)
        controller.focusAreaSearch(nil)
        XCTAssertTrue(controller.searchControlHasFocus(controller.searchField))
        state.state.searchText = "Search target"
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in
            controller.searchResultsView.tableView.numberOfRows == 2
        }, evaluatedWith: controller)], timeout: 5)
        controller.searchKindPopup.selectItem(withTitle: "Todo Item")
        XCTAssertTrue(controller.searchKindPopup.sendAction(controller.searchKindPopup.action, to: controller.searchKindPopup.target))
        XCTAssertEqual(state.state.searchText, "Search target")
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in
            !controller.searchResultsView.isHidden && controller.searchResultsView.renderedState == "results"
        }, evaluatedWith: controller)], timeout: 5)
        XCTAssertTrue(controller.control(controller.searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))))
        let table = controller.searchResultsView.tableView
        XCTAssertEqual(table.selectedRow, 0)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        table.keyDown(with: escape)
        XCTAssertFalse(controller.isSearchPresented)
        XCTAssertEqual(state.state.searchText, "Search target")
        controller.focusAreaSearch(nil)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in !controller.searchResultsView.isHidden && table.numberOfRows == 2 }, evaluatedWith: controller)], timeout: 5)
        XCTAssertTrue(controller.searchResultsView.focusResults())
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        table.keyDown(with: enter)
        XCTAssertEqual(state.state.selectedTab, .tasks)
        XCTAssertFalse(controller.isSearchPresented)
        XCTAssertEqual(state.state.searchText, "Search target")
        let archive = NSMenuItem(title: "Include Archived in Search", action: #selector(ShellViewController.toggleArchivedSearch(_:)), keyEquivalent: "")
        controller.toggleArchivedSearch(nil)
        XCTAssertTrue(controller.validateMenuItem(archive))
        XCTAssertEqual(archive.state, .on)
        let reopened = shell()
        window.contentViewController = reopened
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(reopened.validateMenuItem(archive))
        XCTAssertEqual(archive.state, .off, "Archive opt-in is session-local")
    }

    @MainActor
    func testSlowOldQueryAndWorkspaceCannotReplaceNewResultsAndErrorsRemainVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-hosted-\(UUID().uuidString)")
        let suite = "works.stillmatter.search-hosted.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let index = try SearchIndex(databaseURL: root.appendingPathComponent("search.sqlite"), workspaceRootURL: workspace)
        let settings = SettingsStore(userDefaults: defaults)
        settings.settings.stillmatterRootURL = workspace
        let state = ShellStateStore(state: ShellState(selectedTab: .meetings))
        let installer = TranscriptionComponentInstaller(paths: .init(applicationSupportURL: root.appendingPathComponent("support")), acquirer: SearchNoAcquirer())
        let shell = ShellViewController(stateStore: state, settingsStore: settings, tasksInbox: nil,
            searchIndexProvider: { index }, captureServiceProvider: { nil }, teamsDetectionProvider: { nil },
            teamsRecordingDiagnosticProvider: { "" }, onManualCapture: {}, jobRecordsProvider: { [] }, jobStatusProvider: { "Idle" },
            transcriptionComponentInstaller: installer, onRebuildIndex: { $0(.success(())) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = shell
        defer { window.contentViewController = nil; window.orderOut(nil) }
        let archiveMenu = NSMenuItem(title: "Include Archived in Search", action: #selector(ShellViewController.toggleArchivedSearch(_:)), keyEquivalent: "")
        XCTAssertTrue(shell.validateMenuItem(archiveMenu))
        XCTAssertEqual(archiveMenu.state, .off)
        shell.toggleArchivedSearch(nil)
        XCTAssertTrue(shell.validateMenuItem(archiveMenu))
        XCTAssertEqual(archiveMenu.state, .on)
        state.state.select(.settings)
        XCTAssertFalse(shell.validateMenuItem(archiveMenu))
        state.state.select(.meetings)
        let started = expectation(description: "Old query started")
        let released = expectation(description: "Old query released")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        shell.searchRunner = { _, query, _ in
            if query == "old" {
                started.fulfill(); gate.wait(); released.fulfill()
                return [.init(kind: .summary, sourcePath: "Meetings/old/summary.md", title: "OLD", body: "private old workspace")]
            }
            if query == "error" { throw NSError(domain: "Fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Controlled failure"]) }
            return [.init(kind: .summary, sourcePath: "Meetings/new/summary.md", title: "NEW", body: "current workspace")]
        }
        shell.isSearchPresented = true
        state.state.searchText = "old"
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(shell.searchResultsView.renderedState, "loading")
        state.state.searchText = "new"
        shell.receive(.workspace)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in shell.searchResultsView.resultTitlesForValidation == ["NEW"] }, evaluatedWith: shell)], timeout: 5)
        gate.signal()
        await fulfillment(of: [released], timeout: 5)
        // Drain the main queue after old completion, then assert its observable result.
        await Task.yield()
        XCTAssertEqual(shell.searchResultsView.resultTitlesForValidation, ["NEW"])
        state.state.searchText = "error"
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in shell.searchResultsView.renderedState == "failed" }, evaluatedWith: shell)], timeout: 5)
        XCTAssertEqual(state.state.searchText, "error")
    }

    @MainActor
    func testRepeatedSearchResultsOpenTheirOwningMeetingTabs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-routes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace"), support = root.appendingPathComponent("support")
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support)
        let path = "Meetings/call/meeting.md"
        _ = try vault.writeMarkdown(Data("---\ntitle: Search target\ncapture_session_id: call\n---\n# Search target\n".utf8), relativePath: path, expectedVersion: nil)
        let transcript: [String: Any] = ["schema_version": 1, "capture_session_id": "call",
            "meeting_relative_path": path, "language": "en", "detected_languages": ["en"],
            "engine": "fixture", "model": "fixture", "generated_at": "2026-01-01T00:00:00Z", "audio_sources": [], "diagnostics": [],
            "segments": [["id": "overlap-first", "start": 12, "end": 14, "text": "Earlier wording", "language": "en", "track": "system-audio", "speaker": "Guest"],
                         ["id": "overlap-target", "start": 12, "end": 14, "text": "Target wording", "language": "en", "track": "microphone", "speaker": "Me"]]]
        _ = try vault.writeMarkdown(JSONSerialization.data(withJSONObject: transcript), relativePath: "Meetings/call/transcript.json", expectedVersion: nil)
        func service() -> MeetingManagementService { MeetingManagementService(vault: vault) }
        XCTAssertEqual(try service().detail(for: path).transcript.count, 2)
        XCTAssertEqual(try service().detail(for: path).transcript.count, 2)
        let read = MeetingReadModel(workspaceID: workspace.path, sourceFactory: { MeetingManagementReadSource(serviceProvider: service) })
        var currentRead = read
        let view = MeetingManagementView(readModelProvider: { currentRead }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        defer { view.refresh(isVisible: false); read.stop() }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail != nil }, evaluatedWith: view)], timeout: 10)
        guard view.displayedDetail != nil else {
            return XCTFail("Browser: \(view.meetingsModel.loadState), detail: \(view.meetingsModel.detail.loadState), status: \(view.status.stringValue)")
        }
        let cases: [(String, MeetingDetailPage)] = [("my-notes.md", .notes), ("action-items.md", .actionItems),
            ("open-items.md", .openItems), ("summary.md", .summary), ("transcript.json", .transcript)]
        for (filename, page) in cases {
            view.focusSearchResult(SearchResult(kind: .markdown, sourcePath: "Meetings/call/" + filename, title: "Source", body: "Match"))
            await fulfillment(of: [expectation(for: NSPredicate { _, _ in
                view.displayedDetail?.row.meetingRelativePath == path && view.meetingsModel.detail.page == page
            }, evaluatedWith: view)], timeout: 5)
        }
        view.focusSearchResult(SearchResult(kind: .transcript, sourcePath: "Meetings/call/transcript.json",
            title: "Transcript", body: "Target wording", transcriptStartSeconds: 12, transcriptEndSeconds: 14))
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.timelineNavigation.jump?.segmentID == "overlap-target" }, evaluatedWith: view)], timeout: 5)
        view.focusSearchResult(SearchResult(kind: .transcript, sourcePath: "Meetings/call/transcript.json",
            title: "Removed utterance", body: "Removed wording", transcriptStartSeconds: 12, transcriptEndSeconds: 14))
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.status.stringValue.contains("utterance changed") }, evaluatedWith: view)], timeout: 5)
        XCTAssertNil(view.timelineNavigation.jump)
        view.focusSearchResult(SearchResult(kind: .markdown, sourcePath: "Meetings/missing/my-notes.md", title: "Missing", body: "Old hit"))
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.status.stringValue.contains("no longer available") }, evaluatedWith: view)], timeout: 5)
        view.refresh(isVisible: false)
        _ = try vault.writeMarkdown(Data("---\ntitle: Later meeting\ncapture_session_id: missing\n---\n# Later meeting\n".utf8), relativePath: "Meetings/missing/meeting.md", expectedVersion: nil)
        read.invalidate(.rescanRequired(reason: "A different Meeting appears after failed navigation"))
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.meetingsModel.availableRows.count == 2 }, evaluatedWith: view)], timeout: 5)
        XCTAssertEqual(view.displayedDetail?.row.meetingRelativePath, path)
        XCTAssertNotEqual(view.meetingsModel.detail.page, .notes)
        view.refresh(isVisible: false)
        view.refresh(isVisible: true)
        view.focusSearchResult(SearchResult(kind: .markdown, sourcePath: "Meetings/missing/my-notes.md", title: "Second Meeting", body: "Match"))
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in
            view.displayedDetail?.row.meetingRelativePath == "Meetings/missing/meeting.md" && view.meetingsModel.detail.page == .notes
        }, evaluatedWith: view)], timeout: 5)
        let otherVault = WorkspaceVault(workspaceRootURL: root.appendingPathComponent("other-workspace"), appSupportRootURL: root.appendingPathComponent("other-support"))
        _ = try otherVault.writeMarkdown(Data("---\ntitle: Other workspace\ncapture_session_id: call\n---\n# Other workspace\n".utf8), relativePath: path, expectedVersion: nil)
        let otherRead = MeetingReadModel(workspaceID: "other", sourceFactory: { MeetingManagementReadSource(serviceProvider: { MeetingManagementService(vault: otherVault) }) })
        defer { otherRead.stop() }
        view.focusSearchResult(SearchResult(kind: .markdown, sourcePath: "Meetings/call/my-notes.md", title: "Old workspace", body: "Old hit"))
        currentRead = otherRead
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail?.row.title == "Other workspace" }, evaluatedWith: view)], timeout: 5)
        XCTAssertEqual(view.meetingsModel.detail.page, .summary, "A same-path Meeting in a new workspace must not consume the old route")
    }

    @MainActor
    func testCanonicalTextRefreshPublishesConflictsAndRepairsWithoutOpeningMeeting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-text-monitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: root.appendingPathComponent("support"))
        _ = try vault.writeMarkdown(Data("---\ntitle: Text fixture\ncapture_session_id: call\n---\n# Text fixture\n".utf8), relativePath: "Meetings/call/meeting.md", expectedVersion: nil)
        let document: [String: Any] = ["schema_version": 1, "capture_session_id": "call", "meeting_relative_path": "Meetings/call/meeting.md",
            "language": "en", "detected_languages": ["en"], "engine": "fixture", "model": "fixture", "generated_at": "2026-01-01T00:00:00Z",
            "audio_sources": [], "diagnostics": [], "segments": [["id": "one", "start": 12, "end": 14, "language": "en", "track": "microphone", "speaker": "Me", "text": "OriginalTextNeedle"]]]
        _ = try vault.writeMarkdown(JSONSerialization.data(withJSONObject: document), relativePath: "Meetings/call/transcript.json", expectedVersion: nil)
        _ = try MeetingManagementService(vault: vault).detail(for: "Meetings/call/meeting.md")
        let textURL = workspace.appendingPathComponent("Meetings/call/transcript.txt")
        let jsonURL = workspace.appendingPathComponent("Meetings/call/transcript.json")
        let originalJSON = try Data(contentsOf: jsonURL)
        let edited = try String(contentsOf: textURL).replacingOccurrences(of: "OriginalTextNeedle", with: "EditedTextNeedle")
        var publications = 0
        let runtime = SearchIndexRuntime(databaseURL: root.appendingPathComponent("search.sqlite")) { index, _ in if index != nil { publications += 1 } }
        defer { runtime.stop() }
        var settings = AppSettings(); settings.stillmatterRootURL = workspace
        runtime.configure(settings)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in runtime.index != nil }, evaluatedWith: runtime)], timeout: 10)
        try edited.write(to: textURL, atomically: true, encoding: .utf8)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in (try? runtime.index?.search("EditedTextNeedle").count) == 1 }, evaluatedWith: runtime)], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: jsonURL), originalJSON)
        let beforeFailure = publications
        try "broken text".write(to: textURL, atomically: true, encoding: .utf8)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in
            guard publications > beforeFailure, let index = runtime.index else { return false }
            do { _ = try index.search("EditedTextNeedle"); return false } catch { return true }
        }, evaluatedWith: runtime)], timeout: 10)
        try edited.write(to: textURL, atomically: true, encoding: .utf8)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in (try? runtime.index?.search("EditedTextNeedle").count) == 1 }, evaluatedWith: runtime)], timeout: 10)
        XCTAssertEqual(try Data(contentsOf: jsonURL), originalJSON)
    }

    @MainActor
    func testFilesystemRuntimePublishesFreshEditsRemovalAndProviderAfterRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("search-monitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace"), file = workspace.appendingPathComponent("Meetings/call/summary.md")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "# Summary\n\nOriginal marker".write(to: file, atomically: true, encoding: .utf8)
        var publications = 0
        let runtime = SearchIndexRuntime(databaseURL: root.appendingPathComponent("search.sqlite"), semanticSearch: SearchLocalScores()) { index, _ in
            if index != nil { publications += 1 }
        }
        defer { runtime.stop() }
        var settings = AppSettings(); settings.stillmatterRootURL = workspace
        runtime.configure(settings)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in runtime.index != nil }, evaluatedWith: runtime)], timeout: 10)
        XCTAssertEqual(try runtime.index?.retrieve("paraphrase").results.count, 1)
        try "# Summary\n\nReplacement marker".write(to: file, atomically: true, encoding: .utf8)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in
            publications > 1 && (try? runtime.index?.search("Replacement").count) == 1
        }, evaluatedWith: runtime)], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(runtime.index).search("Original").isEmpty)
        try FileManager.default.removeItem(at: file)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in
            (try? runtime.index?.search("Replacement").isEmpty) == true
        }, evaluatedWith: runtime)], timeout: 10)
        let recovered = expectation(description: "Recovered index")
        runtime.recover(settings) { result in
            if case let .failure(error) = result { XCTFail(error.localizedDescription) }
            recovered.fulfill()
        }
        await fulfillment(of: [recovered], timeout: 10)
        try "# Summary\n\nRecovered text".write(to: file, atomically: true, encoding: .utf8)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in (try? runtime.index?.search("Recovered").count) == 1 }, evaluatedWith: runtime)], timeout: 10)
        XCTAssertEqual(try runtime.index?.retrieve("paraphrase").results.count, 1)
        let outside = root.appendingPathComponent("outside.md")
        try "# Private\n\nOutsidePrivateNeedle".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in (try? runtime.index?.search("Recovered").isEmpty) == true }, evaluatedWith: runtime)], timeout: 10)
        XCTAssertTrue(try XCTUnwrap(runtime.index).search("OutsidePrivateNeedle").isEmpty)
    }
}

private struct SearchLocalScores: LocalSemanticSearching {
    func similarities(query: String, passages: [String]) throws -> [Double] { passages.map { _ in 0.8 } }
}

private struct SearchNoAcquirer: TranscriptionModelAcquiring {
    func acquireModel(_ model: TranscriptionModelChoice, in stagingURL: URL, cancellation: TranscriptionInstallCancellation, progress: @escaping (TranscriptionInstallProgress) -> Void) throws -> URL {
        XCTFail("Search tests must never install a transcription model")
        throw NSError(domain: "Unexpected installation", code: 1)
    }
}
