import Foundation
import AVFoundation

public enum MeetingCaptureDisplayState: String, Equatable { case live, stopped, unavailable }
public enum MeetingProcessingState: String, Equatable, CaseIterable { case live, processing, needsAttention, ready, unavailable
    public var displayName: String { switch self { case .live: return "Live"; case .processing: return "Processing"; case .needsAttention: return "Needs attention"; case .ready: return "Ready"; case .unavailable: return "Unavailable" } }
}
public enum MeetingProcessingFilter: Equatable { case all, live, processing, needsAttention, ready, notFinished, unavailable }
public struct MeetingBrowserFilters: Equatable {
    public var query: String; public var startDate: Date?; public var endDate: Date?; public var project: String?; public var processing: MeetingProcessingFilter; public var archived: Bool
    public init(query: String = "", startDate: Date? = nil, endDate: Date? = nil, project: String? = nil, processing: MeetingProcessingFilter = .all, archived: Bool = false) { self.query=query; self.startDate=startDate; self.endDate=endDate; self.project=project; self.processing=processing; self.archived=archived }
}
public enum MeetingArtifactRole: String, Equatable { case doorway, recordingBundle, source, transcript, summary, extraction }
public struct MeetingArtifact: Equatable { public let role: MeetingArtifactRole; public let relativePath: String; public let available: Bool; public let message: String?
    public init(role: MeetingArtifactRole, relativePath: String, available: Bool, message: String? = nil) { self.role=role; self.relativePath=relativePath; self.available=available; self.message=message }
}
public struct MeetingJobPresentation: Equatable, Identifiable { public let jobID: String; public let title: String; public let status: JobStatus; public let stage: String?; public let error: String?; public let attemptCount: Int; public let retryReason: String?
    public var id: String { jobID }
    public init(jobID: String, title: String, status: JobStatus, stage: String?, error: String?, attemptCount: Int = 0, retryReason: String? = nil) { self.jobID=jobID; self.title=title; self.status=status; self.stage=stage; self.error=error; self.attemptCount=attemptCount; self.retryReason=retryReason }
}
public struct MeetingCitation: Equatable { public let segmentID: String; public let startSeconds: Double; public let endSeconds: Double; public let seekSeconds: Double?
    public init(segmentID: String, startSeconds: Double, endSeconds: Double, seekSeconds: Double? = nil) { self.segmentID=segmentID; self.startSeconds=startSeconds; self.endSeconds=endSeconds; self.seekSeconds=seekSeconds }
}
public struct MeetingCitedOutcome: Equatable { public let text: String; public let citations: [MeetingCitation]
    public init(text: String, citations: [MeetingCitation]) { self.text = text; self.citations = citations }
}
public struct MeetingActionItem: Equatable { public let id: String; public let text: String; public let citations: [MeetingCitation]; public let reviewState: ProposalReviewState; public let referenceOnly: Bool
    public init(id: String, text: String, citations: [MeetingCitation], reviewState: ProposalReviewState = .referenceOnly, referenceOnly: Bool = false) { self.id=id; self.text=text; self.citations=citations; self.reviewState=reviewState; self.referenceOnly=referenceOnly }
}
public struct MeetingSummarySections: Equatable { public var summary: String; public var decisions: String; public var myActionItems: String; public var otherActionItems: String; public var openQuestions: String
    public init(summary: String = "", decisions: String = "", myActionItems: String = "", otherActionItems: String = "", openQuestions: String = "") { self.summary=summary; self.decisions=decisions; self.myActionItems=myActionItems; self.otherActionItems=otherActionItems; self.openQuestions=openQuestions }
}
public struct MeetingBrowserRow: Equatable, Identifiable { public let id: String; public let title: String; public let startedAt: Date?; public let meetingRelativePath: String; public let captureState: MeetingCaptureDisplayState; public let processingState: MeetingProcessingState; public let project: String?; public let job: MeetingJobPresentation?; public let isArchived: Bool
    public let durationSeconds: Double?
    public let hasRecording: Bool
    public let hasMyActions: Bool
    public let hasOthersActions: Bool
    public let needsActionReview: Bool
    public init(id: String, title: String, startedAt: Date?, meetingRelativePath: String, captureState: MeetingCaptureDisplayState, processingState: MeetingProcessingState = .unavailable, project: String? = nil, job: MeetingJobPresentation? = nil, isArchived: Bool = false, durationSeconds: Double? = nil, hasRecording: Bool = false, hasMyActions: Bool = false, hasOthersActions: Bool = false, needsActionReview: Bool = false) { self.id=id; self.title=title; self.startedAt=startedAt; self.meetingRelativePath=meetingRelativePath; self.captureState=captureState; self.processingState=processingState; self.project=project; self.job=job; self.isArchived=isArchived; self.durationSeconds=durationSeconds; self.hasRecording=hasRecording; self.hasMyActions=hasMyActions; self.hasOthersActions=hasOthersActions; self.needsActionReview=needsActionReview }
    public var displayTitle: String {
        let prefix = "Untitled Meeting at "
        return title.hasPrefix(prefix) ? String(title.dropFirst(prefix.count)) : title
    }
    public var requiresAttention: Bool { job?.status == .failed || processingState == .needsAttention || needsActionReview }
}
public struct MeetingPlayback: Equatable {
    public enum Capability: Equatable { case mixed, microphoneOnly, unavailable }
    public let capability: Capability
    public let microphonePath: String?
    public let systemPath: String?
    public let durationSeconds: Double
    public let microphoneOffsetSeconds: Double
    public let systemOffsetSeconds: Double
    public let message: String
    public init(capability: Capability, microphonePath: String? = nil, systemPath: String? = nil, durationSeconds: Double = 0,
                microphoneOffsetSeconds: Double = 0, systemOffsetSeconds: Double = 0, message: String) {
        self.capability = capability; self.microphonePath = microphonePath; self.systemPath = systemPath
        self.durationSeconds = durationSeconds; self.microphoneOffsetSeconds = microphoneOffsetSeconds
        self.systemOffsetSeconds = systemOffsetSeconds; self.message = message
    }
}
public struct MeetingTranscriptSegment: Equatable, Identifiable { public let id: String; public let startSeconds: Double; public let endSeconds: Double; public let track: String; public let speaker: String; public let text: String; public let seekSeconds: Double? }
public struct MeetingBrowserDetail: Equatable { public let decisions: [MeetingCitedOutcome]; public let openQuestions: [MeetingCitedOutcome]; public let transcript: [MeetingTranscriptSegment]; public let row: MeetingBrowserRow; public let doorwayText: String; public let doorwayVersion: WorkspaceFileVersion?; public let humanNotes: String; public let artifacts: [MeetingArtifact]; public let job: MeetingJobPresentation?; public let jobs: [MeetingJobPresentation]; public let summaryVersion: WorkspaceFileVersion?; public let summary: MeetingSummarySections?; public let extraction: MeetingSummaryExtraction?; public let myActionItems: [MeetingActionItem]; public let otherActionItems: [MeetingActionItem]; public let staleProposals: [ActionItemProposal]; public let playback: MeetingPlayback
    public init(row: MeetingBrowserRow, doorwayText: String, doorwayVersion: WorkspaceFileVersion? = nil, humanNotes: String = "", artifacts: [MeetingArtifact] = [], job: MeetingJobPresentation? = nil, jobs: [MeetingJobPresentation] = [], summaryVersion: WorkspaceFileVersion? = nil, summary: MeetingSummarySections? = nil, extraction: MeetingSummaryExtraction? = nil, myActionItems: [MeetingActionItem] = [], otherActionItems: [MeetingActionItem] = [], staleProposals: [ActionItemProposal] = [], transcript: [MeetingTranscriptSegment] = [], decisions: [MeetingCitedOutcome] = [], openQuestions: [MeetingCitedOutcome] = [], playback: MeetingPlayback = MeetingPlayback(capability: .unavailable, message: "Recording Bundle unavailable")) { self.decisions=decisions; self.openQuestions=openQuestions; self.transcript=transcript; self.playback=playback; self.row=row; self.doorwayText=doorwayText; self.doorwayVersion=doorwayVersion; self.humanNotes=humanNotes; self.artifacts=artifacts; self.job=job; self.jobs=jobs; self.summaryVersion=summaryVersion; self.summary=summary; self.extraction=extraction; self.myActionItems=myActionItems; self.otherActionItems=otherActionItems; self.staleProposals=staleProposals }
}
public enum MeetingManagementError: Error, Equatable, LocalizedError { case unavailable; case malformed(String); case notFound(String); case retryRejected(String)
    public var errorDescription: String? { if case let .retryRejected(reason) = self { return reason }; return "Meeting processing is unavailable." }
}

