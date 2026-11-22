import Foundation
import XCTest
@testable import StillmatterCore

final class SearchIndexTests: XCTestCase {
    func testHybridRetrievalCombinesKeywordAndLocalParaphraseWithoutPrivateProfiles() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Summary\n\nMove the launch to Friday.", to: "Meetings/call/summary.md")
        try fixture.write("# Notes\n\nrelease deadline", to: "Meetings/call/notes.md")
        try fixture.write("# Voice\n\nprivate voice secret", to: "People/VoiceProfiles/person/profile.md")
        let provider = FixtureSemanticSearch()
        let index = try SearchIndex(databaseURL: fixture.databaseURL, workspaceRootURL: fixture.vaultURL,
                                    semanticSearch: provider)
        try index.startupScan()
        let response = try index.retrieve("release deadline")
        XCTAssertEqual(Set(response.results.map(\.sourcePath)), ["Meetings/call/summary.md", "Meetings/call/notes.md"])
        XCTAssertTrue(response.semanticNotice?.contains("suggestions") == true)
        XCTAssertFalse(provider.passages.contains(where: { $0.contains("private voice") }))
        XCTAssertTrue(try index.search("secret").isEmpty)
    }

    func testSemanticLifecycleRefreshArchiveAndWorkspaceIsolation() throws {
        let fixture = try SearchIndexFixture()
        let path = "Meetings/call/summary.md"
        try fixture.write("# Summary\n\nMove the launch to Friday.", to: path)
        let provider = FixtureSemanticSearch()
        let index = try SearchIndex(databaseURL: fixture.databaseURL, workspaceRootURL: fixture.vaultURL, semanticSearch: provider)
        try index.startupScan()
        try fixture.write("{\"archived\":true}", to: "Meetings/call/archive.json")
        XCTAssertTrue(try index.retrieve("release").results.isEmpty)
        XCTAssertEqual(try index.retrieve("release", filter: SearchFilter(includeArchived: true)).results.count, 1)
        try fixture.write("{\"archived\":false}", to: "Meetings/call/archive.json")
        try fixture.write("# Summary\n\nMonday replacement.", to: path)
        try index.update(relativePath: path)
        XCTAssertEqual(try index.retrieve("release").results.map(\.body), ["Monday replacement."])
        XCTAssertFalse(provider.passages.contains(where: { $0.contains("Friday") }))
        try fixture.remove(path)
        try index.update(relativePath: path)
        XCTAssertTrue(try index.retrieve("release").results.isEmpty)
        let other = try SearchIndexFixture()
        let switched = try SearchIndex(databaseURL: fixture.databaseURL, workspaceRootURL: other.vaultURL, semanticSearch: provider)
        try switched.startupScan()
        XCTAssertTrue(try switched.retrieve("release", filter: SearchFilter(includeArchived: true)).results.isEmpty)
        let restarted = try fixture.openIndex()
        try restarted.startupScan()
        XCTAssertTrue(try restarted.search("Monday").isEmpty)
    }

    func testSemanticFailureKeepsKeywordResultsAndExplainsMissingCapability() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Summary\n\nFriday café review.", to: "Meetings/call/summary.md")
        let provider = FixtureSemanticSearch()
        let index = try SearchIndex(databaseURL: fixture.databaseURL, workspaceRootURL: fixture.vaultURL, semanticSearch: provider)
        try index.rebuild()
        provider.scores = [.nan]
        let invalid = try index.retrieve("cafe")
        XCTAssertEqual(invalid.results.count, 1)
        XCTAssertTrue(invalid.semanticNotice?.contains("invalid scores") == true)
        provider.scores = []
        XCTAssertTrue(try index.retrieve("cafe").semanticNotice?.contains("invalid scores") == true)
        provider.failure = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model missing"])
        XCTAssertTrue(try index.retrieve("Friday").semanticNotice?.contains("Model missing") == true)
        let missing = try fixture.openIndex()
        XCTAssertEqual(try missing.retrieve("cafe", limit: 1).results.count, 1)
        XCTAssertTrue(try missing.retrieve("cafe").semanticNotice?.contains("not installed") == true)
        XCTAssertEqual(try missing.retrieve("").results.count, 1)
    }

    func testRemovedContentCannotReturnFromDelayedInferenceAndProposalsStayOutOfTodoSearch() throws {
        let fixture = try SearchIndexFixture()
        let path = "Meetings/call/action-items.md"
        try fixture.write("# Actions\n\n- [ ] Friday proposal", to: path)
        let provider = FixtureSemanticSearch()
        let index = try SearchIndex(databaseURL: fixture.databaseURL, workspaceRootURL: fixture.vaultURL, semanticSearch: provider)
        try index.rebuild()
        XCTAssertTrue(try index.retrieve("Friday", filter: SearchFilter(kinds: [.todo])).results.isEmpty)
        provider.duringInference = {
            try fixture.remove(path)
            try index.update(relativePath: path)
        }
        XCTAssertTrue(try index.retrieve("Friday").results.isEmpty)
    }

    func testSearchRejectsEscapingPathsSymlinksAndPrivateMaterialEvenWithArchiveOption() throws {
        let fixture = try SearchIndexFixture()
        let secret = fixture.rootURL.appendingPathComponent("secret.md")
        try "private needle".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.vaultURL.appendingPathComponent("escape.md"), withDestinationURL: secret)
        try fixture.write("private needle", to: "People/voice-profiles/secret.md")
        try fixture.write("private needle", to: "Meetings/call/diagnostics.md")
        let index = try fixture.openIndex()
        try index.rebuild()
        try index.update(relativePath: "../secret.md")
        try index.update(relativePath: "escape.md")
        XCTAssertTrue(try index.retrieve("needle", filter: SearchFilter(includeArchived: true)).results.isEmpty)
    }

    func testAllCanonicalTextIncludesNotesPreambleAndOnlyCurrentTranscript() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("Preamble compass.\n\n# Notes\n\nLater section.", to: "Meetings/call/my-notes.md")
        try fixture.write("{\"segments\":[{\"text\":\"Corrected speaker\",\"start\":12,\"end\":14}]}", to: "Meetings/call/transcript.json")
        try fixture.write("WEBVTT\n\n00:00:12.000 --> 00:00:14.000\nObsolete speaker\n", to: "Meetings/call/transcript.vtt")
        let index = try fixture.openIndex()
        try index.startupScan()
        XCTAssertEqual(try index.search("compass").count, 1)
        XCTAssertTrue(try index.search("Obsolete").isEmpty)
        XCTAssertEqual(try index.search("Corrected").first?.transcriptStartSeconds, 12)
    }

    func testFailedInferenceCannotReturnDeletedKeywordSnapshot() throws {
        let fixture = try SearchIndexFixture()
        let path = "Meetings/call/summary.md"
        try fixture.write("# Summary\n\nFriday deleted material", to: path)
        let provider = FixtureSemanticSearch()
        let index = try SearchIndex(databaseURL: fixture.databaseURL, workspaceRootURL: fixture.vaultURL, semanticSearch: provider)
        try index.rebuild()
        provider.duringInference = { try fixture.remove(path); try index.update(relativePath: path) }
        provider.failure = NSError(domain: "Unavailable model", code: 1)
        XCTAssertTrue(try index.retrieve("Friday").results.isEmpty)
    }

    func testCanonicalTranscriptCreationAndRemovalReconsidersLegacyVTT() throws {
        let fixture = try SearchIndexFixture()
        let vtt = "Meetings/call/transcript.vtt", json = "Meetings/call/transcript.json"
        try fixture.write("WEBVTT\n\n00:00:12.000 --> 00:00:14.000\nObsolete text\n", to: vtt)
        let index = try fixture.openIndex()
        try index.rebuild()
        XCTAssertEqual(try index.search("Obsolete").count, 1)
        try fixture.write("{\"segments\":[{\"text\":\"Corrected text\",\"start\":12,\"end\":14}]}", to: json)
        try index.update(relativePath: json)
        XCTAssertTrue(try index.search("Obsolete").isEmpty)
        XCTAssertEqual(try index.search("Corrected").count, 1)
        try fixture.remove(json)
        try index.update(relativePath: json)
        XCTAssertTrue(try index.search("Corrected").isEmpty)
        XCTAssertEqual(try index.search("Obsolete").count, 1, "Legacy VTT is authoritative only when JSON is absent")
    }

    func testPersonalTodoSearchRetainsApprovedNotesAndActionsWithoutPendingOrOtherOwners() throws {
        let fixture = try SearchIndexFixture()
        func task(_ title: String, owner: String, review: String) throws -> String {
            let metadata = MeetingItemMetadata(v: 1, id: UUID().uuidString.lowercased(), owner: owner,
                review: review, origin: "user", legacyID: nil, citations: [])
            return "- [ ] \(title) <!-- sm-item:\(String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self)) -->"
        }
        let notes = try [task("Approved note deadline", owner: "me", review: "approved"),
            task("Other owner deadline", owner: "person:someone", review: "approved")].joined(separator: "\n")
            + "\n- [ ] User authored deadline\n- [ ] Malformed deadline <!-- sm-item:broken -->"
        try fixture.write("# My Notes\n\n" + notes, to: "Meetings/call/my-notes.md")
        let actions = try [task("Approved action deadline", owner: "me", review: "approved"),
            task("Pending proposal deadline", owner: "me", review: "pending")].joined(separator: "\n")
        try fixture.write("# Actions\n\n" + actions, to: "Meetings/call/action-items.md")
        try fixture.write("# Todos\n\n- [ ] Standalone task", to: "Todos/todo.md")
        let index = try fixture.openIndex()
        try index.rebuild()
        XCTAssertEqual(Set(try index.search("deadline", filter: SearchFilter(kinds: [.todo])).map(\.title)),
            ["Approved note deadline", "User authored deadline", "Approved action deadline"])
        XCTAssertTrue(try index.search("proposal", filter: SearchFilter(kinds: [.todo])).isEmpty)
        XCTAssertFalse(try index.search("proposal", filter: SearchFilter(kinds: [.markdown])).isEmpty)
    }

    func testCanonicalTranscriptTextEditsRefreshWithoutWritingSourcesAndConflictsFailClosed() throws {
        let fixture = try SearchIndexFixture()
        try fixture.prepareCanonicalTranscript()
        let jsonPath = "Meetings/call/transcript.json", textPath = "Meetings/call/transcript.txt"
        let originalJSON = try String(contentsOf: fixture.vaultURL.appendingPathComponent(jsonPath))
        let originalText = try String(contentsOf: fixture.vaultURL.appendingPathComponent(textPath))
        let manifestPath = "Meetings/call/meeting-artifacts.json"
        let originalManifest = try String(contentsOf: fixture.vaultURL.appendingPathComponent(manifestPath))
        let index = try fixture.openIndex()
        try index.rebuild()
        try fixture.write(originalText.replacingOccurrences(of: "Original utterance", with: "Corrected utterance"), to: textPath)
        try index.update(relativePath: textPath)
        XCTAssertTrue(try index.search("Original").isEmpty)
        XCTAssertEqual(try index.search("Corrected").first?.sourcePath, textPath)
        XCTAssertEqual(try index.search("Corrected").first?.transcriptStartSeconds, 12)
        XCTAssertEqual(try String(contentsOf: fixture.vaultURL.appendingPathComponent(jsonPath)), originalJSON)
        try fixture.write(originalJSON.replacingOccurrences(of: "Original utterance", with: "Replacement utterance"), to: jsonPath)
        XCTAssertThrowsError(try index.update(relativePath: jsonPath))
        XCTAssertThrowsError(try index.search("Corrected"), "A conflicting pair cannot expose stale chunks")
        try fixture.write(originalText, to: textPath)
        try index.update(relativePath: textPath)
        XCTAssertEqual(try index.search("Replacement").first?.sourcePath, jsonPath)
        try fixture.write("malformed text", to: textPath)
        XCTAssertThrowsError(try index.update(relativePath: textPath))
        XCTAssertThrowsError(try index.search("Replacement"))
        let replacementJSON = try Data(contentsOf: fixture.vaultURL.appendingPathComponent(jsonPath))
        try fixture.write(String(decoding: MeetingTranscriptCodec.text(replacementJSON), as: UTF8.self), to: textPath)
        try index.update(relativePath: textPath)
        XCTAssertEqual(try index.search("Replacement").count, 1)
        try fixture.write("broken manifest", to: manifestPath)
        XCTAssertThrowsError(try index.update(relativePath: manifestPath))
        XCTAssertThrowsError(try index.search("Replacement"))
        var manifestObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(originalManifest.utf8)) as? [String: Any])
        manifestObject["version"] = 99
        try fixture.write(String(decoding: JSONSerialization.data(withJSONObject: manifestObject), as: UTF8.self), to: manifestPath)
        XCTAssertThrowsError(try index.update(relativePath: manifestPath))
        try fixture.write(originalManifest, to: manifestPath)
        try index.update(relativePath: manifestPath)
        var wrongOwner = try XCTUnwrap(JSONSerialization.jsonObject(with: replacementJSON) as? [String: Any])
        wrongOwner["meeting_relative_path"] = "Meetings/other/meeting.md"
        let wrongJSON = try JSONSerialization.data(withJSONObject: wrongOwner)
        try fixture.write(String(decoding: wrongJSON, as: UTF8.self), to: jsonPath)
        try fixture.write(String(decoding: MeetingTranscriptCodec.text(wrongJSON), as: UTF8.self), to: textPath)
        XCTAssertThrowsError(try index.update(relativePath: jsonPath))
        try fixture.write(String(decoding: replacementJSON, as: UTF8.self), to: jsonPath)
        try fixture.write(String(decoding: MeetingTranscriptCodec.text(replacementJSON), as: UTF8.self), to: textPath)
        try index.update(relativePath: jsonPath)
        try fixture.remove(manifestPath)
        try index.update(relativePath: manifestPath)
        try fixture.remove(jsonPath)
        try index.update(relativePath: jsonPath)
        XCTAssertEqual(try index.search("Replacement").first?.sourcePath, textPath)
        try fixture.remove(textPath)
        try index.update(relativePath: textPath)
        XCTAssertTrue(try index.search("Replacement").isEmpty)
    }

    func testCanonicalTranscriptFailedRebuildRecoversAndRejectsEscapingCompanion() throws {
        let fixture = try SearchIndexFixture()
        try fixture.prepareCanonicalTranscript()
        let path = "Meetings/call/transcript.txt"
        let original = try String(contentsOf: fixture.vaultURL.appendingPathComponent(path))
        let index = try fixture.openIndex()
        try index.rebuild()
        try fixture.write("broken", to: path)
        XCTAssertThrowsError(try index.rebuild())
        XCTAssertThrowsError(try index.search("Original"))
        try fixture.write("# Unrelated\n\nUnrelatedPublicationNeedle", to: "Projects/unrelated.md")
        XCTAssertNoThrow(try index.update(relativePath: "Projects/unrelated.md"), "A different Meeting's publication must not fail because of an old source error")
        XCTAssertThrowsError(try index.search("Original"))
        try fixture.write(original, to: path)
        try index.update(relativePath: path)
        XCTAssertEqual(try index.search("Original").count, 1)
        XCTAssertEqual(try index.search("UnrelatedPublicationNeedle").count, 1)
        try fixture.remove(path)
        let external = fixture.rootURL.appendingPathComponent("private-transcript.txt")
        try original.write(to: external, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: fixture.vaultURL.appendingPathComponent(path), withDestinationURL: external)
        XCTAssertThrowsError(try index.update(relativePath: path))
        XCTAssertThrowsError(try index.search("Original"))
    }

    func testRebuildAndWatcherRefreshUseIdenticalCanonicalSourceRulesWithoutWritingFiles() throws {
        for patterns in [[], ["**/transcript.txt"], ["**/meeting-artifacts.json"]] {
            let fixture = try SearchIndexFixture()
            try fixture.prepareCanonicalTranscript()
            let textPath = "Meetings/call/transcript.txt"
            let jsonPath = "Meetings/call/transcript.json"
            let manifestPath = "Meetings/call/meeting-artifacts.json"
            let originalText = try String(contentsOf: fixture.vaultURL.appendingPathComponent(textPath))
            let index = try fixture.openIndex(excludedPatterns: patterns)
            try index.rebuild()
            try fixture.write(originalText.replacingOccurrences(of: "Original utterance", with: "Corrected utterance"), to: textPath)
            let paths = [textPath, jsonPath, manifestPath]
            let before = try paths.map { try Data(contentsOf: fixture.vaultURL.appendingPathComponent($0)) }
            for event in paths {
                try index.update(relativePath: event)
                let refreshed = try index.search("Corrected", filter: SearchFilter(kinds: [.transcript]))
                try index.rebuild()
                XCTAssertEqual(try index.search("Corrected", filter: SearchFilter(kinds: [.transcript])), refreshed)
                XCTAssertEqual(refreshed.count, patterns.isEmpty ? 1 : 0)
                XCTAssertEqual(refreshed.first?.sourcePath, patterns.isEmpty ? textPath : nil)
            }
            XCTAssertEqual(try paths.map { try Data(contentsOf: fixture.vaultURL.appendingPathComponent($0)) }, before)
            try fixture.remove(jsonPath)
            try index.update(relativePath: jsonPath)
            let textOnly = try index.search("Corrected", filter: SearchFilter(kinds: [.transcript]))
            try index.rebuild()
            XCTAssertEqual(try index.search("Corrected", filter: SearchFilter(kinds: [.transcript])), textOnly)
            XCTAssertEqual(textOnly.count, patterns.isEmpty ? 1 : 0)
        }
    }

    func testCanonicalCompanionAndInsideWorkspaceSymlinksCannotBypassSearchExclusions() throws {
        let fixture = try SearchIndexFixture()
        try fixture.prepareCanonicalTranscript()
        let source = fixture.vaultURL.appendingPathComponent("Meetings/call/transcript.txt")
        let text = try String(contentsOf: source)
        let excluded = try fixture.openIndex(excludedPatterns: ["**/transcript.txt"])
        try excluded.rebuild()
        XCTAssertTrue(try excluded.search("Original").isEmpty)
        try fixture.write(text, to: "Private/transcript.txt")
        try fixture.remove("Meetings/call/transcript.txt")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: fixture.vaultURL.appendingPathComponent("Private/transcript.txt"))
        try fixture.write("# Private\n\nAliasSecretNeedle", to: "Private/notes.md")
        try fixture.remove("Meetings/call/my-notes.md")
        try FileManager.default.createSymbolicLink(at: fixture.vaultURL.appendingPathComponent("Meetings/call/my-notes.md"),
            withDestinationURL: fixture.vaultURL.appendingPathComponent("Private/notes.md"))
        let protected = try fixture.openIndex(excludedPatterns: ["Private/**"])
        try protected.rebuild()
        XCTAssertTrue(try protected.search("Original").isEmpty)
        try protected.update(relativePath: "Meetings/call/my-notes.md")
        XCTAssertTrue(try protected.search("AliasSecretNeedle").isEmpty)
    }

    func testStartupScanIndexesKnownArtifactsAsTypedChunksAndSupportsFilters() throws {
        let fixture = try SearchIndexFixture()
        try fixture.write("# Meeting\n\nDiscuss Project Aurora.\n", to: "Meetings/2026/01/19/09-00-sync/meeting.md")
        try fixture.write("# Summary\n\nAurora launch decision.\n", to: "Meetings/2026/01/19/09-00-sync/summary.md")
        try fixture.write("WEBVTT\n\n00:00:01.000 --> 00:00:04.000\nAurora transcript evidence.\n", to: "Meetings/2026/01/19/09-00-sync/transcript.vtt")
        try fixture.write("{\"recording\":\"Aurora planning\",\"duration\":42}", to: "Meetings/2026/01/19/09-00-sync/recording.localref.json")
        try fixture.write("# Todos\n\n## Queue\n\n- [ ] Prepare Aurora launch\n", to: "Todos/todo.md")
        try fixture.write("# Aurora project\n", to: "Projects/Aurora.md")
        let index = try fixture.openIndex()

        try index.startupScan()

        let kinds = Set(try index.search("Aurora").map(\.kind))
        XCTAssertTrue(kinds.isSuperset(of: [.meeting, .summary, .transcript, .metadata, .todo, .project]))
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
        # Project notes

        ## Decisions

        Adopt the heliograph protocol.

        ## Risks

        Cloud cover may delay transmission.
        """, to: "Projects/Notes.md")
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
        try fixture.write("---\nstillmatter_type: project\nproject: Zephyr\n---\n# Work\n\nOrdinary notes.\n", to: "Projects/work.md")
        try fixture.write("{\"recording\":\"Zephyr session\"}", to: "Media/call/recording.localref.json")
        try fixture.write("do not index Zephyr audio", to: "Media/call/audio.m4a")
        let index = try fixture.openIndex(excludedPatterns: ["Media/**"])
        try index.startupScan()

        XCTAssertEqual(Set(try index.search("Zephyr").map(\.kind)), [.metadata])
        XCTAssertEqual(Set(try index.search("Zephyr").map(\.sourcePath)), ["Projects/work.md", "Media/call/recording.localref.json"])
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
        try fixture.write("# Project\n\nOld telescope notes.\n", to: "Projects/sky.md")
        let index = try fixture.openIndex()
        try index.startupScan()

        try fixture.write("# Project\n\nNew observatory notes.\n", to: "Projects/sky.md")
        try index.update(relativePath: "Projects/sky.md")

        XCTAssertTrue(try index.search("telescope").isEmpty)
        XCTAssertEqual(try index.search("observatory").map(\.kind), [.project])

        try fixture.remove("Projects/sky.md")
        try index.update(relativePath: "Projects/sky.md")

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

    func prepareCanonicalTranscript() throws {
        try write("---\ntitle: Canonical fixture\ncapture_session_id: call\n---\n# Canonical fixture\n", to: "Meetings/call/meeting.md")
        let document: [String: Any] = ["schema_version": 1, "capture_session_id": "call", "meeting_relative_path": "Meetings/call/meeting.md",
            "language": "en", "detected_languages": ["en"], "engine": "fixture", "model": "fixture", "generated_at": "2026-01-01T00:00:00Z",
            "audio_sources": [], "diagnostics": [], "segments": [["id": "one", "start": 12, "end": 14, "language": "en", "track": "microphone", "speaker": "Me", "text": "Original utterance"]]]
        try write(String(decoding: JSONSerialization.data(withJSONObject: document), as: UTF8.self), to: "Meetings/call/transcript.json")
        let vault = WorkspaceVault(workspaceRootURL: vaultURL, appSupportRootURL: rootURL.appendingPathComponent("Support"))
        _ = try MeetingManagementService(vault: vault).detail(for: "Meetings/call/meeting.md")
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

private final class FixtureSemanticSearch: LocalSemanticSearching {
    var passages: [String] = []
    var scores: [Double]?
    var failure: Error?
    var duringInference: (() throws -> Void)?
    func similarities(query: String, passages: [String]) throws -> [Double] {
        self.passages = passages
        try duringInference?()
        if let failure { throw failure }
        if let scores { return scores }
        return passages.map { $0.contains("Friday") ? 0.95 : 0.2 }
    }
}
