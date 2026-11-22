import Foundation

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
    public let stageID: String?
    /// Measured progress within the current stage, when supplied by the producer.
    public let progressFraction: Double?
    public var id: String { jobID }
    public init(jobID: String, title: String, status: JobStatus, stage: String?, error: String?, attemptCount: Int = 0, retryReason: String? = nil, stageID: String? = nil, progressFraction: Double? = nil) { self.jobID=jobID; self.title=title; self.status=status; self.stage=stage; self.error=error; self.attemptCount=attemptCount; self.retryReason=retryReason; self.stageID=stageID; self.progressFraction=progressFraction }
}
public struct MeetingCitation: Equatable {
    public let segmentID: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let seekSeconds: Double?

    public init(segmentID: String, startSeconds: Double, endSeconds: Double, seekSeconds: Double? = nil) {
        self.segmentID = segmentID
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.seekSeconds = seekSeconds
    }

    public func matches(_ segment: MeetingTranscriptSegment) -> Bool {
        segment.id == segmentID && startSeconds.isFinite && endSeconds.isFinite &&
            abs(segment.startSeconds - startSeconds) < 0.001 &&
            abs(segment.endSeconds - endSeconds) < 0.001
    }

    public func validatedSeekSeconds(playbackDuration: Double?) -> Double? {
        guard let seekSeconds, seekSeconds.isFinite, seekSeconds >= 0,
              let playbackDuration, playbackDuration.isFinite,
              seekSeconds <= playbackDuration else { return nil }
        return seekSeconds
    }
}
public struct MeetingCitedOutcome: Equatable { public let text: String; public let citations: [MeetingCitation]
    public init(text: String, citations: [MeetingCitation]) { self.text = text; self.citations = citations }
}
public struct MeetingActionItem: Equatable { public let id: String; public let text: String; public let citations: [MeetingCitation]; public let reviewState: ProposalReviewState; public let referenceOnly: Bool; public let completionStatus: TodoStatus?
    public init(id: String, text: String, citations: [MeetingCitation], reviewState: ProposalReviewState = .referenceOnly, referenceOnly: Bool = false, completionStatus: TodoStatus? = nil) { self.completionStatus=completionStatus; self.id=id; self.text=text; self.citations=citations; self.reviewState=reviewState; self.referenceOnly=referenceOnly }
}
public struct MeetingSummarySections: Equatable { public var summary: String; public var decisions: String; public var myActionItems: String; public var otherActionItems: String; public var openQuestions: String
    public init(summary: String = "", decisions: String = "", myActionItems: String = "", otherActionItems: String = "", openQuestions: String = "") { self.summary=MeetingSummaryEvidence.readableText(summary); self.decisions=decisions; self.myActionItems=myActionItems; self.otherActionItems=otherActionItems; self.openQuestions=openQuestions }
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
    /// Empty arrays on both tracks select legacy offset playback. Otherwise every
    /// retained track requires ordered ranges covering its complete decoded file.
    /// Timeline positions are seconds from the shared Meeting origin.
    public let microphoneRanges: [MeetingPlaybackRange]
    public let systemRanges: [MeetingPlaybackRange]
    public let message: String
    public init(capability: Capability, microphonePath: String? = nil, systemPath: String? = nil, durationSeconds: Double = 0,
                microphoneOffsetSeconds: Double = 0, systemOffsetSeconds: Double = 0, microphoneRanges: [MeetingPlaybackRange] = [],
                systemRanges: [MeetingPlaybackRange] = [], message: String) {
        self.capability = capability; self.microphonePath = microphonePath; self.systemPath = systemPath
        self.durationSeconds = durationSeconds; self.microphoneOffsetSeconds = microphoneOffsetSeconds
        self.systemOffsetSeconds = systemOffsetSeconds; self.message = message
        self.microphoneRanges = microphoneRanges; self.systemRanges = systemRanges
    }
}
public struct MeetingTranscriptSegment: Equatable, Identifiable {
    public let id: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let track: String
    public let speaker: String
    public let text: String
    public let seekSeconds: Double?
    public let playbackRanges: [Range<Double>]

