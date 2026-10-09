import XCTest
@testable import StillmatterCore

final class ActivityItemsTests: XCTestCase {
    func testCreatesFileBackedActivityOwnedByGeneralAndLinksProject() throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        let service = fixture.service(now: { "2026-09-16T10:30:00Z" })

        let activity = try service.create(ActivityDraft(
            title: "Ship activity basics",
            goal: "Give long-running work a durable home."
        ))

        XCTAssertEqual(activity.relativePath, "Activities/2026/09/2026-09-16-ship-activity-basics.md")
        XCTAssertEqual(activity.project, "General")
        XCTAssertEqual(activity.status, .active)
        XCTAssertEqual(activity.startedAt, "2026-09-16T10:30:00Z")
        XCTAssertNil(activity.endedAt)
        XCTAssertEqual(activity.goal, "Give long-running work a durable home.")
        let project = try String(contentsOf: fixture.root.appendingPathComponent("Projects/General.md"))
        XCTAssertTrue(project.contains("- [[Activities/2026/09/2026-09-16-ship-activity-basics.md|Ship activity basics]]"))
    }

    func testChosenProjectOwnershipUsesProjectHeadingAndDuplicateTitlesGetDistinctFiles() throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        try fixture.write("# Project Aurora\n\n## Activities\n", to: "Projects/Aurora.md")
        let service = fixture.service(now: { "2026-09-16T11:00:00Z" })

        let first = try service.create(ActivityDraft(title: "Launch prep", project: "Project Aurora"))
        let second = try service.create(ActivityDraft(title: "Launch prep", project: "Aurora"))

        XCTAssertEqual(first.project, "Project Aurora")
        XCTAssertEqual(second.relativePath, "Activities/2026/09/2026-09-16-launch-prep-2.md")
        XCTAssertEqual(Set(try service.all().map(\.relativePath)), Set([first.relativePath, second.relativePath]))
    }

    func testLifecycleSetsTerminalTimestampAndClearsItWhenReactivated() throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        var timestamp = "2026-09-16T10:00:00Z"
        let service = fixture.service(now: { timestamp })
        var activity = try service.create(ActivityDraft(title: "Lifecycle"))

        timestamp = "2026-09-17T12:00:00Z"
        activity = try service.updateStatus(activity, status: .blocked)
        XCTAssertEqual(activity.status, .blocked)
        XCTAssertNil(activity.endedAt)

        activity = try service.updateStatus(activity, status: .completed)
        XCTAssertEqual(activity.status, .completed)
        XCTAssertEqual(activity.endedAt, "2026-09-17T12:00:00Z")

        timestamp = "2026-09-18T09:00:00Z"
        activity = try service.updateStatus(activity, status: .active)
        XCTAssertEqual(activity.status, .active)
        XCTAssertNil(activity.endedAt)
        XCTAssertEqual(try service.active().map(\.title), ["Lifecycle"])

        activity = try service.updateStatus(activity, status: .canceled)
        XCTAssertEqual(activity.endedAt, "2026-09-18T09:00:00Z")
        XCTAssertTrue(try service.active().isEmpty)
    }

    func testOutputsAndTimestampedLogsRemainReadableAndSearchable() throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        let service = fixture.service(now: { "2026-09-16T14:15:00Z" })
        var activity = try service.create(ActivityDraft(title: "Observatory rollout"))

        activity = try service.appendOutput("[[Reports/launch-plan.md|Launch plan]]", to: activity)
        activity = try service.appendLog("Calibrated the silver chronometer", to: activity)

        XCTAssertEqual(activity.outputs, ["[[Reports/launch-plan.md|Launch plan]]"])
        XCTAssertEqual(activity.activityLog, ["2026-09-16T14:15:00Z — Calibrated the silver chronometer"])

        let index = try SearchIndex(
            databaseURL: fixture.appSupport.appendingPathComponent("search.sqlite"),
            workspaceRootURL: fixture.root
        )
        try index.rebuild()
        let result = try XCTUnwrap(index.search("chronometer").first)
        XCTAssertEqual(result.kind, .activity)
        XCTAssertEqual(result.sourcePath, activity.relativePath)
        XCTAssertEqual(result.title, "Activity log")
    }

    func testRejectsUnknownProjectAndDetectsStaleWrites() throws {
        let fixture = try ActivityFixture()
        defer { fixture.remove() }
        let service = fixture.service(now: { "2026-09-16T10:00:00Z" })

        XCTAssertThrowsError(try service.create(ActivityDraft(title: "Lost", project: "Missing"))) {
            XCTAssertEqual($0 as? ActivityServiceError, .projectNotFound("Missing"))
        }

        let activity = try service.create(ActivityDraft(title: "Concurrent edit"))
        try fixture.write("\nManual note.\n", appendingTo: activity.relativePath)
        XCTAssertThrowsError(try service.updateStatus(activity, status: .blocked)) {
            guard case WorkspaceVaultError.conflict = $0 else {
                return XCTFail("Expected a WorkspaceVault conflict, got \($0)")
            }
        }
    }
}

private final class ActivityFixture {
    let base: URL
    let root: URL
    let appSupport: URL

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityItemsTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Vault", isDirectory: true)
        appSupport = base.appendingPathComponent("AppSupport", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("# General\n\n## Activities\n", to: "Projects/General.md")
    }

    func service(now: @escaping () -> String) -> ActivityService {
        ActivityService(
            workspaceRootURL: root,
            vault: WorkspaceVault(workspaceRootURL: root, appSupportRootURL: appSupport),
            now: now
        )
    }

    func write(_ contents: String, to relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func write(_ contents: String, appendingTo relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        let existing = try String(contentsOf: url)
        try (existing + contents).write(to: url, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}