public final class MeetingManagementService {
    private let vault: WorkspaceVault; private let jobs: JobStore?; private let inbox: TasksInbox?; private let index: SearchIndex?; private let captureSnapshot: () -> CaptureSnapshot?
    private let retryDispatcher: (String, String, String, String?) throws -> Void
    private let retryUnavailableReason: (String) -> String?
    private let onReprocessQueued: () -> Void
    public init(vault: WorkspaceVault, jobStore: JobStore? = nil, inbox: TasksInbox? = nil, searchIndex: SearchIndex? = nil, captureSnapshot: @escaping () -> CaptureSnapshot? = { nil }, retryUnavailableReason: @escaping (String) -> String? = { _ in "Retry unavailable: processing is not configured." }, retryDispatcher: @escaping (String, String, String, String?) throws -> Void = { _, _, _, _ in throw MeetingManagementError.retryRejected("Retry unavailable: processing is not configured.") }, onReprocessQueued: @escaping () -> Void = {}) { self.vault=vault; self.jobs=jobStore; self.inbox=inbox; self.index=searchIndex; self.captureSnapshot=captureSnapshot; self.retryUnavailableReason=retryUnavailableReason; self.retryDispatcher=retryDispatcher; self.onReprocessQueued=onReprocessQueued }
    public func list() throws -> [MeetingBrowserRow] { try list(filters: MeetingBrowserFilters()) }
    public func list(filters: MeetingBrowserFilters) throws -> [MeetingBrowserRow] {
        try filter(allRows(), using: filters)
    }

    /// Supplies project choices and filtered rows from the same workspace scan.
    public func browserRows(filters: MeetingBrowserFilters) throws -> (visible: [MeetingBrowserRow], available: [MeetingBrowserRow]) {
        let rows = try allRows()
        let available = rows.filter { $0.isArchived == filters.archived }
        return (try filter(available, using: filters), available)
    }

    private func filter(_ rows: [MeetingBrowserRow], using filters: MeetingBrowserFilters) throws -> [MeetingBrowserRow] {
        let query = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let indexedPaths = try matchingMeetingPaths(for: query, rows: rows)
        return rows.filter { row in
            guard row.isArchived == filters.archived else { return false }
            guard indexedPaths == nil || indexedPaths?.contains(row.meetingRelativePath) == true else { return false }
            if let date = filters.startDate, row.startedAt.map({ $0 < date }) ?? true { return false }
            if let date = filters.endDate {
                let exclusiveEnd = Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date
                if row.startedAt.map({ $0 >= exclusiveEnd }) ?? true { return false }
            }
            if let project = filters.project, row.project != project { return false }
            switch filters.processing {
            case .all: return true
            case .notFinished: return row.processingState == .processing || row.processingState == .needsAttention
            case .live: return row.processingState == .live
            case .processing: return row.processingState == .processing
            case .needsAttention: return row.processingState == .needsAttention
            case .ready: return row.processingState == .ready
            case .unavailable: return row.processingState == .unavailable
            }
        }
    }

