import AppKit
import XCTest
import StillmatterCore
@testable import StillmatterHostedTestHost

/// Runs inside a signed app process, using app implementation types that SwiftPM
/// tests cannot import. No test constructs a recorder or requests OS permissions.
final class AppCompositionHostedTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-hosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "works.stillmatter.hosted.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
        defaults = nil
        root = nil
    }

    private func composition(support: String) throws -> AppComposition {
        let supportURL = root.appendingPathComponent(support)
        try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
        return AppComposition(settingsStore: SettingsStore(userDefaults: defaults),
                              applicationSupportURL: supportURL, onCaptureSnapshot: { _ in
            XCTFail("Store assembly must not start recording")
        })
    }

    func testOperationalStoresPersistAndRemainIsolatedAcrossAppCompositions() throws {
        XCTAssertNil(NSApplication.shared.delegate, "Test host must not start production AppDelegate")
        let first = try composition(support: "support-a")
        let jobs = try XCTUnwrap(first.jobStore)
        let inbox = try XCTUnwrap(first.tasksInbox)
        let workspace = root.appendingPathComponent("workspace-a")
        let scoped = try inbox.scoped(to: workspace)
        XCTAssertTrue(try scoped.queueProposal(id: "synthetic-action", title: "Review synthetic evidence", sourceRef: "[[Meetings/synthetic/summary]]"))
        let manifest = JobManifest(type: "hosted-fixture", title: "Synthetic job", executionClass: .lightweight,
                                   stages: [.init(id: "check", title: "Check")]).owned(by: workspace)
        _ = try jobs.enqueue(id: "synthetic-job", manifest: manifest)

        let reopened = try composition(support: "support-a")
        XCTAssertEqual(try reopened.jobStore?.job(id: "synthetic-job")?.manifest, manifest)
        let reopenedInbox = try XCTUnwrap(reopened.tasksInbox).scoped(to: workspace)
        XCTAssertEqual(try reopenedInbox.items().map(\.id), ["synthetic-action"])
        XCTAssertTrue(try inbox.scoped(to: root.appendingPathComponent("workspace-b")).items().isEmpty)
        let unrelated = try composition(support: "support-b")
        XCTAssertTrue(try XCTUnwrap(unrelated.jobStore).jobs().isEmpty)
        XCTAssertTrue(try XCTUnwrap(unrelated.tasksInbox).scoped(to: workspace).items().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.path), "Opening operational stores must not create a content workspace")
    }

    @MainActor
    func testAppSearchRuntimePublishesIndexAndInvalidatesItWhenWorkspaceIsRemoved() async throws {
        let workspace = root.appendingPathComponent("workspace")
        let projects = workspace.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        try "# Synthetic Hosted Search\n\nHostedSearchEvidenceToken\n".write(
            to: projects.appendingPathComponent("synthetic.md"), atomically: true, encoding: .utf8)
        let indexed = expectation(description: "App search runtime publishes usable index")
        var publications: [Bool] = []
        var published = false
        let runtime = SearchIndexRuntime(databaseURL: root.appendingPathComponent("search.sqlite")) { index, _ in
            publications.append(index != nil)
            if index != nil && !published { published = true; indexed.fulfill() }
        }
        defer { runtime.stop() }
        var settings = AppSettings()
        settings.stillmatterRootURL = workspace
        runtime.configure(settings)
        await fulfillment(of: [indexed], timeout: 15)
        let index = try XCTUnwrap(runtime.index)
        XCTAssertEqual(try index.search("HostedSearchEvidenceToken").map(\.sourcePath), ["Projects/synthetic.md"])
        let generation = runtime.generation
        runtime.configure(settings)
        XCTAssertEqual(runtime.generation, generation, "Identical settings must retain the index")
        settings.stillmatterRootURL = nil
        runtime.configure(settings)
        XCTAssertNil(runtime.index)
        XCTAssertGreaterThan(runtime.generation, generation)
        XCTAssertEqual(publications, [false, true, false])
        runtime.stop()
        settings.stillmatterRootURL = workspace
        runtime.configure(settings)
        XCTAssertNil(runtime.index, "Stopped app runtime cannot recreate an index")
    }
}
