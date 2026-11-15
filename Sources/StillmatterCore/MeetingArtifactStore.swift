import Foundation

/// Owns canonical Meeting text, migration and its file-aware consistency boundary.
/// Jobs and derived indexes may refer to these files; neither is a competing content store.
final class MeetingArtifactStore {
    struct Loaded {
        let notes: String
        let notesVersion: WorkspaceFileVersion
        let sections: MeetingSummarySections
        let summaryVersion: WorkspaceFileVersion
        let extraction: MeetingSummaryExtraction
        let transcript: TranscriptDocument?
        let paths: [String: String]
        let versions: [String: WorkspaceFileVersion]
        let reviewStates: [String: ProposalReviewState]
        let completionStates: [String: TodoStatus]
        var speakerCorrectionRevision: String?
        var speakerCorrectionReview: [MeetingSpeakerCorrectionReview] = []
        var analysisOutdated = false
        var speakerReviewRequired = false
    }
    private struct Manifest: Codable {
        var version = 1
        let meetingID: String
        var meetingPath: String
        var files: [String: String]
        var transcriptBaseHash: String?
        var speakerCorrections: [MeetingSpeakerCorrection]?
        var speakerCorrectionRevision: String?
        var analysisSpeakerRevision: String?
        var transcriptSessionID: String?
        var legacyReview: [String: String]
        var reviewIntents: [String: String] = [:]
        var legacyMappings: [String: [String]]?
        var archiveDateUnknown: Bool
    }
    private typealias Item = MeetingItemMetadata
    private static let lock = NSRecursiveLock()
    private static let names = ["notes": "my-notes.md", "summary": "summary.md", "actions": "action-items.md", "decisions": "decisions.md", "open": "open-items.md"]
    private let vault: WorkspaceVault
    private let inbox: TasksInbox?
    private let checkpoint: (Int) throws -> Void

    init(vault: WorkspaceVault, inbox: TasksInbox?, checkpoint: @escaping (Int) throws -> Void = { _ in }) {
        self.vault = vault
        self.inbox = inbox
        self.checkpoint = checkpoint
    }

    func identity(at meetingPath: String) throws -> String? {
        try manifest(at: sibling(meetingPath, "meeting-artifacts.json"))?.meetingID
    }

    /// Today must not adopt files, replay transactions or update review state just by viewing them.
    func pendingReviewCount(meetingPath: String, meetingID: String) throws -> Int {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try MeetingArtifactTransaction(vault: vault, identity: meetingID).readPublished {
            try MeetingArtifactTransaction(vault: vault, identity: "workspace-tags").requirePublished()
            return try publishedPendingReviewCount(meetingPath: meetingPath, meetingID: meetingID)
        }
    }

    private func publishedPendingReviewCount(meetingPath: String, meetingID: String) throws -> Int {
        let state = try manifest(at: sibling(meetingPath, "meeting-artifacts.json"))
        let path = try artifactPath("actions", meetingPath: meetingPath, state: state)
        if let source = try optional(path) {
            let text = try decode(source.data, path: path)
            _ = try validateItems(text, path: path)
            var notePendingCount = 0
            if let state {
                guard state.meetingID == meetingID else { throw malformed(meetingPath, "The artifact manifest identity changed.") }
                var contents = ["actions": text], resolvedPaths = ["actions": path]
                for kind in ["notes", "decisions", "open"] {
                    let otherPath = try artifactPath(kind, meetingPath: meetingPath, state: state)
                    contents[kind] = try decode(vault.readMarkdown(relativePath: otherPath).data, path: otherPath)
                    resolvedPaths[kind] = otherPath
                }
                try validateCanonicalItems(contents, paths: resolvedPaths, meetingPath: meetingPath)
                notePendingCount = TodoItemParser().parse(markdown: contents["notes"] ?? "", relativePath: resolvedPaths["notes"] ?? "").filter {
                    TodoItemParser.metadata(in: $0.rawText)?.review == "pending"
                }.count
            }
            return notePendingCount + TodoItemParser().parse(markdown: text, relativePath: path).filter {
                TodoItemParser.metadata(in: $0.rawText)?.review == "pending"
                    || (state == nil && TodoItemParser.metadata(in: $0.rawText) == nil)
            }.count
        }
        guard state == nil else { throw malformed(path, "The canonical Action Items file is missing.") }
        guard let source = try optional(sibling(meetingPath, "summary-extraction.json")) else { return 0 }
        let extraction = try JSONDecoder().decode(MeetingSummaryExtraction.self, from: source.data)
        guard extraction.meeting == meetingPath, extraction.schemaVersion == MeetingSummaryExtraction.currentSchemaVersion else {
            throw malformed(meetingPath, "Summary identity or version does not match this Meeting.")
        }
        return try (extraction.myActionItems + extraction.otherActionItems).filter {
            let review = try inbox?.proposalReviewState(id: "meeting-action:\(meetingID):\($0.id)")
            return review == nil || review == .pending
        }.count
    }

    private func artifactPath(_ kind: String, meetingPath: String, state: Manifest?, paths: [String]? = nil) throws -> String {
        let directory = (meetingPath as NSString).deletingLastPathComponent
        let candidates = try paths ?? vault.markdownPaths(relativeTo: directory)
        let identified = try candidates.filter { path in
            guard (path as NSString).deletingLastPathComponent == directory else { return false }
            return hasArtifactMarker(kind, in: try decode(vault.readMarkdown(relativePath: path).data, path: path))
        }
        let name = try required(Self.names[kind], path: meetingPath, field: "artifact kind")
        guard identified.count <= 1 else { throw malformed(name, "Multiple files claim this artifact identity. Keep one canonical file.") }
        return identified.first ?? state?.files[kind].map { sibling(meetingPath, ($0 as NSString).lastPathComponent) }
            ?? sibling(meetingPath, name)
    }

    /// Compatibility while the existing recorder/producer still owns legacy files.
    /// No file adoption occurs until capture and its current processing work finish.
    func legacyLoaded(meetingPath: String, meetingID: String) throws -> Loaded {
        let doorway = try vault.readMarkdown(relativePath: meetingPath)
        let text = try decode(doorway.data, path: meetingPath)
        let range = legacyNotesRange(in: text)
        let notesPath = sibling(meetingPath, "my-notes.md")
        let separate = try optional(notesPath)
        let notes = try separate.map { try decode($0.data, path: notesPath) }
            ?? (range.map { String(text[$0.bodyStart..<$0.end]) } ?? "")
        let summaryPath = sibling(meetingPath, "summary.md")
        let summary = try optional(summaryPath)
        let summaryText = try summary.map { try decode($0.data, path: summaryPath) } ?? ""
        let extractionPath = sibling(meetingPath, "summary-extraction.json")
        let extraction = try optional(extractionPath).map { try JSONDecoder().decode(MeetingSummaryExtraction.self, from: $0.data) }
            ?? MeetingSummaryExtraction(meeting: meetingPath, transcript: sibling(meetingPath, "transcript.json"), decisions: [], myActionItems: [], otherActionItems: [], openQuestions: [])
        let transcriptPath = sibling(meetingPath, "transcript.json")
        let transcript = try optional(transcriptPath).map { try MeetingTranscriptCodec.document($0.data, path: transcriptPath) }
        let reviews = try Dictionary(uniqueKeysWithValues: extraction.myActionItems.map {
            ($0.id, try inbox?.proposalReviewState(id: "meeting-action:" + meetingID + ":" + $0.id) ?? .referenceOnly)
        })
        return Loaded(notes: notes, notesVersion: separate?.version ?? doorway.version,
            sections: MeetingSummarySections(summary: summaryText), summaryVersion: summary?.version ?? doorway.version,
            extraction: extraction, transcript: transcript, paths: ["notes": separate == nil ? meetingPath : notesPath, "summary": summaryPath],
            versions: summary.map { ["notes": separate?.version ?? doorway.version, "summary": $0.version] } ?? ["notes": separate?.version ?? doorway.version], reviewStates: reviews, completionStates: [:])
    }

