import XCTest
@testable import StillmatterCore

final class MeetingArtifactTests: XCTestCase {
    private var root: URL!
    private var support: URL!
    private var vault: WorkspaceVault!
    private let meeting = "Meetings/fixture/meeting.md"
    private var store: MeetingArtifactStore { MeetingArtifactStore(vault: vault, inbox: nil) }
    private var service: MeetingManagementService { MeetingManagementService(vault: vault) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("stillmatter-artifacts-\(UUID().uuidString)")
        support = root.appendingPathComponent("support")
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        vault = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func write(_ path: String, _ text: String) throws {
        _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path, expectedVersion: vault.versionOfMarkdown(relativePath: path))
    }
    private func text(_ path: String) throws -> String { String(decoding: try vault.readMarkdown(relativePath: path).data, as: UTF8.self) }
    private func path(_ name: String) -> String { "Meetings/fixture/" + name }
    private func seed(notes: String = "Мої слова. English too.\n- [ ] Підсумок #робота\n- [ ] Підсумок #робота", extraction: Bool = true) throws {
        try write(meeting, "---\ntitle: Fixture\ncapture_session_id: fixture\n---\n# Fixture\n\n## Notes\n\n\(notes)\n\n## Related\n\n[[Projects/General]]\n")
        try write(path("summary.md"), "---\ntype: meeting-summary\ngenerated_at: 2026-01-01T00:00:00Z\n---\n## Summary\n\nKeep my edited Summary.\n")
        if extraction {
            let citation = MeetingOutcomeCitation(segmentID: "s1", startSeconds: 1.125, endSeconds: 2.5)
            let value = MeetingSummaryExtraction(meeting: meeting, transcript: path("transcript.json"),
                decisions: [.init(id: "decision", text: "Choose the plan", citations: [citation])],
                myActionItems: [.init(id: "task", text: "Send recap", citations: [citation])],
                otherActionItems: [.init(id: "other", text: "Colleague's task", citations: [])],
                openQuestions: [.init(id: "question", text: "What next?", citations: [citation])])
            try write(path("summary-extraction.json"), String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
        }
    }
    private func load() throws -> MeetingArtifactStore.Loaded { try store.load(meetingPath: meeting, meetingID: "fixture") }
    private func transcript(_ words: String = "Привіт\u{2028}Hello\u{2029}") throws -> Data {
        let document = TranscriptDocument(schemaVersion: 1, captureSessionID: "fixture", meetingRelativePath: meeting,
            language: .english, detectedLanguages: [.english, .ukrainian], engine: "synthetic", model: "fixture", generatedAt: Date(timeIntervalSince1970: 0),
            audioSources: [], segments: [.init(id: "s1", startSeconds: 1.125, endSeconds: 2.5, text: words, language: .ukrainian, track: .microphone, speaker: "Me")],
            diagnostics: ["Metadata\u{2028}line\u{2029}paragraph"])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    func testSummarySaveRejectsCrossFileIdentityCollisionsWithoutChangingFiles() throws {
        try seed()
        let initial = try load()
        let action = try XCTUnwrap(initial.sections.myActionItems.components(separatedBy: "\n").first { $0.contains("<!-- sm-item:") })
        let paths = Array(initial.paths.values)
        let before = try paths.map { try vault.readMarkdown(relativePath: $0).data }
        var edited = initial.sections
        edited.summary = "Changed summary"
        edited.decisions += "\n" + action
        XCTAssertThrowsError(try store.saveSummary(edited, meetingPath: meeting, meetingID: "fixture", expected: initial.summaryVersion)) {
            XCTAssertTrue($0.localizedDescription.contains("same item ID"))
        }
        XCTAssertEqual(try paths.map { try vault.readMarkdown(relativePath: $0).data }, before)
        XCTAssertEqual(try load().sections.summary, initial.sections.summary)
    }

    func testNotesSaveRejectsIdentityFromAnotherArtifactWithoutChangingFiles() throws {
        try seed()
        let initial = try load()
        let action = try XCTUnwrap(initial.sections.myActionItems.components(separatedBy: "\n").first { $0.contains("<!-- sm-item:") })
        let paths = Array(initial.paths.values)
        let before = try paths.map { try vault.readMarkdown(relativePath: $0).data }
        XCTAssertThrowsError(try store.saveNotes(initial.notes + "\n" + action, meetingPath: meeting, meetingID: "fixture", expected: initial.notesVersion)) {
            XCTAssertTrue($0.localizedDescription.contains("same item ID"))
        }
        XCTAssertEqual(try paths.map { try vault.readMarkdown(relativePath: $0).data }, before)
        XCTAssertEqual(try load().notes, initial.notes)
    }

    func testSummarySaveAllowsMovingAnIdentityBetweenArtifacts() throws {
        try seed()
        let initial = try load()
        let action = try XCTUnwrap(initial.sections.myActionItems.components(separatedBy: "\n").first { $0.contains("<!-- sm-item:") })
        var edited = initial.sections
        edited.myActionItems = edited.myActionItems.replacingOccurrences(of: action, with: "")
        edited.decisions += "\n" + action
        try store.saveSummary(edited, meetingPath: meeting, meetingID: "fixture", expected: initial.summaryVersion)
        let saved = try load()
        XCTAssertTrue(saved.sections.decisions.contains(action))
        XCTAssertFalse(saved.sections.myActionItems.contains(action))
    }

    func testLegacyMigrationCreatesSeparateCanonicalFilesAndKeepsProseIdentityAndReferencesAcrossReopen() throws {
        try seed()
        try write(path("archive.json"), "{\"archived\":true}")
        try write("Todos/todo.md", "## Queue\n- [x] Edited accepted task [[Meetings/fixture/summary|ref]]\n")
        let oldTodo = try text("Todos/todo.md")
        let first = try load()
        XCTAssertTrue(first.notes.contains("Мої слова. English too."))
        let notes = TodoItemParser().parse(markdown: first.notes, relativePath: first.paths["notes"]!)
        XCTAssertEqual(notes.count, 2)
        XCTAssertNotEqual(notes[0].id, notes[1].id)
        XCTAssertEqual(notes.map(\.title), ["Підсумок #робота", "Підсумок #робота"])
        XCTAssertTrue(try text(meeting).contains("## Related\n\n[[Projects/General]]"))
        XCTAssertTrue(try text(meeting).contains("[[my-notes]]"))
        XCTAssertEqual(first.sections.summary, "## Summary\n\nKeep my edited Summary.\n")
        XCTAssertEqual(first.extraction.decisions.first?.text, "Choose the plan")
        XCTAssertEqual(first.extraction.myActionItems.first?.citations.first?.segmentID, "s1")
        XCTAssertNotEqual(try text("Todos/todo.md"), oldTodo)
        XCTAssertTrue(try text("Todos/todo.md").contains("[[item:"))
        XCTAssertEqual(try text(path("archive.json")), "{\"archived\":true}")
        XCTAssertTrue(try text(path("meeting-artifacts.json")).contains("\"archiveDateUnknown\":true"))
        let reopened = try load()
        XCTAssertEqual(first.notes, reopened.notes)
        XCTAssertEqual(first.notesVersion, reopened.notesVersion)
        XCTAssertEqual(first.summaryVersion, reopened.summaryVersion)
        XCTAssertEqual(first.paths, reopened.paths)
        XCTAssertEqual(try store.identity(at: meeting), "fixture")
    }

    func testExistingNotesAndHumanEditedOutcomeSectionsWinOverLegacyEmbeddedGeneratedContent() throws {
        try seed()
        try write(path("my-notes.md"), "Existing user-owned notes.\n- [x] Already done #mine")
        try write(path("summary.md"), "## Summary\n\nEdited\n\n## Decisions\n\n- Manually corrected decision\n\n## Open questions\n\n- User question\n")
        XCTAssertThrowsError(try load()) { XCTAssertTrue($0.localizedDescription.contains("Both are preserved")) }
        XCTAssertTrue(try text(meeting).contains("Мої слова"))
        XCTAssertTrue(try text(path("my-notes.md")).hasPrefix("Existing user-owned notes."))
        // Explicitly resolve by removing the legacy embedded section; the separate file survives.
        try write(meeting, "---\ntitle: Fixture\ncapture_session_id: fixture\n---\n# Fixture\n")
        let loaded = try load()
        XCTAssertTrue(loaded.notes.hasPrefix("Existing user-owned notes."))
        XCTAssertFalse(loaded.notes.contains("Мої слова"))
        XCTAssertEqual(loaded.extraction.decisions.first?.text, "Manually corrected decision")
        XCTAssertEqual(loaded.extraction.openQuestions.first?.text, "User question")
        XCTAssertTrue(loaded.sections.summary.contains("## Summary\n\nEdited"))
        XCTAssertTrue(try text(path("summary.md")).contains("stillmatter-artifact:summary"))
    }

    func testEveryMigrationCheckpointResumesCapturedPlanWithoutDuplicateIDsOrOverwritingNotes() throws {
        for stop in 0...7 {
            let workspace = root.appendingPathComponent("crash-\(stop)")
            let isolated = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support.appendingPathComponent("crash-\(stop)"))
            _ = try isolated.writeMarkdown(Data("# Legacy\n\n## Notes\n\n- [ ] Keep me\n".utf8), relativePath: meeting, expectedVersion: nil)
            enum Crash: Error { case injected }
            let interrupted = MeetingArtifactStore(vault: isolated, inbox: nil, checkpoint: { phase in if phase == stop { throw Crash.injected } })
            XCTAssertThrowsError(try interrupted.load(meetingPath: self.meeting, meetingID: "fixture"))
            let reopened = MeetingArtifactStore(vault: isolated, inbox: nil)
            let result = try reopened.load(meetingPath: self.meeting, meetingID: "fixture")
            XCTAssertEqual(TodoItemParser().parse(markdown: result.notes, relativePath: "notes.md").count, 1)
            XCTAssertTrue(result.notes.contains("Keep me"))
            XCTAssertEqual(try reopened.load(meetingPath: self.meeting, meetingID: "fixture").notes, result.notes)
        }
    }

    func testInterruptedMigrationPreservesUnexpectedExternalVersionAndRecoveryPlan() throws {
        try seed()
        enum Crash: Error { case injected }
        let interrupted = MeetingArtifactStore(vault: vault, inbox: nil, checkpoint: { if $0 == 1 { throw Crash.injected } })
        XCTAssertThrowsError(try interrupted.load(meetingPath: meeting, meetingID: "fixture"))
        let journal = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: vault.meetingArtifactStateURL, includingPropertiesForKeys: nil).first)
        let before = try Data(contentsOf: journal)
        try write(path("action-items.md"), "External changed content remains authoritative.")
        XCTAssertThrowsError(try load()) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed during artifact recovery"))
            XCTAssertTrue(error.localizedDescription.contains("action-items.md"))
        }
        XCTAssertEqual(try text(path("action-items.md")), "External changed content remains authoritative.")
        XCTAssertEqual(try Data(contentsOf: journal), before)
    }

    func testExternalCanonicalEditsRenameAndVersionedSaveKeepBothUnsavedDraftAndSource() throws {
        try seed(notes: "Original notes.")
        let first = try service.detail(for: "fixture")
        let renamed = path("renamed-notes.md")
        try FileManager.default.moveItem(at: vault.rootURL.appendingPathComponent(path("my-notes.md")), to: vault.rootURL.appendingPathComponent(renamed))
        try write(renamed, try text(renamed).replacingOccurrences(of: "Original notes.", with: "External notes."))
        let latest = try service.detail(for: "fixture")
        XCTAssertEqual(latest.humanNotes.trimmingCharacters(in: .newlines), "External notes.")
        XCTAssertThrowsError(try service.saveHumanNotes("Unsaved local draft", for: "fixture", expectedVersion: XCTUnwrap(first.notesVersion)))
        XCTAssertTrue(try text(renamed).contains("External notes."))
        let conflicts = support.appendingPathComponent("MeetingArtifacts/Conflicts")
        let conflict = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: conflicts, includingPropertiesForKeys: nil).first)
        let savedConflict = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: conflict))
        XCTAssertEqual(savedConflict["draft"], "Unsaved local draft")
        XCTAssertEqual(savedConflict["external"]?.trimmingCharacters(in: .newlines), "External notes.")
        let saved = try service.saveHumanNotes("Explicitly resolved notes", for: "fixture", expectedVersion: XCTUnwrap(latest.notesVersion))
        XCTAssertEqual(saved.humanNotes, "Explicitly resolved notes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.rootURL.appendingPathComponent(path("my-notes.md")).path))
        XCTAssertEqual(try service.detail(for: "fixture").humanNotes, "Explicitly resolved notes")
    }

    func testSummarySaveKeepsGeneratedFrontmatterAndConflictsWithChangedOutcomeArtifactsButNotNotes() throws {
        try seed(notes: "Notes")
        let first = try service.detail(for: "fixture")
        _ = try service.saveHumanNotes("Edited notes independently", for: "fixture", expectedVersion: XCTUnwrap(first.notesVersion))
        var sections = try XCTUnwrap(first.summary)
        sections.summary = "Updated summary"
        let saved = try service.saveSummary(sections, for: "fixture", expectedVersion: XCTUnwrap(first.summaryVersion))
        XCTAssertEqual(saved.summary?.summary, "Updated summary")
        XCTAssertTrue(try text(path("summary.md")).contains("generated_at: 2026-01-01T00:00:00Z"))
        try write(path("decisions.md"), try text(path("decisions.md")).replacingOccurrences(of: "Choose the plan", with: "External decision"))
        XCTAssertThrowsError(try service.saveSummary(sections, for: "fixture", expectedVersion: XCTUnwrap(saved.summaryVersion)))
        XCTAssertEqual(try service.detail(for: "fixture").decisions.first?.text, "External decision")
        XCTAssertEqual(try service.detail(for: "fixture").humanNotes, "Edited notes independently")
    }

    func testMalformedUTF8MetadataDuplicateArtifactAndMissingFileAreActionableWithoutEmptySuccess() throws {
        try seed()
        _ = try load()
        let notes = path("my-notes.md"), valid = try text(notes)
        _ = try vault.writeMarkdown(Data([0xff, 0xfe]), relativePath: notes, expectedVersion: vault.versionOfMarkdown(relativePath: notes))
        XCTAssertThrowsError(try service.detail(for: "fixture")) { XCTAssertTrue($0.localizedDescription.contains("my-notes.md")) }
        try write(notes, valid)
        try write(path("copied-notes.md"), valid)
        XCTAssertThrowsError(try load()) { XCTAssertTrue($0.localizedDescription.contains("Multiple files")) }
        try FileManager.default.removeItem(at: vault.rootURL.appendingPathComponent(path("copied-notes.md")))
        try write(notes, "- [ ] Task <!-- sm-item:broken -->")
        XCTAssertThrowsError(try service.detail(for: "fixture")) { XCTAssertTrue($0.localizedDescription.contains("my-notes.md")) }
        try write(notes, valid)
        try FileManager.default.removeItem(at: vault.rootURL.appendingPathComponent(notes))
        XCTAssertThrowsError(try service.detail(for: "fixture"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: vault.rootURL.appendingPathComponent(notes).path))
    }

    func testNotesAdoptionPreservesWhitespaceFencedExamplesAndStableIDsAfterExternalTextEdits() throws {
        try seed(notes: "  Prose with spaces  \n```markdown\n- [ ] Example, not a task\n```\n~~~\n- [ ] Another example\n~~~\n* [B] Real task #mine")
        let first = try load()
        XCTAssertTrue(first.notes.hasPrefix("\n  Prose with spaces  "))
        XCTAssertTrue(first.notes.contains("- [ ] Example, not a task\n```"))
        let stableID = try XCTUnwrap(TodoItemParser().parse(markdown: first.notes, relativePath: first.paths["notes"]!).last?.id)
        let notePath = first.paths["notes"]!
        try write(notePath, try text(notePath).replacingOccurrences(of: "Real task", with: "Edited real task"))
        let second = try load()
        XCTAssertEqual(TodoItemParser().parse(markdown: second.notes, relativePath: notePath).last?.id, stableID)
    }

    func testTranscriptJSONTextConsistencyAcceptsOneSidedEditsAndPreservesUnicodeTimingAndUnknownMetadata() throws {
        try seed()
        let original = try transcript()
        try write(path("transcript.json"), String(decoding: original, as: UTF8.self))
        let loaded = try load()
        XCTAssertEqual(loaded.transcript?.segments.first?.startSeconds, 1.125)
        let plain = try vault.readMarkdown(relativePath: path("transcript.txt")).data
        XCTAssertEqual(try MeetingTranscriptCodec.canonicalJSON(original), try MeetingTranscriptCodec.json(plain, path: "transcript.txt"))
        var edited = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        edited["extension_metadata"] = ["note": "Unknown\u{2028}field\u{2029}"]
        try write(path("transcript.json"), String(decoding: try MeetingTranscriptCodec.encodeJSON(edited), as: UTF8.self))
        _ = try load()
        let updatedText = try text(path("transcript.txt")).replacingOccurrences(of: "Привіт", with: "Corrected")
        try write(path("transcript.txt"), updatedText)
        XCTAssertTrue(try XCTUnwrap(load().transcript?.segments.first?.text).contains("Corrected"))
        XCTAssertTrue(try text(path("transcript.json")).contains("extension_metadata"))
        XCTAssertTrue(try text(path("meeting-artifacts.json")).contains("transcriptBaseHash"))
        XCTAssertFalse(try text(path("meeting-artifacts.json")).contains("Corrected"), "Metadata must not retain a private Transcript copy")
    }

    func testDivergentTranscriptEditsInvalidTimingAndInvalidHeadersPreserveBothSources() throws {
        try seed()
        try write(path("transcript.json"), String(decoding: try transcript("Original"), as: UTF8.self))
        _ = try load()
        try write(path("transcript.json"), String(decoding: try transcript("JSON edit"), as: UTF8.self))
        try write(path("transcript.txt"), try text(path("transcript.txt")).replacingOccurrences(of: "Original", with: "Text edit"))
        XCTAssertThrowsError(try load()) { XCTAssertTrue($0.localizedDescription.contains("Both")) }
        XCTAssertTrue(try text(path("transcript.json")).contains("JSON edit"))
        XCTAssertTrue(try text(path("transcript.txt")).contains("Text edit"))
        try write(path("transcript.txt"), "Plain prose cannot fabricate timestamps.")
        XCTAssertThrowsError(try load())
        let bad = try transcript("Bad time")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bad) as? [String: Any])
        var segments = try XCTUnwrap(object["segments"] as? [[String: Any]])
        segments[0]["start"] = -1
        object["segments"] = segments
        XCTAssertThrowsError(try MeetingTranscriptCodec.document(MeetingTranscriptCodec.encodeJSON(object), path: "bad-transcript.json"))
    }

    func testApprovedLegacyCopiesRemainSingleCanonicalTodosWithUnresolvedAssociationEvidence() throws {
        try seed(notes: "Notes")
        let inbox = try TasksInbox(databaseURL: support.appendingPathComponent("operational.sqlite"))
        try inbox.queueProposal(id: "meeting-action:fixture:task", title: "Original recap", sourceRef: "[[Meetings/fixture/summary#My action items|ref]]")
        try inbox.setProposalReviewState(id: "meeting-action:fixture:task", state: .accepted)
        let todo = "## Queue\n- [x] User edited recap due: 2026-01-10 [[Meetings/fixture/summary|ref]]\n"
        try write("Todos/todo.md", todo)
        let management = MeetingManagementService(vault: vault, inbox: inbox)
        let detail = try management.detail(for: "fixture")
        XCTAssertEqual(detail.myActionItems.first?.reviewState, .accepted)
        XCTAssertEqual(detail.myActionItems.first?.text, "User edited recap due: 2026-01-10 [[Meetings/fixture/summary|ref]]")
        XCTAssertTrue(try text("Todos/todo.md").contains("[[item:"))
        XCTAssertTrue(try text(path("meeting-artifacts.json")).contains("legacyMappings"))
        XCTAssertFalse(try text(path("action-items.md")).contains("- [ ] Send recap"))
        XCTAssertTrue(try text(path("meeting-artifacts.json")).contains("accepted"))
    }

    func testExistingApprovalMovesOneCheckboxToTodoAndResolvesExternalTitleCompletionAndRemovalInMeeting() throws {
        try seed(notes: "Notes")
        let inbox = try TasksInbox(databaseURL: support.appendingPathComponent("operational.sqlite"))
        let proposal = "meeting-action:fixture:task"
        try inbox.queueProposal(id: proposal, title: "Send recap", sourceRef: "[[Meetings/fixture/summary#My action items|ref]]")
        try inbox.saveProposalDraft(id: proposal, title: "User edited recap", comment: "Retain review comment")
        let management = MeetingManagementService(vault: vault, inbox: inbox)
        _ = try management.detail(for: "fixture")
        try management.reviewAction(id: proposal, accept: true)
        XCTAssertEqual(try inbox.proposalReviewState(id: proposal), .accepted)
        let todos = try TodoItemIndex(workspaceRootURL: vault.rootURL).loadTaskViews(today: "2026-01-01").queue
        XCTAssertEqual(todos.count, 1)
        XCTAssertEqual(todos[0].title, "User edited recap")
        XCTAssertNotNil(UUID(uuidString: todos[0].id))
        XCTAssertFalse(try text(path("action-items.md")).contains("- [ ] Send recap"))
        XCTAssertEqual(try management.detail(for: "fixture").myActionItems.first?.text, "User edited recap")
        try write(path("action-items.md"), try text(path("action-items.md")).replacingOccurrences(of: "- [ ] User edited recap", with: "- [x] External recap"))
        let changed = try management.detail(for: "fixture")
        XCTAssertEqual(changed.myActionItems.first?.text, "External recap")
        XCTAssertEqual(changed.myActionItems.first?.completionStatus, .done)
        try write(path("action-items.md"), "<!-- stillmatter-artifact:actions:v1 -->\n")
        XCTAssertTrue(try management.detail(for: "fixture").myActionItems.isEmpty)
    }

    func testExternalUnadoptedCheckboxReadsNeverRewriteAndExplicitSaveAdoptsOnce() throws {
        try seed(notes: "Initial")
        let initial = try load()
        let notes = initial.paths["notes"]!
        let external = "<!-- stillmatter-artifact:notes:v1 -->\nProse\u{2028}more\u{2029}\n- [ ] Newly authored #work\n"
        try write(notes, external)
        let before = try vault.readMarkdown(relativePath: notes)
        let read = try load()
        XCTAssertEqual(read.notes, "Prose\u{2028}more\u{2029}\n- [ ] Newly authored #work\n")
        XCTAssertEqual(try vault.readMarkdown(relativePath: notes).version, before.version)
        XCTAssertEqual(try text(notes), external)
        try store.saveNotes(read.notes, meetingPath: meeting, meetingID: "fixture", expected: read.notesVersion)
        let adopted = try load()
        XCTAssertTrue(adopted.notes.contains("sm-item:"))
        let id = TodoItemParser().parse(markdown: adopted.notes, relativePath: notes).first?.id
        XCTAssertNotNil(id.flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(try load().notes, adopted.notes)
    }

    func testMinimalContractMetadataAndGlobalDuplicateIDsAndInvalidApprovalMetadata() throws {
        try seed(notes: "Initial")
        _ = try load()
        let id = UUID().uuidString.lowercased()
        let minimal = "- [ ] User task <!-- sm-item:{\"id\":\"\(id)\",\"origin\":\"note\",\"owner\":\"me\",\"review\":\"approved\",\"v\":1} -->\n"
        try write(path("my-notes.md"), minimal)
        XCTAssertTrue(try load().notes.contains("User task"))
        try write(path("action-items.md"), minimal)
        XCTAssertThrowsError(try load()) { XCTAssertTrue($0.localizedDescription.contains("multiple canonical files")) }
        try write(path("action-items.md"), "")
        for (key, value) in [("review", "invented"), ("origin", "invented"), ("owner", "")] {
            let raw = minimal.replacingOccurrences(of: "\"\(key)\":\"\(key == "review" ? "approved" : key == "origin" ? "note" : "me")\"", with: "\"\(key)\":\"\(value)\"")
            try write(path("my-notes.md"), raw)
            XCTAssertThrowsError(try load()) { XCTAssertTrue($0.localizedDescription.contains("metadata")) }
            XCTAssertEqual(try text(path("my-notes.md")), raw)
        }
    }

    func testArbitrarySummaryMarkdownAndUnknownSectionsSurviveMigrationAndEditing() throws {
        try seed(notes: "Notes")
        let legacy = "---\ntitle: Custom\n---\nIntro prose\n\n## Summary\n\nCurrent summary\n\n## Custom heading\n\nUser-owned content #keep\n"
        try write(path("summary.md"), legacy)
        let loaded = try load()
        XCTAssertTrue(loaded.sections.summary.contains("Current summary"))
        XCTAssertTrue(try text(path("summary.md")).contains("## Custom heading\n\nUser-owned content #keep"))
        var sections = loaded.sections
        sections.summary = sections.summary.replacingOccurrences(of: "Current summary", with: "Edited summary")
        try store.saveSummary(sections, meetingPath: meeting, meetingID: "fixture", expected: loaded.summaryVersion)
        XCTAssertTrue(try text(path("summary.md")).contains("## Custom heading\n\nUser-owned content #keep"))
        try write(path("summary.md"), "## Arbitrary external heading\n\nValid external Markdown")
        let external = try load()
        XCTAssertTrue(external.sections.summary.contains("Valid external Markdown"))
        XCTAssertTrue(external.sections.summary.contains("Arbitrary external heading"))
    }

    func testCRLFUnicodeNotesAndNestedLegacyTodoBlockPreserveAllContentAndStableIDs() throws {
        try seed(notes: "CRLF\u{2028}prose\u{2029}\n- [ ] Note\u{2028}task\u{2029}")
        let doorway = try text(meeting).replacingOccurrences(of: "\n", with: "\r\n")
        try write(meeting, doorway)
        let todo = "## Queue\r\n\r\n- [B] Parent\u{2028}task [[Meetings/fixture/summary|ref]]\r\n  Parent comment\r\n  * [x] Child\u{2029}task due: 2026-11-01\r\n    Child comment\r\n- [ ] Unrelated personal task\r\n"
        try write("Todos/todo.md", todo)
        let first = try load()
        XCTAssertTrue(first.notes.contains("CRLF\u{2028}prose\u{2029}"), first.notes.debugDescription)
        XCTAssertTrue(first.notes.contains("Note\u{2028}task\u{2029}"))
        let canonical = try text(path("action-items.md"))
        XCTAssertTrue(canonical.contains("Parent comment\r\n"), canonical.debugDescription)
        XCTAssertTrue(canonical.contains("Child comment\r\n"))
        XCTAssertTrue(canonical.contains("Child\u{2029}task due: 2026-11-01"))
        let moved = TodoItemParser().parse(markdown: canonical, relativePath: path("action-items.md"))
        XCTAssertEqual(moved.suffix(2).map(\.status), [.blocked, .done])
        XCTAssertEqual(moved.last?.parentID, moved.dropLast().last?.id)
        XCTAssertTrue(try text("Todos/todo.md").contains("- [ ] Unrelated personal task\r\n"))
        XCTAssertFalse(try text("Todos/todo.md").contains("Parent comment"))
        XCTAssertEqual(try load().notes, first.notes)
    }

    func testReadDependencyChangeAtPreparedCheckpointPreservesLegacyFilesAndDurablePlan() throws {
        try seed(notes: "Original notes")
        try write(path("archive.json"), "{\"archived\":true}")
        let doorway = try text(meeting)
        var changed = false
        let interrupted = MeetingArtifactStore(vault: vault, inbox: nil, checkpoint: { phase in
            if phase == 0 && !changed {
                changed = true
                try self.write(self.path("archive.json"), "{\"archived\":false}")
            }
        })
        XCTAssertThrowsError(try interrupted.load(meetingPath: meeting, meetingID: "fixture"))
        XCTAssertEqual(try text(meeting), doorway)
        XCTAssertNil(try vault.versionOfMarkdown(relativePath: path("my-notes.md")))
        XCTAssertEqual(try text(path("archive.json")), "{\"archived\":false}")
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: vault.meetingArtifactStateURL, includingPropertiesForKeys: nil).isEmpty)
        XCTAssertThrowsError(try load())
    }

    func testMalformedNewerNotesPreservesUnsavedDraftAndDoesNotRewriteSource() throws {
        try seed(notes: "Original notes")
        let original = try service.detail(for: "fixture")
        let invalid = Data([0xff, 0xfe])
        let notePath = path("my-notes.md")
        _ = try vault.writeMarkdown(invalid, relativePath: notePath, expectedVersion: vault.versionOfMarkdown(relativePath: notePath))
        XCTAssertThrowsError(try service.saveHumanNotes("Unsaved draft stays recoverable", for: "fixture", expectedVersion: XCTUnwrap(original.notesVersion)))
        XCTAssertEqual(try vault.readMarkdown(relativePath: notePath).data, invalid)
        let conflicts = support.appendingPathComponent("MeetingArtifacts/Conflicts")
        let files = try FileManager.default.contentsOfDirectory(at: conflicts, includingPropertiesForKeys: nil)
        XCTAssertTrue(try files.contains { try String(contentsOf: $0).contains("Unsaved draft stays recoverable") })
    }

    func testExistingActionArtifactRetainsItsTextAndMigratedAcceptedCheckboxes() throws {
        try seed(notes: "Notes")
        try write(path("action-items.md"), "# Existing actions\n\nUser-owned introduction\n- [ ] Existing item #keep\n")
        try write("Todos/todo.md", "## Queue\n- [x] Edited accepted task [[Meetings/fixture/summary|ref]]\n  Retain original comment\n")
        _ = try load()
        let actions = try text(path("action-items.md"))
        XCTAssertTrue(actions.contains("User-owned introduction"))
        XCTAssertTrue(actions.contains("Existing item #keep"))
        XCTAssertTrue(actions.contains("Edited accepted task"))
        XCTAssertTrue(actions.contains("Retain original comment"))
        let indexed = try TodoItemIndex(workspaceRootURL: vault.rootURL).loadTaskViews(today: "2026-01-01")
        XCTAssertEqual(indexed.done.count, 1)
        XCTAssertEqual(indexed.done.first?.title, "Edited accepted task")
    }

    func testNotesAndSummaryInterruptedSavesRecoverSameDraftOnReopen() throws {
        enum Crash: Error { case injected }
        for summary in [false, true] {
            for stop in 0...1 {
                let workspace = root.appendingPathComponent("save-\(summary)-\(stop)")
                let isolated = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support.appendingPathComponent("save-\(summary)-\(stop)"))
                _ = try isolated.writeMarkdown(Data("# Legacy\n## Notes\nOriginal notes\n".utf8), relativePath: meeting, expectedVersion: nil)
                let stable = MeetingArtifactStore(vault: isolated, inbox: nil)
                let initial = try stable.load(meetingPath: meeting, meetingID: "fixture")
                let failing = MeetingArtifactStore(vault: isolated, inbox: nil, checkpoint: { if $0 == stop { throw Crash.injected } })
                if summary {
                    var sections = initial.sections
                    sections.summary = "Saved Summary draft"
                    XCTAssertThrowsError(try failing.saveSummary(sections, meetingPath: meeting, meetingID: "fixture", expected: initial.summaryVersion))
                } else {
                    XCTAssertThrowsError(try failing.saveNotes("Saved note draft", meetingPath: meeting, meetingID: "fixture", expected: initial.notesVersion))
                }
                let reopened = try stable.load(meetingPath: meeting, meetingID: "fixture")
                XCTAssertEqual(summary ? reopened.sections.summary : reopened.notes, summary ? "Saved Summary draft" : "Saved note draft")
                XCTAssertEqual(try stable.load(meetingPath: meeting, meetingID: "fixture").notes, reopened.notes)
            }
        }
    }

    func testTranscriptPairEveryWriteCheckpointRecoversConsistentSourceTimingAndText() throws {
        enum Crash: Error { case injected }
        for stop in 0...2 {
            let workspace = root.appendingPathComponent("pair-\(stop)")
            let isolated = WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support.appendingPathComponent("pair-\(stop)"))
            _ = try isolated.writeMarkdown(Data("# Legacy\n".utf8), relativePath: meeting, expectedVersion: nil)
            let stable = MeetingArtifactStore(vault: isolated, inbox: nil)
            _ = try stable.load(meetingPath: meeting, meetingID: "fixture")
            let source = try transcript("Pair source\u{2028}preserved")
            _ = try isolated.writeMarkdown(source, relativePath: path("transcript.json"), expectedVersion: nil)
            let failing = MeetingArtifactStore(vault: isolated, inbox: nil, checkpoint: { if $0 == stop { throw Crash.injected } })
            XCTAssertThrowsError(try failing.load(meetingPath: meeting, meetingID: "fixture"))
            let recovered = try stable.load(meetingPath: meeting, meetingID: "fixture")
            XCTAssertEqual(recovered.transcript?.segments.first?.text, "Pair source\u{2028}preserved")
            XCTAssertEqual(recovered.transcript?.segments.first?.startSeconds, 1.125)
            let plain = try isolated.readMarkdown(relativePath: path("transcript.txt")).data
            let json = try isolated.readMarkdown(relativePath: path("transcript.json")).data
            XCTAssertEqual(try MeetingTranscriptCodec.json(plain, path: "transcript.txt"), try MeetingTranscriptCodec.canonicalJSON(json))
        }
    }

    func testArchivedUIEditsRejectedWhileValidExternalFilesRemainAuthoritative() throws {
        try seed(notes: "Archived original")
        try write(path("archive.json"), "{\"archived\":true}")
        let archived = try service.detail(for: "fixture")
        XCTAssertThrowsError(try service.saveHumanNotes("Disallowed edit", for: "fixture", expectedVersion: XCTUnwrap(archived.notesVersion)))
        XCTAssertThrowsError(try service.saveSummary(try XCTUnwrap(archived.summary), for: "fixture", expectedVersion: XCTUnwrap(archived.summaryVersion)))
        try write(path("my-notes.md"), "Explicit valid external archive edit")
        XCTAssertEqual(try service.detail(for: "fixture").humanNotes, "Explicit valid external archive edit")
        XCTAssertTrue(try service.detail(for: "fixture").row.isArchived)
    }
}