    init(id: String, startSeconds: Double, endSeconds: Double, track: String, speaker: String, text: String,
         seekSeconds: Double?, playbackRanges: [Range<Double>] = []) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.track = track
        self.speaker = speaker
        self.text = text
        self.seekSeconds = seekSeconds
        self.playbackRanges = playbackRanges
    }
}
public struct MeetingActionDraft: Equatable { public let title: String; public let comment: String; public init(title: String, comment: String) { self.title = title; self.comment = comment } }
public struct MeetingBrowserDetail: Equatable { public var tagCatalog: [String] = []; public var reviewItems: [MeetingReviewItem] = []; public var speakerCorrectionReview: [MeetingSpeakerCorrectionReview] = []; public var analysisOutdated = false; public var speakerReviewRequired = false; public let actionDrafts: [String: MeetingActionDraft]; public let decisions: [MeetingCitedOutcome]; public let openQuestions: [MeetingCitedOutcome]; public let transcript: [MeetingTranscriptSegment]; public let row: MeetingBrowserRow; public let doorwayText: String; public let doorwayVersion: WorkspaceFileVersion?; public let humanNotes: String; public let notesVersion: WorkspaceFileVersion?; public let artifacts: [MeetingArtifact]; public let job: MeetingJobPresentation?; public let jobs: [MeetingJobPresentation]; public let summaryVersion: WorkspaceFileVersion?; public let summary: MeetingSummarySections?; public let extraction: MeetingSummaryExtraction?; public let myActionItems: [MeetingActionItem]; public let otherActionItems: [MeetingActionItem]; public let staleProposals: [ActionItemProposal]; public let playback: MeetingPlayback
    public init(row: MeetingBrowserRow, doorwayText: String, doorwayVersion: WorkspaceFileVersion? = nil, humanNotes: String = "", notesVersion: WorkspaceFileVersion? = nil, artifacts: [MeetingArtifact] = [], job: MeetingJobPresentation? = nil, jobs: [MeetingJobPresentation] = [], summaryVersion: WorkspaceFileVersion? = nil, summary: MeetingSummarySections? = nil, extraction: MeetingSummaryExtraction? = nil, myActionItems: [MeetingActionItem] = [], otherActionItems: [MeetingActionItem] = [], staleProposals: [ActionItemProposal] = [], transcript: [MeetingTranscriptSegment] = [], decisions: [MeetingCitedOutcome] = [], openQuestions: [MeetingCitedOutcome] = [], playback: MeetingPlayback = MeetingPlayback(capability: .unavailable, message: "Recording Bundle unavailable"), actionDrafts: [String: MeetingActionDraft] = [:]) { self.actionDrafts=actionDrafts; self.decisions=decisions; self.openQuestions=openQuestions; self.transcript=transcript; self.playback=playback; self.row=row; self.doorwayText=doorwayText; self.doorwayVersion=doorwayVersion; self.humanNotes=humanNotes; self.notesVersion=notesVersion ?? doorwayVersion; self.artifacts=artifacts; self.job=job; self.jobs=jobs; self.summaryVersion=summaryVersion; self.summary=summary; self.extraction=extraction; self.myActionItems=myActionItems; self.otherActionItems=otherActionItems; self.staleProposals=staleProposals }
}

public enum MeetingManagementError: Error, Equatable, LocalizedError { case unavailable; case malformed(String); case notFound(String); case retryRejected(String)
    public var errorDescription: String? { switch self { case let .retryRejected(reason), let .malformed(reason): return reason; case let .notFound(id): return "Meeting \(id) could not be found. Reload the Meeting list."; case .unavailable: return "Meeting processing is unavailable." } }
}

/// Shared lifecycle metadata for Meeting browsing and keyword search. Legacy markers
/// without an archive date remain readable and never acquire an invented date.
struct MeetingArchiveState: Codable {
    let archived: Bool
    var archivedAt: Date? = nil

    static func relativePath(for artifactPath: String) -> String {
        (artifactPath as NSString).deletingLastPathComponent + "/archive.json"
    }

    static func decode(_ data: Data) throws -> MeetingArchiveState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: data)
    }
}

public final class MeetingManagementService {
    private var artifactStore: MeetingArtifactStore { MeetingArtifactStore(vault: vault, inbox: inbox) }
    private var textEditing: MeetingTextEditing {
        MeetingTextEditing(vault: vault, inbox: inbox, index: index,
                           readDetail: { try self.detail(for: $0) }, onMeetingChanged: onMeetingChanged)
    }
    private let vault: WorkspaceVault; private let jobs: JobStore?; private let inbox: TasksInbox?; private let index: SearchIndex?; private let captureSnapshot: () -> CaptureSnapshot?
    private let enforceWorkspaceOwner: Bool
    private func workspaceJobs() throws -> [JobRecord] {
        let records = try jobs?.jobs() ?? []
        guard enforceWorkspaceOwner else { return records }
        let owner = vault.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        return records.filter { $0.manifest.workspaceOwner == owner }
    }
    private let recordingMediaURL: URL?
    private let retryDispatcher: (String, String, String, String?) throws -> Void
    private let retryUnavailableReason: (String) -> String?
    private let onReprocessQueued: () -> Void
    private let onMeetingChanged: ([String]) -> Void
    public init(vault: WorkspaceVault, jobStore: JobStore? = nil, inbox: TasksInbox? = nil, searchIndex: SearchIndex? = nil, recordingMediaURL: URL? = nil, captureSnapshot: @escaping () -> CaptureSnapshot? = { nil }, retryUnavailableReason: @escaping (String) -> String? = { _ in "Retry unavailable: processing is not configured." }, retryDispatcher: @escaping (String, String, String, String?) throws -> Void = { _, _, _, _ in throw MeetingManagementError.retryRejected("Retry unavailable: processing is not configured.") }, onReprocessQueued: @escaping () -> Void = {}, onMeetingChanged: @escaping ([String]) -> Void = { _ in }, enforceWorkspaceOwner: Bool = false) { self.vault=vault; self.jobs=jobStore; self.inbox=inbox; self.index=searchIndex; self.recordingMediaURL=recordingMediaURL; self.captureSnapshot=captureSnapshot; self.retryUnavailableReason=retryUnavailableReason; self.retryDispatcher=retryDispatcher; self.onReprocessQueued=onReprocessQueued; self.onMeetingChanged=onMeetingChanged; self.enforceWorkspaceOwner=enforceWorkspaceOwner }
    public func actionDraft(id: String) throws -> (title: String, comment: String)? { try inbox?.proposalDraft(id: id) }