    func load(meetingPath: String, meetingID: String) throws -> Loaded {
        try ItemTagStore(vault: vault).recover()
        Self.lock.lock(); defer { Self.lock.unlock() }
        let transaction = MeetingArtifactTransaction(vault: vault, identity: meetingID, checkpoint: checkpoint)
        try transaction.recover()
        let statePath = sibling(meetingPath, "meeting-artifacts.json")
        var migrated = false
        if try manifest(at: statePath) == nil {
            if let pair = try MeetingTranscriptCodec.reconcile(baseHash: nil,
                text: optional(sibling(meetingPath, "transcript.txt"))?.data,
                json: optional(sibling(meetingPath, "transcript.json"))?.data, path: sibling(meetingPath, "transcript")) {
                let document = try MeetingTranscriptCodec.document(pair.json, path: sibling(meetingPath, "transcript.json"))
                guard document.meetingRelativePath == meetingPath, meetingID == meetingPath || document.captureSessionID == meetingID else {
                    throw malformed(sibling(meetingPath, "transcript.json"), "Transcript identity does not match this Meeting.")
                }
            }
            try migrate(meetingPath: meetingPath, meetingID: meetingID, transaction: transaction)
            migrated = true
        }
        if migrated {
            _ = try MeetingNoteTodoBridge(vault: vault).adoptSavedNotes(at: sibling(meetingPath, "my-notes.md"))
        }
        let stateSource = try vault.readMarkdown(relativePath: statePath)
        var state = try JSONDecoder().decode(Manifest.self, from: stateSource.data)
        guard state.version == 1, state.meetingID == meetingID else { throw malformed(statePath, "The artifact manifest identity or version changed. Restore its valid source before reloading.") }
        for (id, raw) in state.reviewIntents {
            if let review = ProposalReviewState(rawValue: raw), let current = try inbox?.proposalReviewState(id: id) {
                if current != review { try inbox?.setProposalReviewState(id: id, state: review) }
                state.reviewIntents.removeValue(forKey: id)
            }
        }
        var replacements: [WorkspaceMarkdownReplacement] = []
        var contents: [String: String] = [:]
        var versions: [String: WorkspaceFileVersion] = [:]
        let paths = try vault.markdownPaths(relativeTo: (meetingPath as NSString).deletingLastPathComponent)
        for kind in Self.names.keys {
            let path = try artifactPath(kind, meetingPath: meetingPath, state: state, paths: paths)
            guard let source = try optional(path) else { throw malformed(path, "The canonical file is missing. Restore it or its artifact identity, then Reload Latest.") }
            let full = try decode(source.data, path: path)
            let body = try removingMarker(kind, from: full)
            contents[kind] = body
            versions[kind] = source.version
            state.files[kind] = path
            // Reads preserve valid external text, including unadopted checkboxes.
            // Identity is assigned only by initial migration or an explicit save.
            _ = try validateItems(body, path: path)

        }
        try validateCanonicalItems(contents, paths: state.files, meetingPath: meetingPath)
        let jsonPath = sibling(meetingPath, "transcript.json"), textPath = sibling(meetingPath, "transcript.txt")
        var transcript: TranscriptDocument?
        let textSource = try optional(textPath), jsonSource = try optional(jsonPath)
        if let pair = try MeetingTranscriptCodec.reconcile(baseHash: state.transcriptBaseHash,
            text: textSource?.data, json: jsonSource?.data, path: sibling(meetingPath, "transcript")) {
            var pair = pair
            let document = try MeetingTranscriptCodec.document(pair.json, path: jsonPath)
            guard document.meetingRelativePath == meetingPath || document.meetingRelativePath == state.meetingPath,
                  (state.transcriptSessionID.map { document.captureSessionID == $0 } ?? (meetingID == meetingPath || document.captureSessionID == meetingID)) else {
                throw malformed(jsonPath, "Transcript identity does not match this Meeting. Restore its correct source files before reloading.")
            }
            if document.meetingRelativePath != meetingPath {
                guard var object = try JSONSerialization.jsonObject(with: pair.json) as? [String: Any] else {
                    throw malformed(jsonPath, "Transcript root must be a JSON object. Restore valid Transcript data before reloading.")
                }
                object["meeting_relative_path"] = meetingPath
                pair.json = try MeetingTranscriptCodec.encodeJSON(object)
                pair.text = try MeetingTranscriptCodec.text(pair.json)
            }
            if var corrections = state.speakerCorrections, !corrections.isEmpty {
                guard var object = try JSONSerialization.jsonObject(with: pair.json) as? [String: Any],
                      var segments = object["segments"] as? [[String: Any]] else {
                    throw malformed(jsonPath, "Transcript segments must be objects.")
                }
                if let revision = state.speakerCorrectionRevision, object["speaker_identity_revision"] as? String == revision {
                    let edited = MeetingSpeakerCorrection.acceptingExternalNames(corrections, from: document)
                    if edited != corrections {
                        corrections = edited; state.speakerCorrections = edited
                        state.speakerCorrectionRevision = UUID().uuidString
                    }
                }
                let sourceSegments = Dictionary(grouping: document.segments, by: MeetingSpeakerCorrection.Source.init)
                for (index, segment) in document.segments.enumerated() {
                    let matches = corrections.filter { $0.sources.contains(where: { $0.matches(segment) }) }
                    if matches.count == 1, sourceSegments[MeetingSpeakerCorrection.Source(segment)]?.count == 1 {
                        segments[index]["speaker"] = matches[0].name
                    }
                }
                object["segments"] = segments
                object["speaker_identity_revision"] = state.speakerCorrectionRevision
                pair.json = try MeetingTranscriptCodec.encodeJSON(object)
                pair.text = try MeetingTranscriptCodec.text(pair.json)
            }
            transcript = try MeetingTranscriptCodec.document(pair.json, path: jsonPath)
            for (path, data) in [(jsonPath, pair.json), (textPath, pair.text)] {
                let current = path == jsonPath ? jsonSource : textSource
                let unchangedJSON = try path == jsonPath && current.map { try MeetingTranscriptCodec.canonicalJSON($0.data) == data } == true
                if current?.data != data && !unchangedJSON { replacements.append(.init(relativePath: path, data: data, expectedVersion: current?.version)) }
            }
            state.transcriptBaseHash = MeetingTranscriptCodec.hash(pair.json)
            state.transcriptSessionID = document.captureSessionID
        }
        state.meetingPath = meetingPath
        let stateData = try JSONEncoder().encode(state)
        let oldState = stateSource
        if stateData != oldState.data {
            // Encode with stable keys so an unchanged read does not cause a write loop.
            guard let currentState = try JSONSerialization.jsonObject(with: stateData) as? NSDictionary,
                  let previousState = try JSONSerialization.jsonObject(with: oldState.data) as? NSDictionary else {
                throw malformed(statePath, "The artifact manifest must be a JSON object. Restore its valid source before reloading.")
            }
            if !currentState.isEqual(previousState) {
                replacements.append(.init(relativePath: statePath, data: stateData, expectedVersion: oldState.version))
            }
        }
        if !replacements.isEmpty {
            try transaction.publish(replacements)
        }
        let actionPath = try required(state.files["actions"], path: statePath, field: "action-items path")
        let actionContent = try required(contents["actions"], path: statePath, field: "action-items content")
        let actionItems = try outcomes(actionContent, path: actionPath)
        let exposedIDs = actionItems.map { $0.outcome.id }
        guard Set(exposedIDs).count == exposedIDs.count else { throw malformed(actionPath, "Duplicate legacy item references require explicit resolution.") }
        let summaryContent = try required(contents["summary"], path: statePath, field: "summary content")
        let decisionsContent = try required(contents["decisions"], path: statePath, field: "decisions content")
        let openContent = try required(contents["open"], path: statePath, field: "open-items content")
        let notesContent = try required(contents["notes"], path: statePath, field: "notes content")
        let notesVersion = try required(versions["notes"], path: statePath, field: "notes version")
        let sections = MeetingSummarySections(summary: String(summaryContent.dropFirst(try frontmatter(summaryContent).count)), decisions: decisionsContent,
            myActionItems: actionContent, otherActionItems: "", openQuestions: openContent)
        let extraction = MeetingSummaryExtraction(meeting: meetingPath, transcript: jsonPath,
            decisions: try outcomes(decisionsContent, path: required(state.files["decisions"], path: statePath, field: "decisions path")).map(\.outcome),
            myActionItems: actionItems.filter { $0.item.owner == "me" }.map(\.outcome),
            otherActionItems: actionItems.filter { $0.item.owner != "me" }.map(\.outcome),
            openQuestions: try outcomes(openContent, path: required(state.files["open"], path: statePath, field: "open-items path")).map(\.outcome))
        var loaded = Loaded(notes: notesContent, notesVersion: notesVersion, sections: sections,
            summaryVersion: try combined(versions.filter { $0.key != "notes" }), extraction: extraction,
            transcript: transcript, paths: state.files, versions: versions,
            reviewStates: Dictionary(uniqueKeysWithValues: actionItems.map { item in
                (item.outcome.id, item.item.review == "approved" ? .accepted : item.item.review == "rejected" ? .dismissed : ProposalReviewState(rawValue: item.item.review) ?? .pending)
            }), completionStates: Dictionary(uniqueKeysWithValues: actionItems.compactMap { value in value.completion.map { (value.outcome.id, $0) } }))
        loaded.speakerCorrectionRevision = state.speakerCorrectionRevision
        loaded.analysisOutdated = state.speakerCorrectionRevision != state.analysisSpeakerRevision
        let sourceSegments = Dictionary(grouping: transcript?.segments ?? [], by: MeetingSpeakerCorrection.Source.init)
        loaded.speakerCorrectionReview = (state.speakerCorrections ?? []).flatMap { correction in
            correction.sources.filter { sourceSegments[$0]?.count != 1 }.map {
                MeetingSpeakerCorrectionReview(name: correction.name, track: $0.track, startSeconds: $0.start, endSeconds: $0.end)
            }
        }
        loaded.speakerReviewRequired = !loaded.speakerCorrectionReview.isEmpty
        return loaded
    }

