import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class MeetingSearchHostedTests: XCTestCase {
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