    public func saveActionDraft(id: String, title: String, comment: String) throws {
        guard let inbox else { throw MeetingManagementError.unavailable }
        let meetingPath = proposalMeetingPath(id: id)
        if let meetingPath { _ = try editableActionMeeting(meetingPath) }
        try inbox.saveProposalDraft(id: id, title: title, comment: comment)
        if let meetingPath { onMeetingChanged([meetingPath]) }
    }

    public func reviewAction(id: String, accept: Bool) throws {
        guard inbox != nil else { throw MeetingManagementError.unavailable }
        let meetingPath = proposalMeetingPath(id: id)
        guard let meetingPath else { throw MeetingManagementError.notFound(id) }
        let detail = try editableActionMeeting(meetingPath)
        try artifactStore.review(proposalID: id, accept: accept, meetingPath: meetingPath, meetingID: detail.row.id)
        onMeetingChanged([meetingPath])
    }

    public func reviewMeetingItems(meetingID: String, items: [MeetingReviewItem], accept: Bool) throws -> MeetingBrowserDetail {
        let detail = try editableActionMeeting(meetingID)
        try artifactStore.reviewItems(items, accept: accept, meetingPath: detail.row.meetingRelativePath, meetingID: detail.row.id)
        onMeetingChanged([detail.row.meetingRelativePath])
        return try self.detail(for: meetingID)
    }

    public func editMeetingItem(meetingID: String, item: MeetingReviewItem, text: String, owner: String?, dueDate: String?, status: TodoStatus) throws -> MeetingBrowserDetail {
        let detail = try editableActionMeeting(meetingID)
        try artifactStore.editReviewItem(item, text: text, owner: owner, dueDate: dueDate, status: status,
            meetingPath: detail.row.meetingRelativePath, meetingID: detail.row.id)
        onMeetingChanged([detail.row.meetingRelativePath])
        return try self.detail(for: meetingID)
    }

    public func mutateTags(meetingID: String, mutation: ItemTagMutation) throws -> MeetingBrowserDetail {
        let detail = try editableActionMeeting(meetingID)
        if case let .set(id, _, _) = mutation {
            guard detail.reviewItems.contains(where: { $0.id == id }) else { throw TodoItemMutationError.itemNotFound(id) }
        }
        try ItemTagStore(vault: vault).mutate(mutation)
        onMeetingChanged(try list().map(\.meetingRelativePath))
        return try self.detail(for: meetingID)
    }

    private func editableActionMeeting(_ id: String) throws -> MeetingBrowserDetail {
        let detail = try self.detail(for: id)
        guard !detail.row.isArchived, detail.row.captureState == .stopped,
              !detail.jobs.contains(where: { $0.status == .queued || $0.status == .running }) else {
            throw MeetingManagementError.retryRejected("Action Items can be changed after processing in an active Meeting.")
        }
        return detail
    }

    public func list() throws -> [MeetingBrowserRow] { try list(filters: MeetingBrowserFilters()) }

    /// Rebuildable Today rows; canonical files, never individual Inbox proposals, own the count.
    public func reviewReminders() throws -> [InboxItem] {
        try list().compactMap { row in
            guard row.captureState == .stopped, row.processingState != .processing else { return nil }
            let count = try artifactStore.pendingReviewCount(meetingPath: row.meetingRelativePath, meetingID: row.id)
            guard count > 0 else { return nil }
            return InboxItem(id: "meeting-review:\(row.id)", category: .review, kind: .proposal,
                title: row.title, sourceRef: row.meetingRelativePath, details: "\(count) awaiting approval",
                createdAt: "", workspaceOwner: vault.rootURL.standardizedFileURL.resolvingSymlinksInPath().path)
        }
    }
    public func list(filters: MeetingBrowserFilters) throws -> [MeetingBrowserRow] {
        try filter(allRows(), using: filters)
    }