    private func matchingMeetingPaths(for query: String, rows: [MeetingBrowserRow]) throws -> Set<String>? {
        guard !query.isEmpty else { return nil }
        guard let index else {
            return try Set(rows.compactMap { row in
                let content = try vault.readMarkdown(relativePath: row.meetingRelativePath).data
                let text = String(data: content, encoding: .utf8) ?? ""
                return row.title.localizedCaseInsensitiveContains(query) || text.localizedCaseInsensitiveContains(query)
                    ? row.meetingRelativePath : nil
            })
        }
        let results = try index.search(
            query,
            filter: SearchFilter(kinds: [.meeting, .summary, .transcript], pathPrefix: "Meetings/")
        )
        return Set(results.compactMap { result in
            let path = result.sourcePath
            guard path.lowercased().hasPrefix("meetings/") else { return nil }
            return (path as NSString).deletingLastPathComponent + "/meeting.md"
        })
    }
    public func read(filters: MeetingBrowserFilters = MeetingBrowserFilters()) throws -> [MeetingBrowserRow] { try list(filters: filters) }
    public func refresh() throws -> [MeetingBrowserRow] { try list() }
    public func detail(for id: String) throws -> MeetingBrowserDetail {
        guard let row = try allRows().first(where: {$0.id == id || $0.meetingRelativePath == id}) else { throw MeetingManagementError.notFound(id) }
        return try detail(for: row)
    }
    /// Reuses a row from the current browser scan rather than enumerating every Meeting again.
    public func detail(for row: MeetingBrowserRow) throws -> MeetingBrowserDetail {
        do { let source=try vault.readMarkdown(relativePath: row.meetingRelativePath); return makeDetail(row: row, source: source) } catch let e as MeetingManagementError { throw e } catch { throw MeetingManagementError.unavailable }
    }
    public func saveHumanNotes(_ notes: String, for id: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail { let d=try detail(for:id); let text=Self.replaceNotes(in:d.doorwayText, notes:notes); _=try vault.writeMarkdown(Data(text.utf8), relativePath:d.row.meetingRelativePath, expectedVersion:expectedVersion); try? index?.update(relativePath:d.row.meetingRelativePath); return try detail(for:id) }
    public func saveNotes(_ notes: String, for id: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail { try saveHumanNotes(notes, for:id, expectedVersion:expectedVersion) }
    public func saveSummary(_ sections: MeetingSummarySections, for id: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail { let d=try detail(for:id); let path=Self.sibling(d.row.meetingRelativePath, "summary.md"); let old=try vault.readMarkdown(relativePath:path); guard old.version == expectedVersion else { throw WorkspaceVaultError.conflict(relativePath:path, expected:expectedVersion, actual:old.version) }; let front=Self.frontmatter(String(data:old.data,encoding:.utf8) ?? ""); let body=Self.renderSummary(sections); _=try vault.writeMarkdown(Data((front+body).utf8), relativePath:path, expectedVersion:expectedVersion); try? index?.update(relativePath:path); return try detail(for:id) }
    public func sourceArtifacts(for id: String) throws -> [MeetingArtifact] { try detail(for:id).artifacts }

    private struct ArchiveMarker: Codable { let archived: Bool }
    private static func archivePath(for path: String) -> String { sibling(path, "archive.json") }

    private func archived(at path: String) throws -> Bool {
        let marker = Self.archivePath(for: path)
        guard let version = try vault.versionOfMarkdown(relativePath: marker) else { return false }
        let data = try vault.readMarkdown(relativePath: marker)
        guard data.version == version, let state = try? JSONDecoder().decode(ArchiveMarker.self, from: data.data) else {
            throw MeetingManagementError.malformed("Invalid archive marker at \(marker)")
        }
        return state.archived
    }

    public func archive(meetingID: String) throws { try setArchived(true, meetingID: meetingID) }
    public func restore(meetingID: String) throws { try setArchived(false, meetingID: meetingID) }

    private func setArchived(_ archived: Bool, meetingID: String) throws {
        let selected = try detail(for: meetingID)
        guard selected.row.captureState != .live else {
            throw MeetingManagementError.retryRejected("Stop recording before archiving this Meeting.")
        }
        let path = Self.archivePath(for: selected.row.meetingRelativePath)
        let existing = try vault.versionOfMarkdown(relativePath: path)
        guard selected.row.isArchived != archived else { return }
        let data = try JSONEncoder().encode(ArchiveMarker(archived: archived))
        _ = try vault.writeMarkdown(data, relativePath: path, expectedVersion: existing)
    }

    /// Title and canonical folder change together. The expected doorway version protects
    /// manual edits made while the rename warning was open.
    @discardableResult
    public func rename(meetingID: String, title: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("/"), !cleaned.contains("\\"),
              !cleaned.contains("\n"), !cleaned.contains("\r") else {
            throw MeetingManagementError.retryRejected("Enter a title without path separators or line breaks.")
        }
        let selected = try detail(for: meetingID)
        let old = selected.row.meetingRelativePath
        guard selected.doorwayVersion == expectedVersion else {
            throw WorkspaceVaultError.conflict(relativePath: old, expected: expectedVersion, actual: selected.doorwayVersion)
        }
        guard selected.row.captureState == .stopped else { throw MeetingManagementError.retryRejected("Stop recording before renaming.") }
        let session = Self.fields(selected.doorwayText).sessionID
        let owned = try jobs?.jobs().filter { Self.owns($0, session: session, path: old) } ?? []
        guard !owned.contains(where: { $0.status == .queued || $0.status == .running }) else {
            throw MeetingManagementError.retryRejected("This Meeting has processing work in progress.")
        }
        let slug = cleaned.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(8).joined(separator: "-")
        guard !slug.isEmpty else { throw MeetingManagementError.retryRejected("Enter a title with letters or numbers.") }
        let directory = (old as NSString).deletingLastPathComponent
        let parent = (directory as NSString).deletingLastPathComponent
        let name = (directory as NSString).lastPathComponent
        let prefix = name.range(of: #"^\d{2}-\d{2}-"#, options: .regularExpression).map { String(name[$0]) } ?? ""
        let target = "\(parent)/\(prefix)\(slug)/meeting.md"
        let newDirectory = (target as NSString).deletingLastPathComponent
        guard let titleLine = selected.doorwayText.range(of: #"(?m)^title:.*$"#, options: .regularExpression) else {
            throw MeetingManagementError.malformed("Meeting title metadata missing")
        }
        var doorway = selected.doorwayText.replacingCharacters(in: titleLine, with: "title: \(cleaned)")
        if let heading = doorway.range(of: #"(?m)^# .*$"#, options: .regularExpression) {
            doorway.replaceSubrange(heading, with: "# \(cleaned)")
        }
        guard target != old else {
            try vault.replaceMarkdownTransaction([
                WorkspaceMarkdownReplacement(relativePath: old, data: Data(doorway.utf8), expectedVersion: expectedVersion)
            ]) {
                try self.index?.update(relativePath: old)
            }
            return try detail(for: selected.row.id)
        }
        let rewrite: (String) -> String = {
            $0.replacingOccurrences(of: directory + "/", with: newDirectory + "/")
                .replacingOccurrences(of: directory + "|", with: newDirectory + "|")
                .replacingOccurrences(of: directory + "]]", with: newDirectory + "]]" )
                .replacingOccurrences(of: "[[" + name + "/", with: "[[" + (newDirectory as NSString).lastPathComponent + "/")
        }
        doorway = rewrite(doorway)
        var changes: [WorkspaceMarkdownReplacement] = []
        for path in try vault.textPaths() where path != old {
            let current = try vault.readMarkdown(relativePath: path)
            guard let text = String(data: current.data, encoding: .utf8) else { continue }
            var updated = Data(rewrite(text).utf8)
            if path.hasSuffix(".json"), let object = try? JSONSerialization.jsonObject(with: current.data) {
                func rewriteJSON(_ value: Any) -> Any {
                    if let string = value as? String { return rewrite(string) }
                    if let entries = value as? [String: Any] { return entries.mapValues(rewriteJSON) }
                    if let entries = value as? [Any] { return entries.map(rewriteJSON) }
                    return value
                }
                updated = try JSONSerialization.data(withJSONObject: rewriteJSON(object))
                if let originalJSON = try? JSONSerialization.jsonObject(with: current.data) as? NSDictionary,
                   let newJSON = try? JSONSerialization.jsonObject(with: updated) as? NSDictionary,
                   originalJSON == newJSON { continue }
            }
            if updated != current.data {
                changes.append(WorkspaceMarkdownReplacement(relativePath: path, data: updated, expectedVersion: current.version))
            }
        }
        let bundlePath = Self.fields(selected.doorwayText).bundlePath
        var mediaDocuments: [(url: URL, original: Data, updated: Data)] = []
        if let bundlePath {
            let url = URL(fileURLWithPath: bundlePath)
            let original = try Data(contentsOf: url)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let bundle = try decoder.decode(RecordingBundle.self, from: original)
            guard bundle.bundleFilePath == bundlePath, bundle.meetingRelativePath == old,
                  session == nil || bundle.captureSessionID == session else {
                throw MeetingManagementError.retryRejected("Recording Bundle does not match this Meeting.")
            }
            for path in [bundlePath, bundle.mic.metadataFilePath, bundle.system?.metadataFilePath].compactMap({ $0 }) {
                let file = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                let original = try Data(contentsOf: file)
                guard var json = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                    throw MeetingManagementError.retryRejected("Recording metadata is invalid.")
                }
                if let referenced = json["meetingRelativePath"] as? String, referenced != old {
                    throw MeetingManagementError.retryRejected("Recording metadata does not match this Meeting.")
                }
                guard json["meetingRelativePath"] != nil else { continue }
                json["meetingRelativePath"] = target
                mediaDocuments.append((file, original, try JSONSerialization.data(withJSONObject: json)))
            }
        }
        let applyRename = {
            try self.vault.renameMeetingDirectory(from: old, to: target, updatedDoorway: Data(doorway.utf8),
                expectedVersion: expectedVersion, referenceReplacements: changes) {
                var inboxRewritten = false
                var writtenMedia: [(url: URL, original: Data)] = []
                do {
                    try self.jobs?.rewriteMeetingReferences(from: directory, to: newDirectory)
                    try self.inbox?.rewriteMeetingReferences(from: directory, to: newDirectory)
                    inboxRewritten = self.inbox != nil
                    for document in mediaDocuments {
                        // Include a failing write in rollback: an I/O error can occur after
                        // the destination was replaced.
                        writtenMedia.append((document.url, document.original))
                        try document.updated.write(to: document.url, options: .atomic)
                    }
                    // A failed rebuild leaves its SQLite transaction unchanged. The vault and
                    // operational references are restored before the rename can report success.
                    try self.index?.rebuild()
                } catch {
                    var rollbackFailures: [String] = []
                    for document in writtenMedia.reversed() {
                        do { try document.original.write(to: document.url, options: .atomic) }
                        catch { rollbackFailures.append("Media \(document.url.path): \(error)") }
                    }
                    if inboxRewritten {
                        do { try self.inbox?.rewriteMeetingReferences(from: newDirectory, to: directory) }
                        catch { rollbackFailures.append("Inbox: \(error)") }
                    }
                    // Job references are in performRenameUnlessActive's enclosing transaction;
                    // throwing rolls them back, including on another JobStore connection.
                    if !rollbackFailures.isEmpty {
                        throw WorkspaceVaultError.transactionRollbackFailed(
                            "Rename failed with \(error); operational rollback failed: \(rollbackFailures.joined(separator: "; "))"
                        )
                    }
                    throw error
                }
            }
        }
        if let jobs {
            try jobs.performRenameUnlessActive(belongsToMeeting: { Self.owns($0, session: session, path: old) }, applyRename)
        } else {
            try applyRename()
        }
        return try detail(for: session ?? target)
    }
    public func retryFailedJob(meetingID: String, jobID: String) throws {
        guard let store = jobs else { throw MeetingManagementError.retryRejected("Job store is unavailable.") }
        let detail = try detail(for: meetingID)
        let session = Self.fields(detail.doorwayText).sessionID
        let records = try store.jobs().filter { Self.owns($0, session: session, path: detail.row.meetingRelativePath) }
        guard records.contains(where: { $0.id == jobID }) else { throw MeetingManagementError.retryRejected("This Job does not belong to the selected Meeting.") }
        guard Self.currentJobs(records).contains(where: { $0.id == jobID }) else { throw MeetingManagementError.retryRejected("This Job was superseded by a newer run.") }
        guard let job = records.first(where: { $0.id == jobID }), job.status == .failed else { throw MeetingManagementError.retryRejected("Only a failed Job can be retried.") }
        guard job.manifest.type == TranscriptionJob.type || job.manifest.type == MeetingSummaryJob.type else { throw MeetingManagementError.retryRejected("This Job type cannot be retried here.") }
        guard !records.contains(where: { $0.id != jobID && ($0.status == .queued || $0.status == .running) }) else { throw MeetingManagementError.retryRejected("This Meeting already has processing work in progress.") }
        if let reason = retryUnavailableReason(job.manifest.type) { throw MeetingManagementError.retryRejected(reason) }
        try retryDispatcher(job.manifest.type, jobID, detail.row.meetingRelativePath, session)
    }

    /// Only call after the user confirms replacement. Generated files are left intact until each
    /// executor validates its new output; the transcription completion queues the summary job.
    @discardableResult
    public func reprocess(meetingID: String, language: TranscriptLanguage) throws -> JobRecord {
        guard let store = jobs else { throw MeetingManagementError.retryRejected("Job store is unavailable.") }
        let selected = try detail(for: meetingID)
        guard selected.row.captureState == .stopped else { throw MeetingManagementError.retryRejected("Recording has not stopped.") }
        let path = selected.row.meetingRelativePath
        let session = Self.fields(selected.doorwayText).sessionID
        if let reason = retryUnavailableReason(TranscriptionJob.type) { throw MeetingManagementError.retryRejected(reason) }
        if let reason = retryUnavailableReason(MeetingSummaryJob.type) { throw MeetingManagementError.retryRejected(reason) }
        guard let bundlePath = Self.fields(selected.doorwayText).bundlePath, !bundlePath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)) else {
            throw MeetingManagementError.retryRejected("Recording Bundle unavailable.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(RecordingBundle.self, from: data),
              bundle.bundleFilePath == bundlePath, bundle.meetingRelativePath == path,
              session == nil || bundle.captureSessionID == session else {
            throw MeetingManagementError.retryRejected("Recording Bundle does not match this Meeting.")
        }
        try RecordingBundleFinalizer().validate(bundle)
        let job = try store.enqueueUnlessActive(manifest: TranscriptionJob.manifest(title: selected.row.title, bundle: bundle, selection: nil, language: language)) {
            Self.owns($0, session: session, path: path)
        }
        onReprocessQueued()
        return job
    }

    private func allRows() throws -> [MeetingBrowserRow] {
        let paths=try vault.markdownPaths(relativeTo:"Meetings").filter { ($0 as NSString).lastPathComponent == "meeting.md" }; var rows:[MeetingBrowserRow]=[]
        let allJobs = (try? jobs?.jobs()) ?? []
        for path in paths { let source=try? vault.readMarkdown(relativePath:path); let text=source.flatMap { String(data:$0.data,encoding:.utf8) }; let f=Self.fields(text); let live=captureSnapshot().flatMap{$0.meetingRelativePath == path && $0.state != .idle && $0.state != .failed} == true; let session=f.sessionID; let owned=Self.currentJobs(allJobs.filter { job in Self.owns(job, session:session, path:path) }); let state=Self.processing(live:live, path:path, jobs:owned, vault:vault)
            let dir=(path as NSString).deletingLastPathComponent
            let extraction = (try? vault.readMarkdown(relativePath:dir+"/summary-extraction.json")).flatMap { try? JSONDecoder().decode(MeetingSummaryExtraction.self, from:$0.data) }.flatMap { $0.meeting == path && $0.schemaVersion == MeetingSummaryExtraction.currentSchemaVersion ? $0 : nil }
            let bundle = f.bundlePath.flatMap { try? Data(contentsOf: URL(fileURLWithPath:$0)) }.flatMap { try? JSONDecoder().decode(RecordingBundle.self, from:$0) }.flatMap { $0.meetingRelativePath == path && $0.schemaVersion == RecordingBundle.currentSchemaVersion ? $0 : nil }
            let duration = bundle.map { max($0.mic.durationSeconds, $0.system?.durationSeconds ?? 0) }
            let actionIDs = extraction?.myActionItems.map { "meeting-action:\(session ?? path):\($0.id)" } ?? []
            let needsReview = actionIDs.contains { (try? inbox?.proposalReviewState(id:$0)) == .pending }
            rows.append(MeetingBrowserRow(id:session ?? path,title:f.title ?? Self.fallbackTitle(path),startedAt:f.startedAt ?? source?.version.modificationDate,meetingRelativePath:path,captureState:live ? .live : (text == nil ? .unavailable : .stopped),processingState:state,project:f.project,job:Self.presentation(for: owned.first),isArchived:try archived(at:path),durationSeconds:duration,hasRecording:f.bundlePath != nil,hasMyActions:!actionIDs.isEmpty,hasOthersActions:extraction?.otherActionItems.isEmpty == false,needsActionReview:needsReview)) }
        if let s=captureSnapshot(), let p=s.meetingRelativePath, s.state != .idle && s.state != .failed, !rows.contains(where:{$0.meetingRelativePath==p}) { rows.append(MeetingBrowserRow(id:p,title:s.meetingTitle ?? Self.fallbackTitle(p),startedAt:nil,meetingRelativePath:p,captureState:.live,processingState:.live)) }
        return rows.sorted { if let a=$0.startedAt, let b=$1.startedAt, a != b { return a>b }; if $0.startedAt != nil { return true }; if $1.startedAt != nil { return false }; return $0.meetingRelativePath < $1.meetingRelativePath }
    }
    private func makeDetail(row: MeetingBrowserRow, source: (data: Data, version: WorkspaceFileVersion)) -> MeetingBrowserDetail {
        let text = String(data: source.data, encoding: .utf8) ?? ""
        let path = row.meetingRelativePath
        let dir = (path as NSString).deletingLastPathComponent
        let session = Self.fields(text).sessionID
        let allOwned = (try? jobs?.jobs().filter { Self.owns($0, session: session, path: path) }) ?? []
        let owned = Self.currentJobs(allOwned)
        let sum = try? vault.readMarkdown(relativePath: dir + "/summary.md")
        let ext = try? vault.readMarkdown(relativePath: dir + "/summary-extraction.json")
        let extraction = ext.flatMap { try? JSONDecoder().decode(MeetingSummaryExtraction.self, from: $0.data) }
        let playback = resolvePlayback(text: text, path: path, session: session)
        let transcript = makeTranscriptSegments(readTranscript(path: dir + "/transcript.json", meetingPath: path, session: session), playback: playback)
        let validExtraction = extraction.flatMap { value in
            value.schemaVersion == MeetingSummaryExtraction.currentSchemaVersion && value.meeting == path && value.transcript == dir + "/transcript.json" ? value : nil
        }
        func citations(_ source: [MeetingOutcomeCitation]) -> [MeetingCitation] {
            source.map { citation in
                let matching = transcript.filter {
                    $0.id == citation.segmentID && $0.seekSeconds != nil && citation.startSeconds.isFinite && citation.endSeconds.isFinite &&
                    abs($0.startSeconds - citation.startSeconds) < 0.001 && abs($0.endSeconds - citation.endSeconds) < 0.001
                }
                return MeetingCitation(segmentID: citation.segmentID, startSeconds: citation.startSeconds,
                                       endSeconds: citation.endSeconds, seekSeconds: matching.count == 1 ? matching[0].seekSeconds : nil)
            }
        }
        let mine = (validExtraction?.myActionItems ?? []).map { item in
            MeetingActionItem(id: item.id, text: item.text, citations: citations(item.citations),
                              reviewState: (try? inbox?.proposalReviewState(id: "meeting-action:\(row.id):\(item.id)")) ?? nil ?? .referenceOnly)
        }
        let other = (validExtraction?.otherActionItems ?? []).map {
            MeetingActionItem(id: $0.id, text: $0.text, citations: citations($0.citations), referenceOnly: true)
        }
        let currentIDs = Set((validExtraction?.myActionItems ?? []).map { "meeting-action:\(row.id):\($0.id)" })
        let summaryRef = "[[\(dir)/summary#My action items|ref]]"
        let stale = (validExtraction == nil ? [] : ((try? inbox?.items(category: .review)) ?? [])).filter {
            $0.kind == .proposal && $0.sourceRef == summaryRef && $0.id.hasPrefix("meeting-action:\(row.id):") && !currentIDs.contains($0.id)
        }.map { ActionItemProposal(id: $0.id, title: $0.title, sourceRef: summaryRef) }
        return MeetingBrowserDetail(row: row, doorwayText: text, doorwayVersion: source.version, humanNotes: Self.notes(from: text),
            artifacts: resolvedArtifacts(for: text, path: path), job: Self.presentation(for: owned.first) ?? row.job,
            jobs: (owned + allOwned.filter { job in
                (job.status == .queued || job.status == .running) && !owned.contains(where: { $0.id == job.id })
            }).map { candidate in
                let reason: String? = candidate.status != .failed ? nil :
                    (candidate.manifest.type == TranscriptionJob.type || candidate.manifest.type == MeetingSummaryJob.type
                     ? retryUnavailableReason(candidate.manifest.type) : "This Job type cannot be retried here.")
                return Self.presentation(for: candidate, retryReason: reason)!
            },
            summaryVersion: sum?.version, summary: sum.flatMap { Self.parseSummary(String(data: $0.data, encoding: .utf8) ?? "") },
            extraction: validExtraction, myActionItems: mine, otherActionItems: other, staleProposals: stale, transcript: transcript,
            decisions: (validExtraction?.decisions ?? []).map { MeetingCitedOutcome(text: $0.text, citations: citations($0.citations)) },
            openQuestions: (validExtraction?.openQuestions ?? []).map { MeetingCitedOutcome(text: $0.text, citations: citations($0.citations)) }, playback: playback)
    }
    private func makeTranscriptSegments(_ document: TranscriptDocument?, playback: MeetingPlayback) -> [MeetingTranscriptSegment] {
        guard let document else { return [] }
        let ordered: [TranscriptSegment] = document.segments.sorted(by: { $0.startSeconds < $1.startSeconds })
        var result: [MeetingTranscriptSegment] = []
        for segment in ordered {
            let valid = segment.startSeconds.isFinite && segment.endSeconds.isFinite && segment.startSeconds >= 0 && segment.endSeconds >= segment.startSeconds && segment.endSeconds <= playback.durationSeconds
            let target: Double? = playback.capability != .unavailable && valid ? segment.startSeconds : nil
            result.append(MeetingTranscriptSegment(id: segment.id, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds, track: segment.track.speakerLabel, speaker: segment.speaker, text: segment.text, seekSeconds: target))
        }
        return result
    }
    private func readTranscript(path: String, meetingPath: String, session: String?) -> TranscriptDocument? { guard let data = try? vault.readMarkdown(relativePath: path).data else { return nil }; let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; guard let document=try? decoder.decode(TranscriptDocument.self, from:data), document.schemaVersion == TranscriptDocument.currentSchemaVersion, document.meetingRelativePath == meetingPath, session == nil || document.captureSessionID == session else { return nil }; return document }
    private func resolvePlayback(text: String, path: String, session: String?) -> MeetingPlayback {
        func unavailable(_ reason: String) -> MeetingPlayback { MeetingPlayback(capability: .unavailable, message: reason) }
        guard let bundlePath = Self.fields(text).bundlePath, !bundlePath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: bundlePath)) else {
            return unavailable("Recording Bundle unavailable. Check the recording media location.")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let bundle = try? decoder.decode(RecordingBundle.self, from: data) else {
            return unavailable("Recording Bundle invalid. Inspect the source file.")
        }
        guard bundle.bundleFilePath == bundlePath,
              bundle.meetingRelativePath == path,
              session == nil || bundle.captureSessionID == session,
              bundle.schemaVersion == RecordingBundle.currentSchemaVersion else {
            return unavailable("Recording Bundle does not match this Meeting or its supported version.")
        }
        // The optional System Audio Track must not make sound microphone evidence unusable.
        // Check the required evidence independently before attempting full bundle validation.
        let mic = bundle.mic
        guard mic.role == "microphone", Self.hasIntactEvidence(mic),
              let micDuration = Self.audioDuration(mic.preferredAudioFilePath) else {
            return unavailable("Microphone audio missing, changed, or cannot be decoded. Inspect the Recording Bundle.")
        }
        let system = bundle.system
        let systemDuration = system.flatMap { $0.role == "system-audio" && Self.hasIntactEvidence($0) ? Self.audioDuration($0.preferredAudioFilePath) : nil }
        let mixed = systemDuration != nil
        // Validate the entire bundle when all tracks appear usable; a failure must not advertise mixing.
        if mixed && (try? RecordingBundleFinalizer().validate(bundle)) == nil {
            return unavailable("Recording Bundle validation failed. Inspect the source recordings.")
        }
        let partial = bundle.state == .partial
        let offsets: (mic: Double, system: Double)
        if mixed, let system { offsets = Self.playbackOffsets(mic: mic, system: system) }
        else { offsets = (0, 0) }
        return MeetingPlayback(capability: mixed ? .mixed : .microphoneOnly,
            microphonePath: mic.preferredAudioFilePath,
            systemPath: mixed ? system?.preferredAudioFilePath : nil,
            durationSeconds: max(offsets.mic + micDuration, offsets.system + (systemDuration ?? 0)),
            microphoneOffsetSeconds: offsets.mic, systemOffsetSeconds: offsets.system,
            message: mixed ? (partial ? "Microphone and system audio (partial recording)" : "Microphone and system audio")
                : (partial ? "Partial recording: microphone-only audio; system audio unavailable." : "Microphone-only audio; system audio unavailable."))
    }

    private static func playbackOffsets(mic: RecordingBundleTrack, system: RecordingBundleTrack) -> (mic: Double, system: Double) {
        struct Timing: Decodable { let audioClockSpans: [AudioClockSpan]? }
        func fileZero(_ track: RecordingBundleTrack) -> Double? {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: track.metadataFilePath)),
                  let spans = try? decoder.decode(Timing.self, from: data).audioClockSpans,
                  let first = spans.first, first.hostStart.isFinite,
                  first.sampleRate.isFinite, first.sampleRate > 0 else { return nil }
            return first.hostStart - Double(first.startFrame) / first.sampleRate
        }
        guard let micZero = fileZero(mic), let systemZero = fileZero(system),
              micZero.isFinite, systemZero.isFinite else { return (0, 0) }
        let start = min(micZero, systemZero)
        return (max(0, micZero - start), max(0, systemZero - start))
    }

