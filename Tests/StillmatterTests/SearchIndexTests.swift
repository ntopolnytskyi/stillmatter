import Foundation
import XCTest
@testable import StillmatterCore

final class SearchIndexTests: XCTestCase {
    func testStartupScanIndexesKnownArtifactsAsTypedChunksAndSupportsFilters() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Meeting\n\nDiscuss Project Aurora.\n", to: "Meetings/2026/01/19/09-00-sync/meeting.md")
        try fixture.write("# Summary\n\nAurora launch decision.\n", to: "Meetings/2026/01/19/09-00-sync/summary.md")
        try fixture.write("WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nAurora transcript evidence.\n", to: "Meetings/2026/01/19/09-00-sync/transcript.vtt")
        try fixture.write("{\"recording\":\"Aurora planning\",\"duration\":42}", to: "Meetings/2026/01/19/09-00-sync/recording.localref.json")
        try fixture.write("# Todos\n\n## Queue\n\n- [ ] Prepare Aurora launch\n", to: "Todos/todo.md")
        try fixture.write("---\nstillmatter_type: activity\n---\n# Aurora rollout\n", to: "Activities/2026/01/2026-01-19-aurora.md")
        try fixture.write("# Aurora project\n", to: "Projects/Aurora.md")
        try fixture.write("# Aurora weekly report\n", to: "Reports/Weekly/2026-W03.md")
        try fixture.write("# Aurora daily brief\n", to: "Briefs/Daily/2026-01-19.md")
        let index = try fixture.openIndex()

        try index.startupScan()