    /// Supplies project choices and filtered rows from the same workspace scan.
    /// Captures the workspace-derived browser projection once. Callers may reuse it for
    /// multiple filter selections until a workspace or Job invalidation arrives.
    public func browserProjection() throws -> [MeetingBrowserRow] { try allRows() }

    public func browserRows(filters: MeetingBrowserFilters) throws -> (visible: [MeetingBrowserRow], available: [MeetingBrowserRow]) {
        try browserRows(filters: filters, from: browserProjection())
    }

    public func browserRows(filters: MeetingBrowserFilters,
                            from projection: [MeetingBrowserRow]) throws -> (visible: [MeetingBrowserRow], available: [MeetingBrowserRow]) {
        let available = projection.filter { $0.isArchived == filters.archived }
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
            filter: SearchFilter(kinds: [.meeting, .summary, .transcript], pathPrefix: "Meetings/", includeArchived: true)
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
        do { let source=try vault.readMarkdown(relativePath: row.meetingRelativePath); return try makeDetail(row: row, source: source) } catch let e as MeetingManagementError { throw e } catch { throw MeetingManagementError.malformed("Could not load \(row.meetingRelativePath): \(error.localizedDescription). Restore the affected file and Reload Latest.") }
    }
    public func correctSpeaker(meetingID: String, source: MeetingTranscriptSegment, name: String) throws -> MeetingBrowserDetail {
        let selected = try detail(for: meetingID)
        guard !selected.row.isArchived, selected.row.captureState == .stopped,
              !selected.jobs.contains(where: { $0.status == .queued || $0.status == .running }) else {
            throw MeetingManagementError.retryRejected("Speaker correction is available in completed, active Meetings.")
        }
        try artifactStore.correctSpeaker(source: source, name: name, meetingPath: selected.row.meetingRelativePath, meetingID: selected.row.id)
        try index?.update(relativePath: Self.sibling(selected.row.meetingRelativePath, "transcript.json"))
        onMeetingChanged([selected.row.meetingRelativePath])
        return try detail(for: meetingID)
    }

    public func saveHumanNotes(_ notes: String, for id: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        try textEditing.saveNotes(notes, for: id, expectedVersion: expectedVersion)
    }

    public func saveNotes(_ notes: String, for id: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        try textEditing.saveNotes(notes, for: id, expectedVersion: expectedVersion)
    }

    public func saveSummary(_ sections: MeetingSummarySections, for id: String, expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        try textEditing.saveSummary(sections, for: id, expectedVersion: expectedVersion)
    }
    public func saveOutcome(_ entry: MeetingOutcomeEntry, delete: Bool = false, for id: String,
                            expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        let detail = try self.detail(for: id)
        guard !detail.row.isArchived, var sections = detail.summary else { throw MeetingManagementError.unavailable }
        let isDecision = entry.kind == .decision
        let body = isDecision ? sections.decisions : sections.openQuestions
        let old = try MeetingOutcomeDocument.entries(in: body, defaultKind: isDecision ? .decision : .question).first { $0.id == entry.id }
        if let old, old.resolved && !entry.resolved { throw MeetingManagementError.retryRejected("Resolved items cannot be reopened in the app.") }
        for citation in entry.citations where old?.citations.contains(citation) != true {
            guard detail.transcript.contains(where: { $0.id == citation.segmentID && $0.startSeconds == citation.startSeconds && $0.endSeconds == citation.endSeconds }) else {
                throw MeetingManagementError.retryRejected("Select an available Transcript source.")
            }
        }
        let changed = try MeetingOutcomeDocument.replacing(entry, in: body, delete: delete)
        if isDecision { sections.decisions = changed } else { sections.openQuestions = changed }
        return try saveSummary(sections, for: id, expectedVersion: expectedVersion)
    }

    public func sourceArtifacts(for id: String) throws -> [MeetingArtifact] { try detail(for:id).artifacts }

    private func archived(at path: String) throws -> Bool {
        let marker = MeetingArchiveState.relativePath(for: path)
        guard let version = try vault.versionOfMarkdown(relativePath: marker) else { return false }
        let data = try vault.readMarkdown(relativePath: marker)
        guard data.version == version, let state = try? MeetingArchiveState.decode(data.data) else {
            throw MeetingManagementError.malformed("Invalid archive marker at \(marker)")
        }
        return state.archived
    }