    private static func hasIntactEvidence(_ track: RecordingBundleTrack) -> Bool {
        (try? RecordingBundleFinalizer().validate(track: track)) != nil
    }

    private static func audioDuration(_ path: String) -> Double? {
        guard FileManager.default.isReadableFile(atPath: path),
              let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: path)), audio.length > 0,
              audio.processingFormat.sampleRate > 0 else { return nil }
        return Double(audio.length) / audio.processingFormat.sampleRate
    }

    private func resolvedArtifacts(for text: String, path: String) -> [MeetingArtifact] {
        let directory = (path as NSString).deletingLastPathComponent
        let bundlePath = Self.fields(text).bundlePath
        let bundleAvailable = bundlePath.map { FileManager.default.isReadableFile(atPath: $0) } ?? false
        var artifacts = [MeetingArtifact(role: .doorway, relativePath: path, available: true)]
        artifacts.append(MeetingArtifact(role: .recordingBundle, relativePath: bundlePath ?? "", available: bundleAvailable, message: bundleAvailable ? nil : "Recording Bundle unavailable"))
        for (role, name, label) in [(MeetingArtifactRole.transcript, "transcript.md", "Transcript"), (.summary, "summary.md", "Summary"), (.extraction, "summary-extraction.json", "Summary extraction")] {
            let relativePath = directory + "/" + name
            let available = (try? vault.readMarkdown(relativePath: relativePath)) != nil
            artifacts.append(MeetingArtifact(role: role, relativePath: relativePath, available: available, message: available ? nil : "\(label) unavailable"))
        }
        // Recording Bundle paths are absolute media paths, not fabricated workspace-relative paths.
        let bundle: RecordingBundle? = bundleAvailable ? bundlePath.flatMap { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try? decoder.decode(RecordingBundle.self, from: data)
        } : nil
        for track in [bundle?.mic, bundle?.system].compactMap({ $0 }) {
            let mediaPath = track.preferredAudioFilePath
            let available = FileManager.default.isReadableFile(atPath: mediaPath)
            artifacts.append(MeetingArtifact(role: .source, relativePath: mediaPath, available: available,
                                             message: available ? nil : "\(track.role) audio unavailable"))
        }
        if bundle == nil {
            artifacts.append(MeetingArtifact(role: .source, relativePath: "", available: false, message: "Recording media unavailable"))
        }
        return artifacts
    }
    private static func presentation(for job: JobRecord?, retryReason: String? = nil) -> MeetingJobPresentation? {
        guard let job else { return nil }
        let stage = job.stages.first { $0.status == .running || $0.status == .failed || $0.status == .pending }
        return MeetingJobPresentation(
            jobID: job.id, title: job.manifest.title, status: job.status,
            stage: stage?.definition.title, error: stage?.lastError ?? job.failureDetails,
            attemptCount: stage?.attemptCount ?? 0, retryReason: retryReason
        )
    }
    private static func currentJobs(_ records: [JobRecord]) -> [JobRecord] {
        // The store yields creation order. A later run supersedes an earlier run,
        // even when an older Job's status is updated later.
        var latest: [String: (index: Int, job: JobRecord)] = [:]
        for (index, job) in records.enumerated() {
            // Preserve the latest persisted run of each type, not the most recently touched run.
            latest[job.manifest.type] = (index, job)
        }
        return latest.values.map(\.job).sorted { left, right in
            let priority: (JobRecord) -> Int = { job in
                switch job.status {
                case .running, .queued: return 0
                case .failed: return 1
                default: return 2
                }
            }
            if priority(left) != priority(right) { return priority(left) < priority(right) }
            return left.updatedAt > right.updatedAt
        }
    }
    private static func owns(_ job:JobRecord, session:String?, path:String)->Bool { if let s=session, job.manifest.metadata["capture_session_id"] == s { return true }; return job.manifest.sourceArtifacts.contains { $0.relativePath == path || $0.relativePath.hasPrefix((path as NSString).deletingLastPathComponent + "/") } || job.manifest.expectedOutputs.contains { $0.relativePath.hasPrefix((path as NSString).deletingLastPathComponent + "/") } }
    private static func processing(live:Bool,path:String,jobs:[JobRecord],vault:WorkspaceVault)->MeetingProcessingState { if live{return .live}; if jobs.contains(where:{$0.status == .queued || $0.status == .running}) {return .processing}; if jobs.contains(where:{$0.status == .failed}) {return .needsAttention}; let dir=(path as NSString).deletingLastPathComponent; let t=Self.validTranscript(path: dir+"/transcript.json", vault: vault) && (try? vault.readMarkdown(relativePath: dir+"/transcript.md")) != nil, s=(try? vault.readMarkdown(relativePath:dir+"/summary.md")) != nil && (try? vault.readMarkdown(relativePath:dir+"/summary-extraction.json")).flatMap { try? JSONDecoder().decode(MeetingSummaryExtraction.self, from: $0.data) } != nil; return t && s ? .ready : .needsAttention }
    private struct Fields { var title:String?;var startedAt:Date?;var sessionID:String?;var project:String?;var bundlePath:String? }
    private static func validTranscript(path: String, vault: WorkspaceVault) -> Bool { guard let data = try? vault.readMarkdown(relativePath: path).data else { return false }; let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return (try? decoder.decode(TranscriptDocument.self, from: data)) != nil }
    private static func fields(_ text: String?) -> Fields {
        var fields = Fields()
        guard let text else { return fields }
        let lines = text.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                switch key {
                case "title": fields.title = value
                case "project": fields.project = value
                case "capture_session_id", "session_id": fields.sessionID = value
                case "started_at": fields.startedAt = ISO8601DateFormatter().date(from: value)
                case "recording_bundle": fields.bundlePath = value
                default: break
                }
            }
        }
        if fields.title == nil {
            fields.title = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        }
        return fields
    }
    private static func notesRange(in text: String) -> Range<String.Index>? {
        // Captured Meetings use Live notes; older manually written Meetings may use Notes.
        guard let heading = text.range(of: #"(?m)^## (?:Live notes|Notes)[ \t]*$"#, options: .regularExpression) else { return nil }
        let end = text.range(of: #"(?m)^## [^\n]+$"#, options: .regularExpression, range: heading.upperBound..<text.endIndex)?.lowerBound ?? text.endIndex
        return heading.upperBound..<end
    }
    private static func notes(from text: String) -> String {
        guard let range = notesRange(in: text) else { return "" }
        return text[range].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func replaceNotes(in text: String, notes: String) -> String {
        let clean = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = notesRange(in: text) else {
            return text.trimmingCharacters(in: .newlines) + "\n\n## Notes\n\n" + clean + "\n"
        }
        return text.replacingCharacters(in: range, with: "\n\n" + clean + "\n\n")
    }
    private static func sibling(_ path:String,_ name:String)->String {(path as NSString).deletingLastPathComponent+"/"+name}
    private static func frontmatter(_ text:String)->String { guard text.hasPrefix("---") else{return "---\n---\n"}; guard let r=text.range(of:"---",range:text.index(text.startIndex,offsetBy:3)..<text.endIndex) else{return "---\n---\n"}; return String(text[..<text.index(after:r.upperBound)])+"\n" }
    private static func renderSummary(_ s:MeetingSummarySections)->String { ["## Summary",s.summary,"## Decisions",s.decisions,"## My action items",s.myActionItems,"## Other action items",s.otherActionItems,"## Open questions",s.openQuestions].joined(separator:"\n\n")+"\n" }
    private static func parseSummary(_ text:String)->MeetingSummarySections { var values=MeetingSummarySections(); var key=""; for line in text.components(separatedBy:.newlines) { if line.hasPrefix("## "){key=String(line.dropFirst(3)).lowercased();continue}; switch key {case "summary":values.summary += (values.summary.isEmpty ? "":"\n")+line;case "decisions":values.decisions += (values.decisions.isEmpty ? "":"\n")+line;case "my action items":values.myActionItems += (values.myActionItems.isEmpty ? "":"\n")+line;case "other action items":values.otherActionItems += (values.otherActionItems.isEmpty ? "":"\n")+line;case "open questions":values.openQuestions += (values.openQuestions.isEmpty ? "":"\n")+line;default:break} }; return values }
    private static func fallbackTitle(_ path:String)->String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent.replacingOccurrences(of:"-",with:" ").capitalized }
}
