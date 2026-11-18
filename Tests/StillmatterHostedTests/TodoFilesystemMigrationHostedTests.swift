import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

/// Actual loaders, filesystem notifications and native controls, without GUI automation.
final class TodoFilesystemMigrationHostedTests: XCTestCase {
    @MainActor
    func testMalformedTodoRetryPreservesBytesAndRepairRecoversTodayAndTasks() async throws {
        try await withShell { shell, state, workspace in
            let queue = workspace.appendingPathComponent("Todos/todo.md")
            let malformed = Data("## Queue\n- [[item:not-a-valid-uuid|Broken]]\n".utf8)
            try FileManager.default.createDirectory(at: queue.deletingLastPathComponent(), withIntermediateDirectories: true)
            try malformed.write(to: queue)
            state.state.select(.today)
            await self.until { shell.todayWorkbenchView.lastRenderedState == "failed" }
            let todayRetry: NSButton = try self.control("today-state-action", in: shell.todayWorkbenchView)
            // Identical failures are deliberately deduplicated by the view. A presentation-only
            // sentinel makes the next real loader publication observable without changing source bytes.
            shell.todayWorkbenchView.render(.loading)
            let todayRenders = shell.todayWorkbenchView.renderCountForValidation
            todayRetry.performClick(nil)
            await self.until { shell.todayWorkbenchView.renderCountForValidation > todayRenders && shell.todayWorkbenchView.lastRenderedState == "failed" }
            XCTAssertEqual(try Data(contentsOf: queue), malformed)
            state.state.select(.tasks)
            await self.until { shell.todoLedgerView.renderedState == "failed" }
            let retry: NSButton = try self.control("tasks-state-action", in: shell.todoLedgerView)
            let rendered = shell.todoLedgerView.renderCountForValidation
            retry.performClick(nil)
            await self.until { shell.todoLedgerView.renderCountForValidation > rendered && shell.todoLedgerView.renderedState == "failed" }
            XCTAssertEqual(try Data(contentsOf: queue), malformed)
            let valid = Data("## Queue\n- [ ] Repaired canonical task\n\n## Done\n".utf8)
            try valid.write(to: queue, options: .atomic)
            retry.performClick(nil)
            await self.until { shell.todoLedgerView.visibleItems.map(\.title) == ["Repaired canonical task"] }
            state.state.select(.today)
            await self.until { shell.todayWorkbenchView.lastRenderedState == "loaded" }
            let row: NSButton = try self.control("today-todo-" + XCTUnwrap(shell.todoLedgerView.visibleItems.first).id,
                                               in: shell.todayWorkbenchView)
            XCTAssertTrue(row.accessibilityLabel()?.contains("Repaired canonical task") == true)
            XCTAssertEqual(try Data(contentsOf: queue), valid)
        }
    }

    @MainActor
    func testExternalTodoCreationAutomaticallyRefreshesOpenTasksWithoutRewriting() async throws {
        try await withShell { shell, state, workspace in
            state.state.select(.tasks)
            await self.until { shell.todoLedgerView.renderedState == "empty" }
            let monitor = WorkbenchWorkspaceChangeMonitor(root: workspace) { state.publish($0) }
            monitor.start()
            defer { monitor.stop() }
            let queue = workspace.appendingPathComponent("Todos/todo.md")
            try FileManager.default.createDirectory(at: queue.deletingLastPathComponent(), withIntermediateDirectories: true)
            let external = Data("# Todos\n\n## Queue\n- [ ] Externally created task\n".utf8)
            try external.write(to: queue, options: .atomic)
            // No receive(), refresh() or reload() call: the production filesystem monitor drives publication.
            await self.until { shell.todoLedgerView.visibleItems.map(\.title) == ["Externally created task"] }
            XCTAssertEqual(try Data(contentsOf: queue), external)
        }
    }

    @MainActor
    private func withShell(_ body: (ShellViewController, ShellStateStore, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("todo-filesystem-migration-\(UUID().uuidString)")
        let suite = "works.stillmatter.todo-filesystem.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let settings = SettingsStore(userDefaults: defaults)
        settings.settings.stillmatterRootURL = workspace
        settings.settings.calendarSourceSelection = .none
        let state = ShellStateStore(state: ShellState(selectedTab: .settings))
        let inbox = try TasksInbox(databaseURL: root.appendingPathComponent("inbox.sqlite"))
        let installer = TranscriptionComponentInstaller(paths: .init(applicationSupportURL: root.appendingPathComponent("support")), acquirer: TodoNoModelAcquirer())
        let shell = ShellViewController(stateStore: state, settingsStore: settings, tasksInbox: inbox,
            searchIndexProvider: { nil }, captureServiceProvider: { nil }, teamsDetectionProvider: { nil },
            teamsRecordingDiagnosticProvider: { "" }, onManualCapture: {}, jobRecordsProvider: { [] }, jobStatusProvider: { "Idle" },
            transcriptionComponentInstaller: installer, onRebuildIndex: { $0(.success(())) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = shell
        defer { window.contentViewController = nil; window.orderOut(nil) }
        try await body(shell, state, workspace)
    }

    @MainActor
    private func until(_ predicate: @escaping () -> Bool) async {
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in predicate() }, evaluatedWith: nil)], timeout: 10)
    }

    @MainActor
    private func control<T: NSView>(_ identifier: String, in view: NSView) throws -> T {
        if view.accessibilityIdentifier() == identifier, let result = view as? T { return result }
        for child in view.subviews { if let result: T = try? control(identifier, in: child) { return result } }
        throw NSError(domain: "Missing Todo migration control: \(identifier)", code: 1)
    }
}

private struct TodoNoModelAcquirer: TranscriptionModelAcquiring {
    func acquireModel(_ model: TranscriptionModelChoice, in stagingURL: URL, cancellation: TranscriptionInstallCancellation,
                      progress: @escaping (TranscriptionInstallProgress) -> Void) throws -> URL {
        XCTFail("Todo filesystem tests must not acquire models")
        throw CocoaError(.fileReadNoSuchFile)
    }
}