    /// Removes only the workspace Meeting folder; external recordings and accepted Todos are retained.
    public func remove(meetingID: String) throws {
        let selected = try detail(for: meetingID)
        guard selected.canRemove,
              let version = selected.doorwayVersion else {
            throw MeetingManagementError.retryRejected("Stop recording and finish processing before removing this Meeting.")
        }
        let path = selected.row.meetingRelativePath
        let session = MeetingDoorwayMetadata(selected.doorwayText).sessionID
        let owner = vault.rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let removeFiles = { try self.vault.trashMeeting(relativePath: path, expectedVersion: version) }
        if let jobs {
            let removedJobIDs = try jobs.removeInactiveJobs(belongsToMeeting: {
                (!self.enforceWorkspaceOwner || $0.manifest.workspaceOwner == owner) && MeetingDoorwayMetadata.owns($0, session: session, path: path)
            }, removingFiles: removeFiles)
            for id in removedJobIDs { try inbox?.removeItem(id: "job:\(id)") }
        } else {
            try removeFiles()
        }
        let directory = (path as NSString).deletingLastPathComponent
        try inbox?.removeMeetingReferences(in: directory)
        try index?.removeDirectory(relativePath: directory)
        onMeetingChanged([selected.row.meetingRelativePath])
    }

    public func archive(meetingID: String) throws {
        let selected = try detail(for: meetingID)
        if let reason = selected.archiveUnavailableReason { throw MeetingManagementError.retryRejected(reason) }
        // Check every owned Job, including an older run hidden by the row projection.
        guard try !workspaceJobs().contains(where: { MeetingDoorwayMetadata.owns($0, session: MeetingDoorwayMetadata(selected.doorwayText).sessionID,
            path: selected.row.meetingRelativePath) && ($0.status == .queued || $0.status == .running) }) else {
            throw MeetingManagementError.retryRejected("Finish processing before archiving this Meeting.")
        }
        let path = MeetingArchiveState.relativePath(for: selected.row.meetingRelativePath)
        let existing = try vault.versionOfMarkdown(relativePath: path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(MeetingArchiveState(archived: true, archivedAt: Date()))
        _ = try vault.writeMarkdown(data, relativePath: path, expectedVersion: existing)
        onMeetingChanged([selected.row.meetingRelativePath])
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
        guard cleaned.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else {
            throw MeetingManagementError.retryRejected("Enter a title with letters or numbers.")
        }
        let selected = try detail(for: meetingID)
        var context = try MeetingCalendarContext.read(from: selected.doorwayText) ?? MeetingCalendarContext(
            event: nil, fallbackTitle: selected.row.title, appliedTitle: cleaned, manualTitle: true, status: "No linked event")
        context.manualTitle = true
        context.appliedTitle = cleaned
        return try rename(selected: selected, context: context, expectedVersion: expectedVersion)
    }

    @discardableResult
    public func associateCalendar(meetingID: String, event: CalendarMeeting?, resetTitle: Bool = false,
                                  expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        let selected = try detail(for: meetingID)
        guard !selected.row.isArchived else { throw MeetingManagementError.retryRejected("Archived Meeting metadata is read-only.") }
        let context = try selected.calendarChange(event: event, resetTitle: resetTitle)
        return try rename(selected: selected, context: context, expectedVersion: expectedVersion)
    }

    private func rename(selected: MeetingBrowserDetail, context: MeetingCalendarContext,
                        expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        let committed = try MeetingRename(vault: vault, jobs: jobs, inbox: inbox, index: index,
            enforceWorkspaceOwner: enforceWorkspaceOwner).commit(selected: selected, context: context,
                                                                expectedVersion: expectedVersion)
        if !committed.changedPaths.isEmpty { onMeetingChanged(committed.changedPaths) }
        return try detail(for: committed.meetingID)
    }

    public func retryFailedJob(meetingID: String, jobID: String) throws {
        guard jobs != nil else { throw MeetingManagementError.retryRejected("Job store is unavailable.") }
        let detail = try detail(for: meetingID)
        guard !detail.row.isArchived else { throw MeetingManagementError.retryRejected("Archived Meetings cannot retry processing.") }
        let session = MeetingDoorwayMetadata(detail.doorwayText).sessionID
        let records = try workspaceJobs().filter { MeetingDoorwayMetadata.owns($0, session: session, path: detail.row.meetingRelativePath) }
        guard records.contains(where: { $0.id == jobID }) else { throw MeetingManagementError.retryRejected("This Job does not belong to the selected Meeting.") }
        guard Self.currentJobs(records).contains(where: { $0.id == jobID }) else { throw MeetingManagementError.retryRejected("This Job was superseded by a newer run.") }
        guard let job = records.first(where: { $0.id == jobID }), job.status == .failed else { throw MeetingManagementError.retryRejected("Only a failed Job can be retried.") }
        guard MeetingWorkflowJob.supportedTypes.contains(job.manifest.type) else { throw MeetingManagementError.retryRejected("This Job type cannot be retried here.") }
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
        guard !selected.row.isArchived else { throw MeetingManagementError.retryRejected("Archived Meetings cannot be reprocessed.") }
        guard selected.row.captureState == .stopped else { throw MeetingManagementError.retryRejected("Recording has not stopped.") }
        let path = selected.row.meetingRelativePath
        let session = MeetingDoorwayMetadata(selected.doorwayText).sessionID
        if let reason = retryUnavailableReason(TranscriptionJob.type) { throw MeetingManagementError.retryRejected(reason) }
        if let reason = retryUnavailableReason(MeetingSummaryJob.type) { throw MeetingManagementError.retryRejected(reason) }
        guard let bundlePath = MeetingDoorwayMetadata(selected.doorwayText).bundlePath, !bundlePath.isEmpty,
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
        let id = UUID().uuidString
        let recovery = MeetingReprocessingRecovery(vault: vault)
        let artifacts = try MeetingArtifactStore(vault: vault, inbox: inbox).load(meetingPath: path, meetingID: selected.row.id)
        let transcript = TranscriptionPipeline.artifactPaths(meetingRelativePath: path)
        try recovery.retain(jobID: id, paths: Set(artifacts.paths.values).union([
            transcript.markdown, transcript.json, transcript.vtt, Self.sibling(path, "transcript.txt"),
            Self.sibling(path, "summary-extraction.json"), Self.sibling(path, "meeting-artifacts.json")]))
        let job: JobRecord
        do {
            job = try store.enqueueUnlessActive(id: id, manifest: try MeetingWorkflowJob.manifest(transcription: TranscriptionJob.manifest(title: selected.row.title, bundle: bundle, selection: nil, language: language)).owned(by: vault.rootURL)) {
                MeetingDoorwayMetadata.owns($0, session: session, path: path)
            }
        } catch {
            recovery.discard(jobID: id)
            throw error
        }
        onReprocessQueued()
        return job
    }

    private func proposalMeetingPath(id: String) -> String? {
        guard let inbox else { return nil }
        let proposal: ActionItemProposal?
        do { proposal = try inbox.pendingProposal(id: id) } catch { return nil }
        guard let sourceRef = proposal?.sourceRef, sourceRef.hasPrefix("[[") else {
            return (try? allRows().first { id.hasPrefix("meeting-action:\($0.id):") })?.meetingRelativePath
        }
        let path = String(sourceRef.dropFirst(2)).components(separatedBy: "#").first ?? ""
        guard path.hasPrefix("Meetings/"), !path.isEmpty else { return nil }
        return (path as NSString).deletingLastPathComponent + "/meeting.md"
    }

    private func allRows() throws -> [MeetingBrowserRow] {
        let paths=try vault.markdownPaths(relativeTo:"Meetings").filter { ($0 as NSString).lastPathComponent == "meeting.md" }; var rows:[MeetingBrowserRow]=[]
        let allJobs = (try? workspaceJobs()) ?? []
        for path in paths { let source=try? vault.readMarkdown(relativePath:path); let text=source.flatMap { String(data:$0.data,encoding:.utf8) }; let f=MeetingDoorwayMetadata(text); let live=captureSnapshot().flatMap{$0.meetingRelativePath == path && $0.state != .idle && $0.state != .failed} == true; let session=f.sessionID; let owned=Self.currentJobs(allJobs.filter { job in MeetingDoorwayMetadata.owns(job, session:session, path:path) }); let state=Self.processing(live:live, path:path, jobs:owned, vault:vault)
            let dir=(path as NSString).deletingLastPathComponent
            let extraction = (try? vault.readMarkdown(relativePath:dir+"/summary-extraction.json")).flatMap { try? JSONDecoder().decode(MeetingSummaryExtraction.self, from:$0.data) }.flatMap { $0.meeting == path && $0.schemaVersion == MeetingSummaryExtraction.currentSchemaVersion ? $0 : nil }
            let duration = MeetingPlaybackEvidence(recordingMediaURL: recordingMediaURL)
                .recordedDuration(bundlePath: f.bundlePath, meetingPath: path, session: session)
            let actionIDs = extraction?.myActionItems.map { "meeting-action:\(session ?? path):\($0.id)" } ?? []
            let needsReview = actionIDs.contains { (try? inbox?.proposalReviewState(id:$0)) == .pending }
            rows.append(MeetingBrowserRow(id:try artifactStore.identity(at: path) ?? session ?? path,title:f.title ?? Self.fallbackTitle(path),startedAt:f.startedAt ?? source?.version.modificationDate,meetingRelativePath:path,captureState:live ? .live : (text == nil ? .unavailable : .stopped),processingState:state,project:f.project,job:Self.presentation(for: owned.first),isArchived:try archived(at:path),durationSeconds:duration,hasRecording:f.bundlePath != nil,hasMyActions:!actionIDs.isEmpty,hasOthersActions:extraction?.otherActionItems.isEmpty == false,needsActionReview:needsReview)) }
        if let s=captureSnapshot(), let p=s.meetingRelativePath, s.state != .idle && s.state != .failed, !rows.contains(where:{$0.meetingRelativePath==p}) { rows.append(MeetingBrowserRow(id:p,title:s.meetingTitle ?? Self.fallbackTitle(p),startedAt:nil,meetingRelativePath:p,captureState:.live,processingState:.live)) }
        return rows.sorted { if let a=$0.startedAt, let b=$1.startedAt, a != b { return a>b }; if $0.startedAt != nil { return true }; if $1.startedAt != nil { return false }; return $0.meetingRelativePath < $1.meetingRelativePath }
    }
    private func makeDetail(row: MeetingBrowserRow, source: (data: Data, version: WorkspaceFileVersion)) throws -> MeetingBrowserDetail {
        var text = String(data: source.data, encoding: .utf8) ?? ""
        let path = row.meetingRelativePath
        let dir = (path as NSString).deletingLastPathComponent
        let session = MeetingDoorwayMetadata(text).sessionID
        let allOwned = (try? workspaceJobs().filter { MeetingDoorwayMetadata.owns($0, session: session, path: path) }) ?? []
        let owned = Self.currentJobs(allOwned)
        let presentedJobs = (owned + allOwned.filter { job in
            (job.status == .queued || job.status == .running) && !owned.contains(where: { $0.id == job.id })
        }).map { candidate in
            let reason: String? = candidate.status != .failed ? nil :
                (MeetingWorkflowJob.supportedTypes.contains(candidate.manifest.type)
                 ? retryUnavailableReason(candidate.manifest.type) : "This Job type cannot be retried here.")
            return Self.presentation(for: candidate, retryReason: reason)!
        }
        let primaryJob = presentedJobs.first ?? row.job
        if let workflow = owned.first(where: { $0.manifest.type == MeetingWorkflowJob.type }), workflow.status != .succeeded {
            let inactive = workflow.status == .failed || workflow.status == .dismissed
            return MeetingBrowserDetail(row: row, doorwayText: inactive ? text : "", doorwayVersion: inactive ? source.version : nil,
                                        job: primaryJob, jobs: presentedJobs)
        }
        let usesLegacyArtifacts = try artifactStore.usesLegacyWriter(for: row)
        let canonical = try usesLegacyArtifacts
            ? artifactStore.legacyLoaded(meetingPath: row.meetingRelativePath, meetingID: row.id)
            : artifactStore.load(meetingPath: row.meetingRelativePath, meetingID: row.id)
        let source = try vault.readMarkdown(relativePath: row.meetingRelativePath)
        text = String(data: source.data, encoding: .utf8) ?? ""
        let extraction = canonical.extraction
        let evidence = MeetingPlaybackEvidence(recordingMediaURL: recordingMediaURL)
            .resolve(doorwayText: text, meetingPath: path, transcript: canonical.transcript)
        let playback = evidence.playback
        let transcript = evidence.transcript
        let validExtraction: MeetingSummaryExtraction? = extraction
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
                              reviewState: canonical.reviewStates[item.id] ?? .referenceOnly, completionStatus: canonical.completionStates[item.id])
        }
        let other = (validExtraction?.otherActionItems ?? []).map {
            MeetingActionItem(id: $0.id, text: $0.text, citations: citations($0.citations), referenceOnly: true)
        }
        let currentIDs = Set((validExtraction?.myActionItems ?? []).map { "meeting-action:\(row.id):\($0.id)" })
        let summaryRef = "[[\(dir)/summary#My action items|ref]]"
        let stale = (validExtraction == nil ? [] : ((try? inbox?.items(category: .review)) ?? [])).filter {
            $0.kind == .proposal && $0.sourceRef == summaryRef && $0.id.hasPrefix("meeting-action:\(row.id):") && !currentIDs.contains($0.id)
        }.map { ActionItemProposal(id: $0.id, title: $0.title, sourceRef: summaryRef) }
        var actionDrafts: [String: MeetingActionDraft] = [:]
        if let inbox {
            let proposalPrefix = "meeting-action:\(row.id):"
            for proposal in (try? inbox.items(category: .review)) ?? []
            where proposal.kind == .proposal && proposal.id.hasPrefix(proposalPrefix) {
                if let draft = try? inbox.proposalDraft(id: proposal.id) {
                    actionDrafts[proposal.id] = MeetingActionDraft(title: draft.title, comment: draft.comment)
                }
            }
        }
        var detail = MeetingBrowserDetail(row: row, doorwayText: text, doorwayVersion: source.version, humanNotes: canonical.notes, notesVersion: canonical.notesVersion,
            artifacts: resolvedArtifacts(path: path, evidence: evidence), job: primaryJob,
            jobs: presentedJobs,
            summaryVersion: usesLegacyArtifacts ? canonical.versions["summary"] : canonical.summaryVersion, summary: canonical.sections,
            extraction: validExtraction, myActionItems: mine, otherActionItems: other, staleProposals: stale, transcript: transcript,
            decisions: (validExtraction?.decisions ?? []).map { MeetingCitedOutcome(text: $0.text, citations: citations($0.citations)) },
            openQuestions: (validExtraction?.openQuestions ?? []).map { MeetingCitedOutcome(text: $0.text, citations: citations($0.citations)) }, playback: playback, actionDrafts: actionDrafts)
        if !usesLegacyArtifacts { detail.reviewItems = try artifactStore.reviewItems(meetingPath: path, meetingID: row.id) }
        detail.tagCatalog = try ItemTagStore(vault: vault).tags()
        detail.speakerCorrectionReview = canonical.speakerCorrectionReview
        detail.analysisOutdated = canonical.analysisOutdated
        detail.speakerReviewRequired = canonical.speakerReviewRequired
        return detail
    }
    private func resolvedArtifacts(path: String, evidence: MeetingPlaybackEvidence.Resolution) -> [MeetingArtifact] {
        let directory = (path as NSString).deletingLastPathComponent
        var artifacts = [MeetingArtifact(role: .doorway, relativePath: path, available: true), evidence.bundleArtifact]
        for (role, name, label) in [(MeetingArtifactRole.transcript, "transcript.md", "Transcript"), (.summary, "summary.md", "Summary"), (.extraction, "summary-extraction.json", "Summary extraction")] {
            let relativePath = directory + "/" + name
            let available = (try? vault.readMarkdown(relativePath: relativePath)) != nil
            artifacts.append(MeetingArtifact(role: role, relativePath: relativePath, available: available, message: available ? nil : "\(label) unavailable"))
        }
        return artifacts + evidence.sourceArtifacts
    }
    private static func presentation(for job: JobRecord?, retryReason: String? = nil) -> MeetingJobPresentation? {
        guard let job else { return nil }
        let stage = job.stages.first { $0.status == .running || $0.status == .failed || $0.status == .pending }
        return MeetingJobPresentation(
            jobID: job.id, title: job.manifest.title, status: job.status,
            stage: stage?.definition.title, error: stage?.lastError ?? job.failureDetails,
            attemptCount: stage?.attemptCount ?? 0, retryReason: retryReason,
            stageID: stage?.definition.id
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

    private static func processing(live:Bool,path:String,jobs:[JobRecord],vault:WorkspaceVault)->MeetingProcessingState { if live{return .live}; if jobs.contains(where:{$0.status == .queued || $0.status == .running}) {return .processing}; if jobs.contains(where:{$0.status == .failed}) {return .needsAttention}; let dir=(path as NSString).deletingLastPathComponent; let t=Self.validTranscript(path: dir+"/transcript.json", vault: vault) && (try? vault.readMarkdown(relativePath: dir+"/transcript.md")) != nil, s=(try? vault.readMarkdown(relativePath:dir+"/summary.md")) != nil && (try? vault.readMarkdown(relativePath:dir+"/summary-extraction.json")).flatMap { try? JSONDecoder().decode(MeetingSummaryExtraction.self, from: $0.data) } != nil; return t && s ? .ready : .needsAttention }
    private static func validTranscript(path: String, vault: WorkspaceVault) -> Bool { guard let data = try? vault.readMarkdown(relativePath: path).data else { return false }; let decoder=JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return (try? decoder.decode(TranscriptDocument.self, from: data)) != nil }
    private static func sibling(_ path:String,_ name:String)->String {(path as NSString).deletingLastPathComponent+"/"+name}
    private static func frontmatter(_ text:String)->String { guard text.hasPrefix("---") else{return "---\n---\n"}; guard let r=text.range(of:"---",range:text.index(text.startIndex,offsetBy:3)..<text.endIndex) else{return "---\n---\n"}; return String(text[..<text.index(after:r.upperBound)])+"\n" }
    private static func renderSummary(_ s:MeetingSummarySections)->String { ["## Summary",s.summary,"## Decisions",s.decisions,"## My action items",s.myActionItems,"## Other action items",s.otherActionItems,"## Open questions",s.openQuestions].joined(separator:"\n\n")+"\n" }
    private static func parseSummary(_ text:String)->MeetingSummarySections { var values=MeetingSummarySections(); var key=""; for line in text.components(separatedBy:.newlines) { if line.hasPrefix("## "){key=String(line.dropFirst(3)).lowercased();continue}; switch key {case "summary":values.summary += (values.summary.isEmpty ? "":"\n")+line;case "decisions":values.decisions += (values.decisions.isEmpty ? "":"\n")+line;case "my action items":values.myActionItems += (values.myActionItems.isEmpty ? "":"\n")+line;case "other action items":values.otherActionItems += (values.otherActionItems.isEmpty ? "":"\n")+line;case "open questions":values.openQuestions += (values.openQuestions.isEmpty ? "":"\n")+line;default:break} }; return values }
    private static func fallbackTitle(_ path:String)->String { ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent.replacingOccurrences(of:"-",with:" ").capitalized }
}