    func correctSpeaker(source expectedSource: MeetingTranscriptSegment, name: String, meetingPath: String, meetingID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200, !name.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) else {
            throw malformed(meetingPath, "Enter a speaker name of 1–200 characters on one line.")
        }
        let loaded = try load(meetingPath: meetingPath, meetingID: meetingID)
        guard let document = loaded.transcript, let segment = document.segments.first(where: { $0.id == expectedSource.id }) else {
            throw malformed(meetingPath, "This Transcript source changed. Reload Latest before correcting it.")
        }
        guard segment.startSeconds == expectedSource.startSeconds, segment.endSeconds == expectedSource.endSeconds,
              segment.track.speakerLabel == expectedSource.track, segment.speaker == expectedSource.speaker,
              document.segments.filter({ MeetingSpeakerCorrection.Source(segment).matches($0) }).count == 1 else {
            throw malformed(meetingPath, "This speaker source changed or has ambiguous timing. Reload Latest and review its evidence before correcting it.")
        }
        let statePath = sibling(meetingPath, "meeting-artifacts.json")
        let source = try vault.readMarkdown(relativePath: statePath)
        var state = try JSONDecoder().decode(Manifest.self, from: source.data)
        var corrections = state.speakerCorrections ?? []
        if let index = corrections.firstIndex(where: { $0.sources.contains(where: { $0.matches(segment) }) }) {
            corrections[index].name = name
        } else {
            corrections.append(MeetingSpeakerCorrection(name: name, sources: MeetingSpeakerCorrection.sources(for: segment, in: document)))
        }
        state.speakerCorrections = corrections
        state.speakerCorrectionRevision = UUID().uuidString
        try MeetingArtifactTransaction(vault: vault, identity: meetingID, checkpoint: checkpoint).publish([
            .init(relativePath: statePath, data: try JSONEncoder().encode(state), expectedVersion: source.version)
        ])
        _ = try load(meetingPath: meetingPath, meetingID: meetingID)
    }

    /// Existing analysis producers publish into the current canonical files rather
    /// than creating a second set of outcomes after a Meeting has been migrated.
    /// Exact text/owner matches are safe to suppress; shared evidence alone needs user review.
    func reconcileGeneratedActions(_ extraction: MeetingSummaryExtraction, base: Loaded) throws -> MeetingSummaryExtraction {
        let actions = try outcomes(base.sections.myActionItems, path: base.paths["actions"] ?? extraction.meeting)
        let protected = actions.filter { $0.item.origin != "generated" || $0.item.review != "pending" }
            + (try outcomes(base.notes, path: base.paths["notes"] ?? extraction.meeting))
        func normalized(_ text: String) -> String {
            ItemTags.replacing(in: text, with: [])
                .replacingOccurrences(of: #"\b(?:due|done):\s*\d{4}-\d{2}-\d{2}\b"#, with: "", options: .regularExpression)
                .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        func reconcile(_ values: [MeetingOutcome], owner: String?) -> [MeetingOutcome] {
            var seen: Set<String> = []
            return values.compactMap { value in
                let evidence = value.citations.map { "\($0.segmentID):\($0.startSeconds):\($0.endSeconds)" }.sorted().joined(separator: ";")
                guard seen.insert(normalized(value.text) + "\n" + evidence).inserted else { return nil }
                let sameText = protected.filter { $0.item.owner == owner && normalized($0.outcome.text) == normalized(value.text) }
                let exact = sameText.filter { record in
                    record.outcome.citations.isEmpty || value.citations.contains { record.outcome.citations.contains($0) }
                }
                if exact.count == 1 { return nil }
                let sameIdentity = protected.filter { $0.outcome.id == value.id || $0.item.id == value.id.lowercased() }
                // A stable approved identity remains protected even when the model rewrites it.
                if sameIdentity.contains(where: { $0.item.review == "approved" }) { return nil }
                let ambiguous = !sameText.isEmpty || !sameIdentity.isEmpty || protected.contains { record in
                    record.outcome.citations.contains { value.citations.contains($0) }
                }
                guard ambiguous else { return value }
                let id = sameIdentity.isEmpty ? value.id : "reprocess-" + SHA256Hex.digest(Data((value.id + value.text + (owner ?? "")).utf8))
                return MeetingOutcome(id: id, text: ItemTags.replacing(in: value.text,
                    with: ItemTags.read(value.text) + ["possible-duplicate"]), citations: value.citations)
            }
        }
        return MeetingSummaryExtraction(schemaVersion: extraction.schemaVersion, meeting: extraction.meeting, transcript: extraction.transcript,
            decisions: extraction.decisions, myActionItems: reconcile(extraction.myActionItems, owner: "me"),
            otherActionItems: reconcile(extraction.otherActionItems, owner: nil), openQuestions: extraction.openQuestions,
            tagAdditions: extraction.tagAdditions)
    }

    func publishGenerated(summary: Data, extraction: MeetingSummaryExtraction, extractionData: Data,
                          base: Loaded, meetingPath: String, meetingID: String,
                          expectedExtraction: WorkspaceFileVersion?) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let actionsPath = try required(base.paths["actions"], path: meetingPath, field: "action-items path")
        let currentItems = try outcomes(base.sections.myActionItems, path: actionsPath)
        let preserved = currentItems.filter { $0.item.origin != "generated" || $0.item.review != "pending" }
        let preservedIDs = Set(preserved.compactMap { $0.item.legacyID })
        let oldGenerated = Dictionary(uniqueKeysWithValues: currentItems.filter { $0.item.origin == "generated" }.map { ($0.outcome.id, $0.item) })
        var retainedLines: [String] = []
        for raw in base.sections.myActionItems.components(separatedBy: "\n") {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if let start = line.range(of: "<!-- sm-item:"), line.hasSuffix(" -->") {
                let metadata = try decodeItem(Data(line[start.upperBound..<line.index(line.endIndex, offsetBy: -4)].utf8), path: actionsPath)
                if metadata.origin == "generated" && metadata.review == "pending" { continue }
            }
            retainedLines.append(raw)
        }
        let previousOutcomes = try outcomes(base.sections.decisions, path: base.paths["decisions"] ?? meetingPath)
            + outcomes(base.sections.openQuestions, path: base.paths["open"] ?? meetingPath)
        func render(_ values: [MeetingOutcome], owner: String?, checkboxes: Bool) throws -> String {
            try values.filter { !checkboxes || !preservedIDs.contains($0.id) }.map { value in
                let old = checkboxes ? oldGenerated[value.id] : previousOutcomes.first { $0.outcome.id == value.id }?.item
                let metadata = Item(v: 1, id: old?.id ?? UUID().uuidString.lowercased(), owner: owner,
                    review: "pending", origin: "generated", legacyID: value.id, citations: value.citations)
                let oldTags = currentItems.first(where: { $0.outcome.id == value.id }).map { ItemTags.read($0.outcome.text) } ?? []
                let text = checkboxes ? ItemTags.replacing(in: value.text, with: ItemTags.read(value.text) + oldTags + ["ai-gen", "need-approve"]) : value.text
                return (checkboxes ? "- [ ] " : "- ") + text
                    + " <!-- sm-item:" + String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self) + " -->"
            }.joined(separator: "\n")
        }
        let mine = try render(extraction.myActionItems, owner: "me", checkboxes: true)
        let others = try render(extraction.otherActionItems, owner: nil, checkboxes: true)
        let summaryPath = try required(base.paths["summary"], path: meetingPath, field: "summary path")
        var values = ["summary": try decode(summary, path: summaryPath),
            "actions": (retainedLines + [mine, others]).joined(separator: "\n"),
            "decisions": try render(extraction.decisions, owner: nil, checkboxes: false),
            "open": try render(extraction.openQuestions, owner: nil, checkboxes: false)]
        let additions = extraction.tagAdditions ?? []
        let tagChanges = try ItemTagStore(vault: vault).prepareAIAdditions(additions,
            allowedPaths: Set([actionsPath, base.paths["notes"]].compactMap { $0 }))
        let actionIDs = Set(currentItems.map { $0.item.id })
        let actionPatches = additions.filter { actionIDs.contains($0.itemID.lowercased()) }
        if !actionPatches.isEmpty {
            var matched: Set<String> = []
            values["actions"] = values["actions"]!.components(separatedBy: "\n").map { line in
                guard let metadata = TodoItemParser.metadata(in: line) else { return line }
                let patches = actionPatches.filter { $0.itemID.lowercased() == metadata.id }
                if !patches.isEmpty { matched.insert(metadata.id) }
                return ItemTags.replacing(in: line, with: ItemTags.read(line) + patches.flatMap(\.tags))
            }.joined(separator: "\n")
            guard matched == Set(actionPatches.map { $0.itemID.lowercased() }) else {
                throw malformed(actionsPath, "An AI tag target is no longer present in the generated actions. Retry with current items.")
            }
        }
        var replacements = tagChanges.filter { $0.relativePath != actionsPath }
        for kind in values.keys.sorted() {
            let path = try required(base.paths[kind], path: meetingPath, field: "\(kind) path")
            let content = try required(values[kind], path: meetingPath, field: "\(kind) content")
            replacements.append(.init(relativePath: path, data: Data(try wrapped(kind, content).utf8), expectedVersion: base.versions[kind]))
        }
        replacements.append(.init(relativePath: sibling(meetingPath, "summary-extraction.json"), data: extractionData, expectedVersion: expectedExtraction))
        let statePath = sibling(meetingPath, "meeting-artifacts.json")
        let stateSource = try vault.readMarkdown(relativePath: statePath)
        var state = try JSONDecoder().decode(Manifest.self, from: stateSource.data)
        guard state.speakerCorrectionRevision == base.speakerCorrectionRevision else {
            throw malformed(statePath, "Speaker identities changed during analysis. Retry using the current Transcript.")
        }
        state.analysisSpeakerRevision = state.speakerCorrectionRevision
        replacements.append(.init(relativePath: statePath, data: try JSONEncoder().encode(state), expectedVersion: stateSource.version))
        try MeetingArtifactTransaction(vault: vault, identity: meetingID, checkpoint: checkpoint).publish(replacements)
    }

    func saveNotes(_ text: String, meetingPath: String, meetingID: String, expected: WorkspaceFileVersion) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let loaded = try load(meetingPath: meetingPath, meetingID: meetingID)
        let path = try required(loaded.paths["notes"], path: meetingPath, field: "notes path")
        guard loaded.notesVersion == expected else {
            try keepConflict(text, external: loaded.notes, meetingID: meetingID, path: path)
            throw WorkspaceVaultError.conflict(relativePath: path, expected: expected, actual: loaded.notesVersion)
        }
        let canonical = try adopting(text, path: path, kind: "notes")
        let prepared = try MeetingNoteTodoBridge(vault: vault)
            .prepareArtifactSave(canonical, at: path, replacing: loaded.notes)
        let adopted = prepared.notes
        try validateCanonicalItems(["notes": adopted, "actions": loaded.sections.myActionItems,
                                    "decisions": loaded.sections.decisions, "open": loaded.sections.openQuestions],
                                   paths: loaded.paths, meetingPath: meetingPath)
        var replacements = [WorkspaceMarkdownReplacement(
            relativePath: path, data: Data(try wrapped("notes", adopted).utf8), expectedVersion: expected
        )]
        if let todoReplacement = prepared.todoReplacement { replacements.append(todoReplacement) }
        try MeetingArtifactTransaction(vault: vault, identity: meetingID, checkpoint: checkpoint).publish(replacements)
    }

    func saveSummary(_ sections: MeetingSummarySections, meetingPath: String, meetingID: String, expected: WorkspaceFileVersion) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let loaded = try load(meetingPath: meetingPath, meetingID: meetingID)
        guard loaded.summaryVersion == expected else {
            let path = try required(loaded.paths["summary"], path: meetingPath, field: "summary path")
            try keepConflict(sections.summary, external: loaded.sections.summary, meetingID: meetingID, path: path)
            throw WorkspaceVaultError.conflict(relativePath: path, expected: expected, actual: loaded.summaryVersion)
        }
        let values = ["summary": sections.summary, "decisions": sections.decisions, "actions": sections.myActionItems, "open": sections.openQuestions]
        var replacements: [WorkspaceMarkdownReplacement] = []
        var proposedContents = ["notes": loaded.notes]
        for (kind, body) in values {
            let path = try required(loaded.paths[kind], path: meetingPath, field: "\(kind) path")
            let old = try vault.readMarkdown(relativePath: path)
            guard old.version == loaded.versions[kind] else { throw WorkspaceVaultError.conflict(relativePath: path, expected: loaded.versions[kind], actual: old.version) }
            let canonicalBody: String
            if kind == "summary" {
                let existing = try removingMarker(kind, from: decode(old.data, path: path))
                canonicalBody = try frontmatter(existing) + body
            } else { canonicalBody = try adopting(body, path: path, kind: kind) }
            proposedContents[kind] = canonicalBody
            let data = Data(try wrapped(kind, canonicalBody).utf8)
            if old.data != data { replacements.append(.init(relativePath: path, data: data, expectedVersion: old.version)) }
        }
        try validateCanonicalItems(proposedContents, paths: loaded.paths, meetingPath: meetingPath)
        try MeetingArtifactTransaction(vault: vault, identity: meetingID, checkpoint: checkpoint).publish(replacements)
    }

    /// Compatibility for the current personal approval UI: a queue reference exposes
    /// the same canonical checkbox; retries cannot copy another task.
    func review(proposalID: String, accept: Bool, meetingPath: String, meetingID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let loaded = try load(meetingPath: meetingPath, meetingID: meetingID)
        let path = try required(loaded.paths["actions"], path: meetingPath, field: "action-items path")
        let source = try vault.readMarkdown(relativePath: path)
        let original = try decode(source.data, path: path)
        let records = try outcomes(original.replacingOccurrences(of: marker("actions") + "\n", with: ""), path: path)
        guard let record = records.first(where: { "meeting-action:\(meetingID):" + ($0.item.legacyID ?? $0.item.id) == proposalID }) else {
            throw MeetingManagementError.notFound(proposalID)
        }
        if record.item.review == "approved" || record.item.review == "rejected" { return }
        guard !accept || record.item.owner == "me" else { throw malformed(path, "Assign the Action Item to a known owner before approval.") }
        var item = record.item
        item.review = accept ? "approved" : "rejected"
        let metadata = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
        guard let oldLine = try original.components(separatedBy: "\n").first(where: { raw in
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard let start = line.range(of: "<!-- sm-item:"), line.hasSuffix(" -->") else { return false }
            return try decodeItem(Data(line[start.upperBound..<line.index(line.endIndex, offsetBy: -4)].utf8), path: path).id == item.id
        }) else { throw malformed(path, "Action Item identity changed during review. Reload the Meeting and try again.") }
        var replacements: [WorkspaceMarkdownReplacement] = []
        let newLine: String
        if accept {
            let todoPath = TodoItemIndex.mainTodoRelativePath
            let oldTodo = try optional(todoPath)
            let text = try oldTodo.map { try decode($0.data, path: todoPath) } ?? "# Todos\n\n## Queue\n"
            let title = try inbox?.proposalDraft(id: proposalID)?.title ?? record.outcome.text
            let clean = title.replacingOccurrences(of: #"(?:^|\s)#need-approve\b"#, with: "", options: .regularExpression)
            let updated = TodoItemMutator.insertingInQueue([TodoItemDraft(title: "[[item:" + item.id + "|" + clean.replacingOccurrences(of: "|", with: " ") + "]]" )], into: text)
                .replacingOccurrences(of: "- [ ] [[item:" + item.id + "|", with: "- [[item:" + item.id + "|")
            replacements.append(.init(relativePath: todoPath, data: Data(updated.utf8), expectedVersion: oldTodo?.version))
            newLine = "- [ ] " + clean + " <!-- sm-item:" + metadata + " -->"
        } else {
            newLine = oldLine.replacingOccurrences(of: #"<!-- sm-item:.* -->$"#, with: "<!-- sm-item:" + metadata + " -->", options: .regularExpression)
        }
        replacements.append(.init(relativePath: path, data: Data(original.replacingOccurrences(of: oldLine, with: newLine + (oldLine.hasSuffix("\r") ? "\r" : "")).utf8), expectedVersion: source.version))
        let statePath = sibling(meetingPath, "meeting-artifacts.json"), oldState = try vault.readMarkdown(relativePath: statePath)
        var state = try JSONDecoder().decode(Manifest.self, from: oldState.data)
        state.reviewIntents[proposalID] = accept ? "accepted" : "dismissed"
        replacements.append(.init(relativePath: statePath, data: try JSONEncoder().encode(state), expectedVersion: oldState.version))
        try MeetingArtifactTransaction(vault: vault, identity: meetingID, checkpoint: checkpoint).publish(replacements)
        _ = try load(meetingPath: meetingPath, meetingID: meetingID)
    }

    private func migrate(meetingPath: String, meetingID: String, transaction: MeetingArtifactTransaction) throws {
        let doorway = try vault.readMarkdown(relativePath: meetingPath)
        let doorwayText = try decode(doorway.data, path: meetingPath)
        let oldSummary = try optional(sibling(meetingPath, "summary.md"))
        let summary = try oldSummary.map { try decode($0.data, path: sibling(meetingPath, "summary.md")) } ?? ""
        let oldExtraction = try optional(sibling(meetingPath, "summary-extraction.json"))
        let extraction = try oldExtraction.map { try JSONDecoder().decode(MeetingSummaryExtraction.self, from: $0.data) }
        let notePath = sibling(meetingPath, "my-notes.md")
        let oldNotes = try optional(notePath)
        let range = legacyNotesRange(in: doorwayText)
        let embedded = range.map { String(doorwayText[$0.bodyStart..<$0.end]) } ?? ""
        let notes = try oldNotes.map { try decode($0.data, path: notePath) } ?? embedded
        if oldNotes != nil && !embedded.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")).isEmpty &&
            notes.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")) != embedded.trimmingCharacters(in: CharacterSet(charactersIn: "\r\n")) {
            throw malformed(notePath, "This separate file and the doorway's embedded Notes differ. Both are preserved; resolve the two versions before migration.")
        }
        if let extraction, extraction.meeting != meetingPath || extraction.transcript != sibling(meetingPath, "transcript.json") {
            throw malformed(sibling(meetingPath, "summary-extraction.json"), "Legacy extraction belongs to another Meeting. Restore the correct source before migration.")
        }
        let todoPath = TodoItemIndex.mainTodoRelativePath
        let oldTodo = try optional(todoPath)
        var reviews: [String: String] = [:]
        func render(_ values: [MeetingOutcome], owner: String?, checkboxes: Bool) throws -> String {
            try values.map { value in
                let proposal = "meeting-action:\(meetingID):\(value.id)"
                let review = try inbox?.proposalReviewState(id: proposal) ?? .pending
                reviews[proposal] = review.rawValue
                let item = Item(v: 1, id: UUID().uuidString.lowercased(), owner: owner,
                    review: review == .accepted ? "approved" : review.rawValue,
                    origin: "generated", legacyID: value.id, citations: value.citations)
                let comment = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
                if checkboxes && (review == .accepted || review == .merged) {
                    // Old copied Todos have no proposal ID; their canonical blocks migrate below.
                    return "" // The approved legacy checkbox is migrated once below; never guess a proposal binding.
                }
                let prefix = checkboxes ? "- [ ] " : "- "
                let text = checkboxes ? (try inbox?.proposalDraft(id: proposal)?.title ?? value.text) : value.text
                return prefix + text + (checkboxes && review == .pending ? " #ai-gen #need-approve" : "") + " <!-- sm-item:\(comment) -->"
            }.joined(separator: "\n")
        }
        var migratedTodos: [String] = []
        var migratedIDs: [String] = []
        var todoLines = (try oldTodo.map { try decode($0.data, path: todoPath) } ?? "").components(separatedBy: "\n")
        let parsedTodos = TodoItemParser().parse(markdown: todoLines.joined(separator: "\n"), relativePath: todoPath)
        var consumed: Set<Int> = []
        for parent in parsedTodos where parent.parentID == nil {
            let start = parent.location.lineNumber - 1
            var end = start + 1
            while end < todoLines.count {
                let line = todoLines[end]
                if line.hasPrefix("## ") || (TodoMarkdownCheckbox.parse(line).map { $0.indentation <= parent.indentation } ?? false) { break }
                end += 1
            }
            let blockItems = parsedTodos.filter { (start..<end).contains($0.location.lineNumber - 1) }
            guard blockItems.contains(where: { $0.rawText.contains("[[" + (meetingPath as NSString).deletingLastPathComponent + "/") }) else { continue }
            var block = Array(todoLines[start..<end])
            for task in blockItems {
                let index = task.location.lineNumber - 1
                guard consumed.insert(index).inserted else { continue }
                let line = todoLines[index], hasCR = line.hasSuffix("\r")
                let body = hasCR ? String(line.dropLast()) : line
                let item: Item
                if let metadata = body.range(of: "<!-- sm-item:") {
                    item = try decodeItem(Data(body[metadata.upperBound..<body.index(body.endIndex, offsetBy: -4)].utf8), path: todoPath)
                } else {
                    item = Item(v: 1, id: UUID().uuidString.lowercased(), owner: "me", review: "approved", origin: "legacy-todo", legacyID: nil, citations: [])
                }
                migratedIDs.append(item.id)
                block[index - start] = body.range(of: "<!-- sm-item:") == nil
                    ? body + " <!-- sm-item:" + String(decoding: try JSONEncoder().encode(item), as: UTF8.self) + " -->" + (hasCR ? "\r" : "") : line
                let indentation = String(body.prefix { $0 == " " || $0 == "\t" })
                todoLines[index] = indentation + "- [[item:" + item.id + "|" + task.title.replacingOccurrences(of: "|", with: " ") + "]]" + (hasCR ? "\r" : "")
            }
            // Comments remain with the canonical block, not mutable copies in the queue.
            for index in start..<end where !consumed.contains(index) { todoLines[index] = "" }
            migratedTodos.append(block.joined(separator: "\n") + (end < todoLines.count ? "\n" : ""))
        }
        var mine = extraction?.myActionItems ?? []
        let known = Set(mine.map(\.id))
        for proposal in try inbox?.items(category: .review) ?? [] where proposal.kind == .proposal && proposal.id.hasPrefix("meeting-action:\(meetingID):") {
            let id = String(proposal.id.dropFirst("meeting-action:\(meetingID):".count))
            if extraction == nil && !known.contains(id) { mine.append(MeetingOutcome(id: id, text: proposal.title, citations: [])) }
        }
        var bodies = ["notes": try adopting(notes, path: notePath, kind: "notes"), "summary": summary,
            "actions": try render(mine, owner: "me", checkboxes: true),
            "decisions": try render(extraction?.decisions ?? [], owner: nil, checkboxes: false),
            "open": try render(extraction?.openQuestions ?? [], owner: nil, checkboxes: false)]
        let otherActions = try render(extraction?.otherActionItems ?? [], owner: nil, checkboxes: true)
        if !otherActions.isEmpty || !migratedTodos.isEmpty {
            guard var actions = bodies["actions"] else { throw malformed(meetingPath, "Legacy action-items content is missing; no files were changed.") }
            if !otherActions.isEmpty { actions += "\n" + otherActions }
            if !migratedTodos.isEmpty { actions += "\n" + migratedTodos.joined(separator: "\n") }
            bodies["actions"] = actions
        }

        for (kind, heading) in [("decisions", "Decisions"), ("open", "Open questions")] {
            let edited = section(heading, in: summary, missing: "")
            if !edited.isEmpty {
                let name = try required(Self.names[kind], path: meetingPath, field: "\(kind) filename")
                bodies[kind] = try adopting(edited, path: sibling(meetingPath, name), kind: kind)
            }
        }
        // A previously authored separate artifact always wins over generated/embedded content.
        var replacements: [WorkspaceMarkdownReplacement] = []
        var files: [String: String] = [:]
        for (kind, name) in Self.names.sorted(by: { $0.key < $1.key }) {
            let path = sibling(meetingPath, name), old = try optional(path)
            var body: String
            if kind == "summary" { body = try required(bodies[kind], path: meetingPath, field: "summary content") }
            else if let old {
                body = try decode(old.data, path: path)
                if kind == "actions" && !migratedTodos.isEmpty { body += "\n" + migratedTodos.joined(separator: "\n") }
            }
            else { body = try required(bodies[kind], path: meetingPath, field: "\(kind) content") }
            files[kind] = path
            let normalized = try removingMarker(kind, from: body)
            let canonicalBody = kind == "summary" ? normalized : try adopting(normalized, path: path, kind: kind)
            replacements.append(.init(relativePath: path, data: Data(try wrapped(kind, canonicalBody).utf8), expectedVersion: old?.version))
        }
        if let range {
            let updated = doorwayText.replacingCharacters(in: range.headingStart..<range.end, with: "## My Notes\n\n[[my-notes]]\n\n")
            replacements.append(.init(relativePath: meetingPath, data: Data(updated.utf8), expectedVersion: doorway.version))
        }
        var plannedIDs: Set<String> = []
        for replacement in replacements where replacement.relativePath != meetingPath && replacement.relativePath != files["summary"] {
            let ids = try validateItems(decode(replacement.data, path: replacement.relativePath), path: replacement.relativePath)
            guard plannedIDs.isDisjoint(with: ids) else { throw malformed(replacement.relativePath, "Duplicate canonical identities require explicit resolution before migration.") }
            plannedIDs.formUnion(ids)
        }
        if !migratedTodos.isEmpty {
            replacements.append(.init(relativePath: todoPath, data: Data(todoLines.joined(separator: "\n").utf8), expectedVersion: oldTodo?.version))
        }
        let archive = try optional(sibling(meetingPath, "archive.json"))
        let archived = try archive.map { try JSONSerialization.jsonObject(with: $0.data) as? [String: Any] }
        let state = Manifest(meetingID: meetingID, meetingPath: meetingPath, files: files, legacyReview: reviews,
            legacyMappings: Dictionary(uniqueKeysWithValues: reviews.filter { $0.value == "accepted" || $0.value == "merged" }.map { ($0.key, migratedIDs) }), archiveDateUnknown: archived??["archived"] as? Bool == true)
        replacements.append(.init(relativePath: sibling(meetingPath, "meeting-artifacts.json"), data: try JSONEncoder().encode(state), expectedVersion: nil))
        let dependencies = [(todoPath, oldTodo), (sibling(meetingPath, "summary-extraction.json"), oldExtraction), (sibling(meetingPath, "archive.json"), archive)].map {
            WorkspaceMarkdownReplacement(relativePath: $0.0, data: $0.1?.data ?? Data(), expectedVersion: $0.1?.version)
        }
        try transaction.publish(replacements, dependencies: dependencies)
    }

    private func outcomes(_ text: String, path: String) throws -> [(item: Item, outcome: MeetingOutcome, completion: TodoStatus?)] {
        var result: [(Item, MeetingOutcome, TodoStatus?)] = [], ids: Set<String> = []
        for line in text.components(separatedBy: "\n").map({ $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let start = line.range(of: "<!-- sm-item:"),
                  line.hasSuffix(" -->") else {
                continue // Prose/headings/code are valid Markdown, not fabricated outcomes.
            }
            let json = String(line[start.upperBound..<line.index(line.endIndex, offsetBy: -4)])
            let item = try decodeItem(Data(json.utf8), path: path)
            guard item.v == 1, UUID(uuidString: item.id) != nil, ids.insert(item.id).inserted else {
                throw malformed(path, "An item has invalid or duplicate identity metadata. Restore its unique ID.")
            }
            var body = String(line[..<start.lowerBound]).trimmingCharacters(in: .whitespaces)
            body = body.replacingOccurrences(of: #"^- (?:\[[ xXbBcC]\] )?"#, with: "", options: .regularExpression)
            let completion = TodoMarkdownCheckbox.parse(line)?.status

            result.append((item, MeetingOutcome(id: item.legacyID ?? item.id, text: body, citations: item.citations), completion))
        }
        return result
    }

    private func legacyNotesRange(in text: String) -> (headingStart: String.Index, bodyStart: String.Index, end: String.Index)? {
        var offset = 0
        var heading: (start: Int, body: Int)?
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
            if let heading, line.hasPrefix("## ") {
                return (String.Index(utf16Offset: heading.start, in: text), String.Index(utf16Offset: heading.body, in: text), String.Index(utf16Offset: offset, in: text))
            }
            if line == "## Notes" || line == "## Live notes" { heading = (offset, min(offset + raw.utf16.count + 1, text.utf16.count)) }
            offset += raw.utf16.count + 1
        }
        return heading.map { (String.Index(utf16Offset: $0.start, in: text), String.Index(utf16Offset: $0.body, in: text), text.endIndex) }
    }

    private func adopting(_ text: String, path: String, kind: String) throws -> String {
        var ids: Set<String> = [], fence: Character?
        func adoptLine(_ line: String) throws -> String {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if fence == trimmed.first { fence = nil } else if fence == nil { fence = trimmed.first }
                return line
            }
            guard fence == nil else { return line }
            let checkbox = TodoMarkdownCheckbox.parse(line) != nil
            guard kind == "notes" ? checkbox : (checkbox || trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ")) else { return line }
            if let marker = line.range(of: "<!-- sm-item:") {
                guard line.hasSuffix(" -->") else { throw malformed(path, "Close the item's sm-item metadata comment.") }
                let data = Data(line[marker.upperBound..<line.index(line.endIndex, offsetBy: -4)].utf8)
                let item = try decodeItem(data, path: path)
                guard ids.insert(item.id).inserted else { throw malformed(path, "Restore unique item identity metadata.") }
                return line
            }
            let item = Item(v: 1, id: UUID().uuidString.lowercased(), owner: kind == "notes" ? "me" : nil,
                review: kind == "notes" ? "approved" : "pending", origin: kind == "notes" ? "note" : "manual", legacyID: nil, citations: [])
            return line + " <!-- sm-item:" + String(decoding: try JSONEncoder().encode(item), as: UTF8.self) + " -->"
        }
        return try text.components(separatedBy: "\n").map { raw in
            let carriageReturn = raw.hasSuffix("\r")
            return try adoptLine(carriageReturn ? String(raw.dropLast()) : raw) + (carriageReturn ? "\r" : "")
        }.joined(separator: "\n")
    }

    private func validateCanonicalItems(_ contents: [String: String], paths: [String: String], meetingPath: String) throws {
        var canonicalIDs: Set<String> = []
        for kind in ["notes", "actions", "decisions", "open"] {
            let content = try required(contents[kind], path: meetingPath, field: "\(kind) content")
            let path = try required(paths[kind], path: meetingPath, field: "\(kind) path")
            let ids = try validateItems(content, path: path)
            guard canonicalIDs.isDisjoint(with: ids) else {
                throw malformed(path, "The same item ID appears in multiple canonical files. Keep one checkbox and use references.")
            }
            canonicalIDs.formUnion(ids)
        }
    }

    private func validateItems(_ text: String, path: String) throws -> Set<String> {
        var ids: Set<String> = []
        for line in text.components(separatedBy: "\n").map({ $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }) {
            guard let range = line.range(of: "<!-- sm-item:") else { continue }
            guard line.hasSuffix(" -->") else { throw malformed(path, "Close the item's identity metadata comment and Reload Latest.") }
            let item = try decodeItem(Data(line[range.upperBound..<line.index(line.endIndex, offsetBy: -4)].utf8), path: path)
            guard ids.insert(item.id).inserted else { throw malformed(path, "Duplicate item identity requires explicit repair.") }
        }
        return ids
    }

    private func decodeItem(_ data: Data, path: String) throws -> Item {
        do {
            let item = try JSONDecoder().decode(Item.self, from: data)
            guard item.v == 1, UUID(uuidString: item.id) != nil,
                  ["approved", "pending", "rejected", "dismissed", "referenceOnly", "merged"].contains(item.review),
                  ["note", "generated", "legacy-todo", "manual"].contains(item.origin),
                  item.owner == nil || item.owner?.isEmpty == false else {
                throw malformed(path, "Invalid item identity, owner, origin or approval state.")
            }
            return item
        }
        catch { throw malformed(path, "Item metadata is malformed: \(error.localizedDescription) Restore its identity comment and Reload Latest.") }
    }

    private func manifest(at path: String) throws -> Manifest? {
        guard let source = try optional(path) else { return nil }
        let state: Manifest
        do { state = try JSONDecoder().decode(Manifest.self, from: source.data) }
        catch { throw malformed(path, "The artifact manifest is malformed. Restore its saved version before Reload Latest.") }
        guard state.version == 1 else { throw malformed(path, "Unsupported artifact schema. Update Stillmatter or restore a supported file.") }
        return state
    }
    private func optional(_ path: String) throws -> (data: Data, version: WorkspaceFileVersion)? {
        guard try vault.versionOfMarkdown(relativePath: path) != nil else { return nil }
        return try vault.readMarkdown(relativePath: path)
    }
    private func decode(_ data: Data, path: String) throws -> String {
        guard let text = String(data: data, encoding: .utf8) else { throw malformed(path, "The file is not readable UTF-8. Restore its encoding and Reload Latest.") }
        return text
    }
    private func wrapped(_ kind: String, _ body: String) throws -> String {
        let front = kind == "summary" ? try frontmatter(body) : ""
        return front + marker(kind) + "\n" + body.dropFirst(front.count)
    }
    private func hasArtifactMarker(_ kind: String, in text: String) -> Bool {
        let front = kind == "summary" ? ((try? frontmatter(text)) ?? "") : ""
        let body = text.dropFirst(front.count)
        return body.hasPrefix(marker(kind) + "\n") || body.hasPrefix(marker(kind) + "\r\n") || body == marker(kind)
    }
    private func removingMarker(_ kind: String, from text: String) throws -> String {
        let front = kind == "summary" ? try frontmatter(text) : ""
        let body = text.dropFirst(front.count)
        for header in [marker(kind) + "\r\n", marker(kind) + "\n", marker(kind)] where body.hasPrefix(header) {
            return front + body.dropFirst(header.count)
        }
        return text
    }
    private func marker(_ kind: String) -> String { "<!-- stillmatter-artifact:\(kind):v1 -->" }
    private func sibling(_ path: String, _ name: String) -> String { (path as NSString).deletingLastPathComponent + "/" + name }
    private func malformed(_ path: String, _ reason: String) -> MeetingManagementError { .malformed("\(path): \(reason)") }
    private func section(_ name: String, in markdown: String, missing: String? = nil) -> String {
        guard let heading = markdown.range(of: "(?m)^## " + NSRegularExpression.escapedPattern(for: name) + "[ \\t]*$", options: .regularExpression) else { return missing ?? markdown }
        let end = markdown.range(of: #"(?m)^## [^\n]+$"#, options: .regularExpression, range: heading.upperBound..<markdown.endIndex)?.lowerBound ?? markdown.endIndex
        return String(markdown[heading.upperBound..<end]).trimmingCharacters(in: .newlines)
    }
    private func frontmatter(_ markdown: String) throws -> String {
        let body = markdown
        guard body.hasPrefix("---\n") || body.hasPrefix("---\r\n") else { return "" }
        guard let end = body.range(of: "\n---\n", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex)
            ?? body.range(of: "\r\n---\r\n", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) else {
            throw malformed("summary.md", "Close the YAML frontmatter with --- before saving.")
        }
        return String(body[..<end.upperBound])
    }
    private func combined(_ versions: [String: WorkspaceFileVersion]) throws -> WorkspaceFileVersion {
        guard let modificationDate = versions.values.map(\.modificationDate).max() else {
            throw malformed("meeting-artifacts.json", "No canonical artifact versions are available. Restore the missing files before reloading.")
        }
        let contentHash = try versions.keys.sorted().map { key in
            key + ":" + (try required(versions[key], path: "meeting-artifacts.json", field: "\(key) version")).contentHash
        }.joined(separator: "|")
        return WorkspaceFileVersion(contentHash: contentHash, modificationDate: modificationDate,
            byteCount: versions.values.reduce(0) { $0 + $1.byteCount })
    }
    private func required<Value>(_ value: Value?, path: String, field: String) throws -> Value {
        guard let value else { throw malformed(path, "Missing required \(field). Restore the artifact state and Reload Latest.") }
        return value
    }
    func keepConflict(_ draft: String, external: String, meetingID: String, path: String) throws {
        let record = ["meeting": meetingID, "path": path, "draft": draft, "external": external]
        let directory = vault.meetingArtifactStateURL.appendingPathComponent("Conflicts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
    }
}

extension MeetingArtifactStore {
    func reviewItems(meetingPath: String, meetingID: String) throws -> [MeetingReviewItem] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let loaded = try load(meetingPath: meetingPath, meetingID: meetingID)
        return try ["actions", "notes"].flatMap { kind -> [MeetingReviewItem] in
            let path = try required(loaded.paths[kind], path: meetingPath, field: kind)
            let source = try vault.readMarkdown(relativePath: path)
            return String(decoding: source.data, as: UTF8.self).components(separatedBy: "\n").compactMap { line in
                guard let checkbox = TodoMarkdownCheckbox.parse(line), let metadata = TodoItemParser.metadata(in: checkbox.text) else { return nil }
                let parsed = TodoItemParser().parse(markdown: line, relativePath: path)[0]
                return MeetingReviewItem(id: metadata.id, text: parsed.title, owner: metadata.owner,
                    review: metadata.review, status: checkbox.status, dueDate: parsed.dueDate,
                    citations: metadata.citations, path: path, version: source.version, rawLine: line, origin: metadata.origin)
            }
        }
    }

    /// Publishes every selected review decision, its queue references and legacy review
    /// intents in one recoverable plan. Repeating an already committed decision is a no-op.
    func reviewItems(_ expected: [MeetingReviewItem], accept: Bool, meetingPath: String, meetingID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let current = try reviewItems(meetingPath: meetingPath, meetingID: meetingID)
        var changes: [(MeetingReviewItem, String)] = []
        var seen: Set<String> = []
        let statePath = sibling(meetingPath, "meeting-artifacts.json")
        let stateSource = try vault.readMarkdown(relativePath: statePath)
        var state = try JSONDecoder().decode(Manifest.self, from: stateSource.data)
        for item in expected where seen.insert(item.id).inserted {
            guard let actual = current.first(where: { $0.id == item.id }) else { throw MeetingManagementError.notFound(item.id) }
            let decision = accept ? "approved" : "rejected"
            if actual.review == decision { continue }
            guard actual.isPending, actual.rawLine == item.rawLine else { throw TodoItemMutationError.staleCanonicalItem(item.id) }
            guard !accept || actual.hasOwner else { throw malformed(actual.path, "Assign an owner before approval.") }
            var metadata = try required(TodoItemParser.metadata(in: actual.rawLine), path: actual.path, field: "item metadata")
            metadata.review = decision
            let body = actual.rawLine.replacingOccurrences(of: #"\s*<!-- sm-item:.* -->\r?$"#, with: "", options: .regularExpression)
            let clean = accept ? body.replacingOccurrences(of: #"(?:^|\s)#need-approve\b"#, with: "", options: .regularExpression) : body
            changes.append((actual, clean + " <!-- sm-item:" + String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self) + " -->"))
            if let legacyID = metadata.legacyID {
                state.reviewIntents["meeting-action:\(meetingID):\(legacyID)"] = accept ? "accepted" : "dismissed"
            }
        }
        guard !changes.isEmpty else { return }
        try publishItemChanges(changes, meetingID: meetingID, additional: [
            .init(relativePath: statePath, data: try JSONEncoder().encode(state), expectedVersion: stateSource.version)
        ])
        _ = try load(meetingPath: meetingPath, meetingID: meetingID)
    }

    func editReviewItem(_ expected: MeetingReviewItem, text: String, owner: String?, dueDate: String?, status: TodoStatus,
                        meetingPath: String, meetingID: String) throws {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let owner = owner?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(where: \.isNewline), !text.contains("<!--"),
              owner?.contains(where: \.isNewline) != true else { throw malformed(expected.path, "Enter task text and owner on one line.") }
        if let dueDate {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
            guard let date = formatter.date(from: dueDate), formatter.string(from: date) == dueDate else {
                throw malformed(expected.path, "Use a valid due date in YYYY-MM-DD format, or leave it empty.")
            }
        }
        let current = try reviewItems(meetingPath: meetingPath, meetingID: meetingID)
        guard let actual = current.first(where: { $0.id == expected.id }), actual.rawLine == expected.rawLine else {
            throw TodoItemMutationError.staleCanonicalItem(expected.id)
        }
        guard actual.status != .done || status == .done else { throw malformed(actual.path, "Completed items cannot be reopened in the app.") }
        guard actual.review != "approved" || (owner != nil && owner != "" && owner != "unknown") else {
            throw malformed(actual.path, "Approved items require an owner.")
        }
        let old = try required(TodoItemParser.metadata(in: actual.rawLine), path: actual.path, field: "item metadata")
        let metadata = Item(v: old.v, id: old.id, owner: owner == "" ? nil : owner, review: old.review,
            origin: old.origin, legacyID: old.legacyID, citations: old.citations)
        let marker: String
        switch status { case .open: marker = " "; case .blocked: marker = "B"; case .done: marker = "x"; case .canceled: marker = "C" }
        let sourceRef = TodoItemParser().parse(markdown: actual.rawLine, relativePath: actual.path)[0].sourceRef
        let taggedText = ItemTags.replacing(in: text, with: ItemTags.read(text) + actual.tags)
        let body = ([taggedText, dueDate.map { "due: " + $0 }, sourceRef].compactMap { $0 }).joined(separator: " ")
        let line = "- [\(marker)] " + body + " <!-- sm-item:" + String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self) + " -->"
        try publishItemChanges([(actual, line)], meetingID: meetingID)
    }

    private func publishItemChanges(_ changes: [(MeetingReviewItem, String)], meetingID: String,
                                    additional: [WorkspaceMarkdownReplacement] = []) throws {
        var replacements = additional
        for path in Set(changes.map { $0.0.path }).sorted() {
            let source = try vault.readMarkdown(relativePath: path)
            var lines = String(decoding: source.data, as: UTF8.self).components(separatedBy: "\n")
            for (item, line) in changes where item.path == path {
                guard let index = lines.firstIndex(of: item.rawLine) else { throw TodoItemMutationError.staleCanonicalItem(item.id) }
                lines[index] = line
            }
            replacements.append(.init(relativePath: path, data: Data(lines.joined(separator: "\n").utf8), expectedVersion: source.version))
        }
        let queuePath = TodoItemIndex.mainTodoRelativePath
        let queue = try optional(queuePath)
        var queueText = queue.map { String(decoding: $0.data, as: UTF8.self) } ?? "# Todos\n\n## Queue\n\n## Done\n"
        var newReferences: [TodoItemDraft] = []
        for (item, line) in changes {
            let metadata = try required(TodoItemParser.metadata(in: line), path: item.path, field: "item metadata")
            let personal = metadata.owner == "me" && metadata.review == "approved"
            let reference = "[[item:" + item.id.lowercased()
            let hasReference = queueText.components(separatedBy: "\n").contains { $0.contains(reference + "|") || $0.contains(reference + "]]") }
            if !personal {
                queueText = queueText.components(separatedBy: "\n").filter { !$0.contains(reference + "|") && !$0.contains(reference + "]]") }.joined(separator: "\n")
            } else if !hasReference {
                let title = TodoItemParser().parse(markdown: line, relativePath: item.path)[0].title.replacingOccurrences(of: "|", with: " ").replacingOccurrences(of: "]]", with: "")
                newReferences.append(TodoItemDraft(title: reference + "|" + title + "]]"))
            }
        }
        if !newReferences.isEmpty {
            queueText = TodoItemMutator.insertingInQueue(newReferences, into: queueText)
            for (item, _) in changes {
                queueText = queueText.replacingOccurrences(of: "- [ ] [[item:" + item.id.lowercased(), with: "- [[item:" + item.id.lowercased())
            }
        }
        if queue?.data != Data(queueText.utf8) {
            replacements.append(.init(relativePath: queuePath, data: Data(queueText.utf8), expectedVersion: queue?.version))
        }
        try MeetingArtifactTransaction(vault: vault, identity: meetingID, checkpoint: checkpoint).publish(replacements)
    }
}