        let kinds = Set(try index.search("Aurora").map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.meeting, .summary, .transcript, .metadata, .todo, .activity, .project, .report, .brief]))
        let todoResults = try index.search("Aurora", filter: SearchFilter(kinds: [.todo]))
        XCTAssertEqual(todoResults.map(\.sourcePath), ["Todos/todo.md"])
        XCTAssertEqual(todoResults.first?.body, "Prepare Aurora launch")
    }

    func testSearchLimitBoundsMaterializedResults() throws {
        let fixture = try SearchIndexFixture()
        for number in 0..<12 {
            try fixture.write("# Match\n\ncompass marker \(number)\n", to: "Projects/\(number).md")
        }
        let index = try fixture.openIndex()
        try index.startupScan()
        XCTAssertEqual(try index.search("compass").count, 12)
        XCTAssertEqual(try index.search("compass", limit: 5).count, 5)
    }

    func testStartupScanExcludesNoisyBinaryAndConfiguredPaths() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Visible\n\nKeep searchable lighthouse text.\n", to: "Projects/Visible.md")
        try fixture.write("private lighthouse", to: "Private/secret.md")
        try fixture.write("tool lighthouse", to: "node_modules/package/readme.md")
        try fixture.write("snapshot lighthouse", to: "Snapshots/old.md")
        try fixture.write("log lighthouse", to: "Logs/worker.log")
        try fixture.write("database lighthouse", to: "cache.sqlite")
        try fixture.write("audio lighthouse", to: "Meetings/call/audio.m4a")
        try fixture.write("media lighthouse", to: "Meetings/call/media/notes.md")
        let index = try fixture.openIndex(excludedPatterns: ["Private/**", "Meetings/**/media/**"])

        try index.startupScan()

        XCTAssertEqual(try index.search("lighthouse").map(\.sourcePath), ["Projects/Visible.md"])
    }

    func testRebuildReplacesStaleContentWithCurrentVaultContent() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Project\n\nOriginal compass phrase.\n", to: "Projects/General.md")
        let index = try fixture.openIndex()
        try index.startupScan()
        try fixture.write("# Project\n\nReplacement sextant phrase.\n", to: "Projects/General.md")

        XCTAssertEqual(try index.search("compass").count, 1)
        try index.rebuild()

        XCTAssertTrue(try index.search("compass").isEmpty)
        XCTAssertEqual(try index.search("sextant").map(\.sourcePath), ["Projects/General.md"])
    }

    func testIndexCanBeDeletedAndRebuiltFromCanonicalFiles() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Project\n\nRecoverable astrolabe notes.\n", to: "Projects/General.md")
        var index: SearchIndex? = try fixture.openIndex()
        try index?.startupScan()
        index = nil
        try fixture.removeDatabase()

        let reopened = try fixture.openIndex()
        try reopened.startupScan()

        XCTAssertEqual(try reopened.search("astrolabe").map(\.sourcePath), ["Projects/General.md"])
    }

    func testMarkdownSearchReturnsTheMatchingHeadingChunk() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("""
        # Weekly Report

        ## Decisions

        Adopt the heliograph protocol.

        ## Risks

        Cloud cover may delay transmission.
        """, to: "Reports/Weekly/2026-W03.md")
        let index = try fixture.openIndex()
        try index.startupScan()

        let results = try index.search("heliograph")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Decisions")
        XCTAssertEqual(results.first?.body, "Adopt the heliograph protocol.")
    }

    func testVTTTranscriptChunksPreserveTimestampCitations() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("""
        WEBVTT

        00:01:02.500 --> 00:01:06.000
        Calibrate the chronometer tomorrow.

        00:01:08.000 --> 00:01:12.250
        Record the final reading.
        """, to: "Meetings/call/transcript.vtt")
        let index = try fixture.openIndex()
        try index.startupScan()

        let result = try XCTUnwrap(index.search("chronometer").first)

        XCTAssertEqual(result.transcriptStartSeconds, 62.5)
        XCTAssertEqual(result.transcriptEndSeconds, 66)
        XCTAssertEqual(result.body, "Calibrate the chronometer tomorrow.")
    }

    func testJSONTranscriptChunksPreserveSegmentTimestampCitations() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("{\"segments\":[{\"start\":12.25,\"end\":15.5,\"text\":\"Align the periscope.\"}]}", to: "Meetings/call/transcript.json")
        let index = try fixture.openIndex()
        try index.startupScan()

        let result = try XCTUnwrap(index.search("periscope").first)

        XCTAssertEqual(result.transcriptStartSeconds, 12.25)
        XCTAssertEqual(result.transcriptEndSeconds, 15.5)
    }

    func testFrontmatterAndMetadataInsideExcludedMediaRemainSearchable() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("---\nstillmatter_type: activity\nproject: Zephyr\n---\n# Work\n\nOrdinary notes.\n", to: "Activities/work.md")
        try fixture.write("{\"recording\":\"Zephyr session\"}", to: "Media/call/recording.localref.json")
        try fixture.write("do not index Zephyr audio", to: "Media/call/audio.m4a")
        let index = try fixture.openIndex(excludedPatterns: ["Media/**"])
        try index.startupScan()

        XCTAssertEqual(Set(try index.search("Zephyr").map(\.kind)), [.metadata])
        XCTAssertEqual(Set(try index.search("Zephyr").map(\.sourcePath)), ["Activities/work.md", "Media/call/recording.localref.json"])
    }

    func testRecoveryRebuildRecreatesACorruptDatabase() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Project\n\nRecover the quadrant index.\n", to: "Projects/General.md")
        try fixture.writeDatabase("not a sqlite database")

        let index = try SearchIndex.recoveringRebuild(databaseURL: fixture.databaseURL, workspaceRootURL: fixture.vaultURL)

        XCTAssertEqual(try index.search("quadrant").map(\.sourcePath), ["Projects/General.md"])
    }

    func testIncrementalFileEventsReplaceAndRemoveIndexedChunks() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Activity\n\nOld telescope notes.\n", to: "Activities/sky.md")
        let index = try fixture.openIndex()
        try index.startupScan()

        try fixture.write("# Activity\n\nNew observatory notes.\n", to: "Activities/sky.md")
        try index.update(relativePath: "Activities/sky.md")

        XCTAssertTrue(try index.search("telescope").isEmpty)
        XCTAssertEqual(try index.search("observatory").map(\.kind), [.activity])

        try fixture.remove("Activities/sky.md")
        try index.update(relativePath: "Activities/sky.md")

        XCTAssertTrue(try index.search("observatory").isEmpty)
    }
}

private final class SearchIndexFixture {
    let rootURL: URL
    let vaultURL: URL
    let databaseURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterSearchIndexTests-\(UUID().uuidString)", isDirectory: true)
        vaultURL = rootURL.appendingPathComponent("Vault", isDirectory: true)
        databaseURL = rootURL.appendingPathComponent("AppSupport/search.sqlite")
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func write(_ contents: String, to relativePath: String) throws {
        let url = vaultURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func remove(_ relativePath: String) throws {
        try FileManager.default.removeItem(at: vaultURL.appendingPathComponent(relativePath))
    }

    func writeDatabase(_ contents: String) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: databaseURL)
    }

    func removeDatabase() throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func openIndex(excludedPatterns: [String] = []) throws -> SearchIndex {
        try SearchIndex(databaseURL: databaseURL, workspaceRootURL: vaultURL, excludedPatterns: excludedPatterns)
    }
}
