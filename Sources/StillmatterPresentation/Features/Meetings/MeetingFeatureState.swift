import Combine
import Foundation
import StillmatterCore

public enum MeetingQueueFilter: Int, Equatable {
    case recorded
    case attention
    case ready

    public func filter(_ rows: [MeetingBrowserRow]) -> [MeetingBrowserRow] {
        switch self {
        case .recorded:
            rows
        case .attention:
            rows.filter(\.requiresAttention)
        case .ready:
            rows.filter { $0.processingState == .ready && !$0.requiresAttention }
        }
    }
}

/// An editable value keeps the exact canonical version from the start of the editing session.
public struct MeetingTextDraft: Equatable {
    public private(set) var originalText: String
    public private(set) var editedText: String
    public private(set) var baseVersion: WorkspaceFileVersion?
    public private(set) var isEditing: Bool

    public init(originalText: String, baseVersion: WorkspaceFileVersion?) {
        self.originalText = originalText
        editedText = originalText
        self.baseVersion = baseVersion
        isEditing = false
    }

    public var isDirty: Bool { editedText != originalText }

    public mutating func beginEditing() { isEditing = true }
    public mutating func update(_ text: String) {
        if !isEditing { isEditing = true }
        editedText = text
    }

    /// Clean drafts follow refreshed canonical content. Dirty drafts retain both text and baseVersion.
    public mutating func refresh(originalText: String, baseVersion: WorkspaceFileVersion?) {
        guard !isDirty else { return }
        self.originalText = originalText
        editedText = originalText
        self.baseVersion = baseVersion
    }

    /// Explicit conflict resolution; callers must get the user's confirmation before invoking this.
    public mutating func reload(originalText: String, baseVersion: WorkspaceFileVersion?) {
        self.originalText = originalText
        editedText = originalText
        self.baseVersion = baseVersion
        isEditing = false
    }

    public mutating func saved(text: String, baseVersion: WorkspaceFileVersion?) {
        originalText = text
        editedText = text
        self.baseVersion = baseVersion
        isEditing = false
    }

    public mutating func discard() {
        editedText = originalText
        isEditing = false
    }
}

public enum MeetingDetailPage: Equatable { case overview, transcript }

public enum MeetingDetailLoadState: Equatable {
    case idle
    case loading
    case loaded
    case unavailable(String)
    case failed(String)
}

public enum MeetingMutationState: Equatable {
    case idle
    case running(String)
    case succeeded(String)
    case failed(String, conflict: Bool)
}

public enum MeetingMutation {
    case saveNotes(meetingID: String, text: String, baseVersion: WorkspaceFileVersion)
    case saveSummary(meetingID: String, sections: MeetingSummarySections, baseVersion: WorkspaceFileVersion)
    case saveActionDraft(id: String, title: String, comment: String)
    case reviewAction(id: String, accept: Bool)
    case archive(meetingID: String)
    case restore(meetingID: String)
    case rename(meetingID: String, title: String, baseVersion: WorkspaceFileVersion)
    case remove(meetingID: String)
    case retry(meetingID: String, jobID: String)
    case reprocess(meetingID: String, language: TranscriptLanguage)
}

public enum MeetingMutationOutput {
    case detail(MeetingBrowserDetail)
    case job(JobRecord)
    case none
}

/// Implementations serialize writes and deliver completion on the main queue.
public protocol MeetingMutationExecuting: AnyObject {
    func execute(_ mutation: MeetingMutation,
                 completion: @escaping (Result<MeetingMutationOutput, Error>) -> Void)
}

public struct MeetingPlaybackTransportState: Equatable {
    public let source: MeetingPlayback?
    public let position: Double
    public let duration: Double
    public let isPlaying: Bool
    public let isAvailable: Bool
    public let waveform: [Double]
    public let errorMessage: String?

    public init(source: MeetingPlayback? = nil, position: Double = 0, duration: Double = 0,
                isPlaying: Bool = false, isAvailable: Bool = false, waveform: [Double] = [],
                errorMessage: String? = nil) {
        self.source = source
        self.position = position
        self.duration = duration
        self.isPlaying = isPlaying
        self.isAvailable = isAvailable
        self.waveform = waveform
        self.errorMessage = errorMessage
    }
}

@MainActor
public protocol MeetingPlaybackTransport: AnyObject {
    var state: MeetingPlaybackTransportState { get }
    var onChange: ((MeetingPlaybackTransportState) -> Void)? { get set }
    func load(_ source: MeetingPlayback)
    func play()
    func pause()
    func seek(to seconds: Double)
    func stop()
}

@MainActor
public final class MeetingDetailModel: ObservableObject {
    @Published public private(set) var detail: MeetingBrowserDetail?
    @Published public private(set) var loadState: MeetingDetailLoadState = .idle
    @Published public private(set) var isShowingStaleDetail = false
    @Published public private(set) var page: MeetingDetailPage = .overview
    @Published public private(set) var notesDraft: MeetingTextDraft?
    @Published public private(set) var summaryDraft: MeetingTextDraft?
    @Published public private(set) var mutationState: MeetingMutationState = .idle
    @Published public private(set) var selectedActionProposalIDs: Set<String> = []
    @Published public private(set) var playbackState = MeetingPlaybackTransportState()

    private var readModel: MeetingReadModel?
    private var mutationExecutor: MeetingMutationExecuting?
    private var playbackTransport: MeetingPlaybackTransport?
    private var playbackChangeHandler: ((MeetingPlaybackTransportState) -> Void)?
    private var detailRequest: MeetingReadRequest?
    private var requestRevision: UInt64 = 0
    private var selectedReference: MeetingReference?
    private var mutationInFlight = false
    private var mutationGeneration: UInt64 = 0
    private var playbackGeneration: UInt64 = 0

    public init() {}

    public var selectedMeetingID: String? { selectedReference?.id }
    public var hasDirtyDrafts: Bool { notesDraft?.isDirty == true || summaryDraft?.isDirty == true }
    public var isMutationInFlight: Bool { mutationInFlight }

    public func bind(readModel: MeetingReadModel?, mutationExecutor: MeetingMutationExecuting?,
                     playbackTransport: MeetingPlaybackTransport?) {
        if self.readModel !== readModel {
            mutationGeneration &+= 1
            mutationInFlight = false
            mutationState = .idle
            detailRequest?.cancel()
            detailRequest = nil
            requestRevision &+= 1
        }
        self.readModel = readModel
        self.mutationExecutor = mutationExecutor
        if self.playbackTransport !== playbackTransport {
            playbackGeneration &+= 1
            self.playbackTransport?.stop()
            self.playbackTransport?.onChange = nil
            self.playbackTransport = playbackTransport
            let generation = playbackGeneration
            playbackChangeHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.playbackGeneration == generation else { return }
                    self.playbackState = state
                }
            }
            playbackTransport?.onChange = playbackChangeHandler
            playbackState = playbackTransport?.state ?? MeetingPlaybackTransportState()
        }
    }

    public func select(_ reference: MeetingReference?) {
        guard reference != selectedReference else { return }
        detailRequest?.cancel()
        detailRequest = nil
        requestRevision &+= 1
        selectedReference = reference
        mutationGeneration &+= 1
        mutationInFlight = false
        mutationState = .idle
        page = .overview
        guard let reference else {
            detail = nil
            notesDraft = nil
            summaryDraft = nil
            loadState = .idle
            isShowingStaleDetail = false
            playbackTransport?.stop()
            playbackState = playbackTransport?.state ?? MeetingPlaybackTransportState()
            selectedActionProposalIDs = []
            return
        }
        let sameMeeting = detail?.row.id == reference.id && detail?.row.meetingRelativePath == reference.meetingRelativePath
        if !sameMeeting {
            detail = nil
            notesDraft = nil
            summaryDraft = nil
            selectedActionProposalIDs = []
            playbackTransport?.stop()
        }
        loadState = .loading
        isShowingStaleDetail = sameMeeting && detail != nil
        readDetail(reference, revision: requestRevision)
    }

    #if DEBUG
    public var task05BoundModel: MeetingReadModel? { readModel }
    #endif

    public func refreshSelectedDetail(completion: ((Result<MeetingBrowserDetail, Error>) -> Void)? = nil) {
        guard let reference = selectedReference else { completion?(.failure(MeetingManagementError.unavailable)); return }
        requestRevision &+= 1
        let revision = requestRevision
        detailRequest?.cancel()
        loadState = .loading
        isShowingStaleDetail = detail != nil
        guard let readModel else { completion?(.failure(MeetingManagementError.unavailable)); return }
        detailRequest = readModel.readDetail(for: reference) { [weak self] result in
            Task { @MainActor in
                guard let self, self.requestRevision == revision, self.selectedReference == reference else { return }
                switch result {
                case let .success(detail): self.apply(detail); completion?(.success(detail))
                case let .failure(error):
                    let message = Self.message(for: error)
                    self.loadState = message.hasPrefix("Choose a workspace") ? .unavailable(message) : .failed(message)
                    completion?(.failure(error))
                }
            }
        }
    }

    public func setPage(_ page: MeetingDetailPage) { self.page = page }

    public func beginEditingNotes() { notesDraft?.beginEditing() }
    public func updateNotesDraft(_ text: String) { notesDraft?.update(text) }
    public func beginEditingSummary() { summaryDraft?.beginEditing() }
    public func updateSummaryDraft(_ text: String) { summaryDraft?.update(text) }

    public func discardDrafts() {
        // Explicit discard adopts the current canonical content, including an external
        // version that arrived while the old local draft was dirty.
        reloadDraftsAfterConfirmation()
    }

    public func reloadDraftsAfterConfirmation() {
        guard let detail else { return }
        notesDraft?.reload(originalText: detail.humanNotes, baseVersion: detail.notesVersion)
        summaryDraft?.reload(originalText: detail.summary?.summary ?? "", baseVersion: detail.summaryVersion)
    }

    public func saveNotes(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let detail, let draft = notesDraft, draft.isDirty,
              let version = draft.baseVersion else {
            completion?(.failure(MeetingManagementError.unavailable))
            return
        }
        perform(.saveNotes(meetingID: detail.row.id, text: draft.editedText, baseVersion: version),
                progress: "Saving notes…", completion: completion) { [weak self] output in
            guard case let .detail(saved) = output else { throw MeetingManagementError.unavailable }
            self?.apply(saved)
            self?.notesDraft?.saved(text: saved.humanNotes, baseVersion: saved.notesVersion)
        }
    }

    public func saveSummary(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let detail, let draft = summaryDraft, draft.isDirty,
              let version = draft.baseVersion, var sections = detail.summary else {
            completion?(.failure(MeetingManagementError.unavailable))
            return
        }
        sections.summary = draft.editedText
        perform(.saveSummary(meetingID: detail.row.id, sections: sections, baseVersion: version),
                progress: "Saving Summary…", completion: completion) { [weak self] output in
            guard case let .detail(saved) = output else { throw MeetingManagementError.unavailable }
            self?.apply(saved)
            self?.summaryDraft?.saved(text: saved.summary?.summary ?? "", baseVersion: saved.summaryVersion)
        }
    }

    public func saveDirtyDrafts(completion: @escaping (Result<Void, Error>) -> Void) {
        if notesDraft?.isDirty == true {
            saveNotes { [weak self] result in
                switch result {
                case .failure: completion(result)
                case .success:
                    if self?.summaryDraft?.isDirty == true { self?.saveSummary(completion: completion) }
                    else { completion(.success(())) }
                }
            }
        } else if summaryDraft?.isDirty == true {
            saveSummary(completion: completion)
        } else {
            completion(.success(()))
        }
    }

    public func selectActionProposals(_ ids: Set<String>) { selectedActionProposalIDs = ids }

    public func saveActionDraft(id: String, title: String, comment: String,
                                completion: ((Result<Void, Error>) -> Void)? = nil) {
        perform(.saveActionDraft(id: id, title: title, comment: comment),
                progress: "Saving Action Item…", completion: completion)
    }

    public func reviewAction(id: String, accept: Bool,
                             completion: ((Result<Void, Error>) -> Void)? = nil) {
        perform(.reviewAction(id: id, accept: accept), progress: accept ? "Accepting Action Item…" : "Dismissing Action Item…",
                completion: completion)
    }

    public func archive(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let detail else { completion?(.failure(MeetingManagementError.unavailable)); return }
        perform(.archive(meetingID: detail.row.id), progress: "Archiving Meeting…", completion: completion)
    }

    public func restore(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let detail else { completion?(.failure(MeetingManagementError.unavailable)); return }
        perform(.restore(meetingID: detail.row.id), progress: "Restoring Meeting…", completion: completion)
    }

    public func rename(to title: String, completion: ((Result<MeetingBrowserDetail, Error>) -> Void)? = nil) {
        guard !hasDirtyDrafts else { completion?(.failure(MeetingManagementError.unavailable)); return }
        guard let detail, let version = detail.doorwayVersion else {
            completion?(.failure(MeetingManagementError.unavailable)); return
        }
        performOutput(.rename(meetingID: detail.row.id, title: title, baseVersion: version),
                      progress: "Renaming Meeting…", completion: { result in
            switch result {
            case let .success(.detail(renamed)): completion?(.success(renamed))
            case .success: completion?(.failure(MeetingManagementError.unavailable))
            case let .failure(error): completion?(.failure(error))
            }
        }, apply: { [weak self] output in
            guard case let .detail(renamed) = output else { throw MeetingManagementError.unavailable }
            self?.apply(renamed)
        })
    }

    public func remove(completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard !hasDirtyDrafts else { completion?(.failure(MeetingManagementError.unavailable)); return }
        guard let detail else { completion?(.failure(MeetingManagementError.unavailable)); return }
        perform(.remove(meetingID: detail.row.id), progress: "Removing Meeting…", completion: completion) { [weak self] _ in
            self?.select(nil)
        }
    }

    public func retry(jobID: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let detail else { completion?(.failure(MeetingManagementError.unavailable)); return }
        perform(.retry(meetingID: detail.row.id, jobID: jobID), progress: "Retrying processing…", completion: completion)
    }

    public func reprocess(language: TranscriptLanguage,
                          completion: ((Result<JobRecord, Error>) -> Void)? = nil) {
        guard !hasDirtyDrafts else { completion?(.failure(MeetingManagementError.unavailable)); return }
        guard let detail else { completion?(.failure(MeetingManagementError.unavailable)); return }
        performOutput(.reprocess(meetingID: detail.row.id, language: language), progress: "Reprocessing Meeting…", completion: { result in
            switch result {
            case let .success(.job(job)): completion?(.success(job))
            case .success: completion?(.failure(MeetingManagementError.unavailable))
            case let .failure(error): completion?(.failure(error))
            }
        })
    }

    public func togglePlayback() {
        if playbackState.isPlaying { playbackTransport?.pause() } else { playbackTransport?.play() }
    }

    public func seekPlayback(to seconds: Double) { playbackTransport?.seek(to: seconds) }
    public func stopPlayback() {
        playbackTransport?.stop()
        playbackState = playbackTransport?.state ?? MeetingPlaybackTransportState()
    }

    public func stop() {
        detailRequest?.cancel()
        detailRequest = nil
        requestRevision &+= 1
        mutationGeneration &+= 1
        mutationInFlight = false
        mutationState = .idle
        playbackTransport?.stop()
        playbackState = playbackTransport?.state ?? MeetingPlaybackTransportState()
    }

    private func readDetail(_ reference: MeetingReference, revision: UInt64) {
        guard let readModel else {
            detail = nil
            loadState = .unavailable("Meeting read model is not configured.")
            return
        }
        detailRequest = readModel.readDetail(for: reference) { [weak self] result in
            Task { @MainActor in
                guard let self, self.requestRevision == revision, self.selectedReference == reference else { return }
                switch result {
                case let .success(detail): self.apply(detail)
                case .failure(.workspaceUnavailable), .failure(.stopped):
                    self.loadState = .unavailable("Meeting workspace is unavailable.")
                    self.isShowingStaleDetail = self.detail != nil
                case let .failure(error):
                    let message = Self.message(for: error)
                    self.loadState = message.hasPrefix("Choose a workspace") ? .unavailable(message) : .failed(message)
                    self.isShowingStaleDetail = self.detail != nil
                }
            }
        }
    }

    private func apply(_ detail: MeetingBrowserDetail) {
        guard selectedReference?.id == detail.row.id,
              selectedReference?.meetingRelativePath == detail.row.meetingRelativePath else { return }
        self.detail = detail
        if notesDraft == nil { notesDraft = MeetingTextDraft(originalText: detail.humanNotes, baseVersion: detail.notesVersion) }
        else { notesDraft?.refresh(originalText: detail.humanNotes, baseVersion: detail.notesVersion) }
        if summaryDraft == nil { summaryDraft = MeetingTextDraft(originalText: detail.summary?.summary ?? "", baseVersion: detail.summaryVersion) }
        else { summaryDraft?.refresh(originalText: detail.summary?.summary ?? "", baseVersion: detail.summaryVersion) }
        loadState = .loaded
        isShowingStaleDetail = false
        playbackTransport?.load(detail.playback)
        playbackState = playbackTransport?.state ?? playbackState
    }

    private func perform(_ mutation: MeetingMutation, progress: String,
                         completion: ((Result<Void, Error>) -> Void)? = nil,
                         apply: ((MeetingMutationOutput) throws -> Void)? = nil) {
        performOutput(mutation, progress: progress, completion: { result in
            completion?(result.map { _ in () })
        }, apply: apply)
    }

    private func performOutput(_ mutation: MeetingMutation, progress: String,
                               completion: ((Result<MeetingMutationOutput, Error>) -> Void)? = nil,
                               apply: ((MeetingMutationOutput) throws -> Void)? = nil) {
        guard !mutationInFlight, let mutationExecutor else {
            completion?(.failure(MeetingManagementError.unavailable))
            return
        }
        mutationInFlight = true
        mutationState = .running(progress)
        let generation = mutationGeneration
        let origin = readModel
        let reference = selectedReference
        mutationExecutor.execute(mutation) { [weak self] result in
            Task { @MainActor in
                // The executor completes its durable write against its captured vault, and
                // the service invalidates that origin. Only publication is generation-bound.
                guard let self, self.mutationGeneration == generation,
                      self.readModel === origin, self.selectedReference == reference else { return }
                self.mutationInFlight = false
                switch result {
                case let .success(output):
                    do {
                        try apply?(output)
                        self.mutationState = .succeeded(progress)
                        completion?(.success(output))
                    } catch {
                        self.mutationState = .failed(error.localizedDescription, conflict: false)
                        completion?(.failure(error))
                    }
                case let .failure(error):
                    let conflict = (error as? WorkspaceVaultError).map {
                        if case .conflict = $0 { true } else { false }
                    } ?? false
                    self.mutationState = .failed(error.localizedDescription, conflict: conflict)
                    completion?(.failure(error))
                }
            }
        }
    }

    private static func message(for error: MeetingReadError) -> String {
        switch error {
        case .workspaceUnavailable: return "Meeting workspace is unavailable."
        case .stopped: return "Meeting reads have stopped."
        case let .meetingNotInBrowser(reference): return "Meeting is no longer available: \(reference.meetingRelativePath)"
        case let .sourceFailure(sourceError):
            if (sourceError as? MeetingManagementError) == .some(.unavailable) {
                return "Choose a workspace in Settings to see Meetings."
            }
            return "Could not load Meeting: \(sourceError.localizedDescription)"
        }
    }
}

public enum MeetingSelectionDecision: Equatable { case save, discard, cancel }
public enum MeetingSelectionRequestResult: Equatable { case applied, requiresDecision }

@MainActor
public final class MeetingsModel: ObservableObject {
    @Published public private(set) var snapshot: MeetingBrowserSnapshot?
    @Published public private(set) var loadState: MeetingDetailLoadState = .idle
    @Published public private(set) var selectedMeetingID: String?
    @Published public private(set) var selectedMeetingIDs: Set<String> = []
    @Published public private(set) var queueFilter: MeetingQueueFilter = .recorded
    @Published public private(set) var filters = MeetingBrowserFilters()
    @Published public private(set) var pendingSelectionDecision = false
    @Published public private(set) var pendingWorkspaceDecision = false

    public let detail: MeetingDetailModel

    private let readModelProvider: () -> MeetingReadModel?
    private let mutationExecutorProvider: () -> MeetingMutationExecuting?
    private let playbackTransportProvider: () -> MeetingPlaybackTransport?
    private var mutableSelectionState = MeetingBrowserPresentationState()
    private var readModel: MeetingReadModel?
    private var mutationExecutor: MeetingMutationExecuting?
    private var playbackTransport: MeetingPlaybackTransport?
    private var observation: MeetingChangeObservation?
    private var browserRequest: MeetingReadRequest?
    private var requestRevision: UInt64 = 0
    private var pendingSelection: (id: String?, ids: Set<String>)?
    private var queueBeforePendingSelection: MeetingQueueFilter?
    private var pendingReadModel: MeetingReadModel?
    private var pendingMutationExecutor: MeetingMutationExecuting?
    private var pendingPlaybackTransport: MeetingPlaybackTransport?
    private var ignoredReadModel: MeetingReadModel?
    private var isActive = false
    private var needsSelectedDetailRefresh = false

    public init(readModelProvider: @escaping () -> MeetingReadModel?,
                mutationExecutorProvider: @escaping () -> MeetingMutationExecuting? = { nil },
                playbackTransportProvider: @escaping () -> MeetingPlaybackTransport? = { nil },
                detail: MeetingDetailModel? = nil) {
        self.readModelProvider = readModelProvider
        self.mutationExecutorProvider = mutationExecutorProvider
        self.playbackTransportProvider = playbackTransportProvider
        self.detail = detail ?? MeetingDetailModel()
    }

    public var visibleRows: [MeetingBrowserRow] { queueFilter.filter(snapshot?.visibleRows ?? []) }
    public var availableRows: [MeetingBrowserRow] { snapshot?.availableRows ?? [] }
    public var isDirty: Bool { detail.hasDirtyDrafts }

    public func archive(completion: ((Result<Void, Error>) -> Void)? = nil) { detail.archive(completion: completion) }
    public func restore(completion: ((Result<Void, Error>) -> Void)? = nil) { detail.restore(completion: completion) }
    public func remove(completion: ((Result<Void, Error>) -> Void)? = nil) { detail.remove(completion: completion) }
    public func rename(to title: String, completion: ((Result<MeetingBrowserDetail, Error>) -> Void)? = nil) { detail.rename(to: title, completion: completion) }
    public func reprocess(language: TranscriptLanguage, completion: ((Result<JobRecord, Error>) -> Void)? = nil) { detail.reprocess(language: language, completion: completion) }
    public func retry(jobID: String, completion: ((Result<Void, Error>) -> Void)? = nil) { detail.retry(jobID: jobID, completion: completion) }

    public func activate() {
        isActive = true
        needsSelectedDetailRefresh = true
        connectIfNeeded()
        observeReadModelIfNeeded()
        refresh()
    }

    public func deactivate() {
        isActive = false
        browserRequest?.cancel()
        browserRequest = nil
        observation?.cancel()
        observation = nil
        detail.stop()
    }

    public func updateFilters(_ filters: MeetingBrowserFilters) {
        guard self.filters != filters else { return }
        self.filters = filters
        refresh()
    }

    public func setQueueFilter(_ filter: MeetingQueueFilter, resetProcessingFilter: Bool = false) {
        guard queueFilter != filter || resetProcessingFilter else { return }
        if detail.hasDirtyDrafts && queueBeforePendingSelection == nil {
            queueBeforePendingSelection = queueFilter
        }
        queueFilter = filter
        if resetProcessingFilter && filters.processing != .all {
            var updated = filters
            updated.processing = .all
            filters = updated
        }
        // The browser view observes snapshot to reload its table, while its rows also depend
        // on this queue. Publish the current snapshot before AppKit can request stale row indices.
        if let snapshot { self.snapshot = snapshot }
        reconcileSelection()
        if !pendingSelectionDecision { queueBeforePendingSelection = nil }
    }

    public func refresh() {
        connectIfNeeded()
        guard isActive, let readModel else {
            loadState = .unavailable("Meeting workspace is not configured.")
            return
        }
        requestRevision &+= 1
        let revision = requestRevision
        browserRequest?.cancel()
        loadState = .loading
        browserRequest = readModel.readBrowser(filters: filters) { [weak self] result in
            Task { @MainActor in
                guard let self, self.isActive, self.requestRevision == revision else { return }
                switch result {
                case let .success(snapshot):
                    self.loadState = .loaded
                    self.apply(snapshot)
                case .failure(.workspaceUnavailable), .failure(.stopped):
                    self.loadState = .unavailable("Meeting workspace is unavailable.")
                case let .failure(error):
                    let message = Self.message(for: error)
                    self.loadState = message.hasPrefix("Choose a workspace") ? .unavailable(message) : .failed(message)
                }
            }
        }
    }

    public func select(meetingID: String?, selectedIDs: Set<String>) -> MeetingSelectionRequestResult {
        let id = meetingID ?? selectedIDs.first
        let ids = selectedIDs.union(id.map { [$0] } ?? [])
        guard (id != selectedMeetingID || ids != selectedMeetingIDs), detail.hasDirtyDrafts else {
            commitSelection(id: id, ids: ids)
            return .applied
        }
        pendingSelection = (id, ids)
        pendingSelectionDecision = true
        // @Published delivers before storing true. A synchronous alert may already have
        // resolved and cleared the request inside that delivery; do not leave a stale flag.
        if pendingSelection == nil { pendingSelectionDecision = false }
        return .requiresDecision
    }

    public func resolvePendingSelection(_ decision: MeetingSelectionDecision,
                                        completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard let pendingSelection else { return }
        switch decision {
        case .cancel:
            self.pendingSelection = nil
            if let previousQueue = queueBeforePendingSelection {
                queueBeforePendingSelection = nil
                queueFilter = previousQueue
                if let snapshot { self.snapshot = snapshot }
            }
            pendingSelectionDecision = false
            completion?(.success(()))
        case .discard:
            queueBeforePendingSelection = nil
            detail.discardDrafts()
            self.pendingSelection = nil
            pendingSelectionDecision = false
            commitSelection(id: pendingSelection.id, ids: pendingSelection.ids)
            completion?(.success(()))
        case .save:
            detail.saveDirtyDrafts { [weak self] result in
                guard let self else { return }
                if case .success = result {
                    self.queueBeforePendingSelection = nil
                    self.pendingSelection = nil
                    self.pendingSelectionDecision = false
                    self.commitSelection(id: pendingSelection.id, ids: pendingSelection.ids)
                }
                completion?(result)
            }
        }
    }

    public func resolvePendingWorkspaceChange(_ decision: MeetingSelectionDecision,
                                             completion: ((Result<Void, Error>) -> Void)? = nil) {
        guard pendingWorkspaceDecision else { return }
        switch decision {
        case .cancel:
            ignoredReadModel = pendingReadModel
            clearPendingWorkspace()
            completion?(.success(()))
        case .discard:
            detail.discardDrafts()
            installPendingWorkspace()
            completion?(.success(()))
        case .save:
            detail.saveDirtyDrafts { [weak self] result in
                guard let self else { return }
                if case .success = result { self.installPendingWorkspace() }
                completion?(result)
            }
        }
    }

    public func stop() {
        deactivate()
        detail.bind(readModel: nil, mutationExecutor: nil, playbackTransport: nil)
    }

    #if DEBUG
    public var task05ReadRows: [String: String]? { readModel?.task05LatestRows }
    public var task05DetailBindingMatches: Bool { detail.task05BoundModel === readModel }
    #endif

    private func connectIfNeeded() {
        let candidate = readModelProvider()
        guard candidate !== ignoredReadModel else { return }
        guard candidate !== readModel else { return }
        let executor = mutationExecutorProvider()
        let playback = playbackTransportProvider()
        if readModel != nil && detail.hasDirtyDrafts {
            pendingReadModel = candidate
            pendingMutationExecutor = executor
            pendingPlaybackTransport = playback
            pendingWorkspaceDecision = true
            return
        }
        install(candidate, executor: executor, playback: playback)
    }

    private func install(_ candidate: MeetingReadModel?, executor: MeetingMutationExecuting?,
                         playback: MeetingPlaybackTransport?) {
        requestRevision &+= 1
        browserRequest?.cancel()
        browserRequest = nil
        observation?.cancel()
        observation = nil
        readModel = candidate
        mutationExecutor = executor
        playbackTransport = playback
        detail.bind(readModel: candidate, mutationExecutor: executor, playbackTransport: playback)
        snapshot = nil
        selectedMeetingID = nil
        selectedMeetingIDs = []
        mutableSelectionState.clear()
        detail.select(nil)
        guard candidate != nil else {
            snapshot = nil
            selectedMeetingID = nil
            selectedMeetingIDs = []
            detail.select(nil)
            loadState = .unavailable("Meeting workspace is not configured.")
            return
        }
        observeReadModelIfNeeded()
    }

    private func observeReadModelIfNeeded() {
        guard observation == nil, let readModel else { return }
        observation = readModel.observeChanges { [weak self] event in
            Task { @MainActor in self?.receive(event) }
        }
    }

    private func installPendingWorkspace() {
        let candidate = pendingReadModel
        let executor = pendingMutationExecutor
        let playback = pendingPlaybackTransport
        clearPendingWorkspace()
        ignoredReadModel = nil
        install(candidate, executor: executor, playback: playback)
        refresh()
    }

    private func clearPendingWorkspace() {
        pendingReadModel = nil
        pendingMutationExecutor = nil
        pendingPlaybackTransport = nil
        pendingWorkspaceDecision = false
    }

    private func commitSelection(id: String?, ids: Set<String>) {
        let visible = Set(visibleRows.map(\.id))
        let validIDs = ids.intersection(visible)
        let nextID = id.flatMap { visible.contains($0) ? $0 : nil } ?? visibleRows.first?.id
        selectedMeetingID = nextID
        selectedMeetingIDs = nextID.map { validIDs.isEmpty ? Set([$0]) : validIDs.union([$0]) } ?? []
        mutableSelectionState.clear()
        if let nextID { mutableSelectionState.select(nextID, alsoSelected: selectedMeetingIDs) }
        let row = visibleRows.first { $0.id == nextID }
        detail.select(row.map(MeetingReference.init(row:)))
    }

    private func reconcileSelection() {
        let visibleIDs = visibleRows.map(\.id)
        var nextState = mutableSelectionState
        let reconciled = nextState.reconcile(visibleMeetingIDs: visibleIDs,
                                             selectedMeetingIDs: selectedMeetingIDs)
        let ids = nextState.selectedMeetingIDs
        if (reconciled != selectedMeetingID || ids != selectedMeetingIDs) && detail.hasDirtyDrafts {
            pendingSelection = (reconciled, ids)
            pendingSelectionDecision = true
            if pendingSelection == nil { pendingSelectionDecision = false }
            return
        }
        mutableSelectionState = nextState
        selectedMeetingID = reconciled
        selectedMeetingIDs = ids
        let row = visibleRows.first { $0.id == reconciled }
        detail.select(row.map(MeetingReference.init(row:)))
    }

    private func apply(_ newSnapshot: MeetingBrowserSnapshot) {
        if snapshot != newSnapshot { snapshot = newSnapshot }
        let visibleIDs = visibleRows.map(\.id)
        var nextState = mutableSelectionState
        let reconciled = nextState.reconcile(visibleMeetingIDs: visibleIDs,
                                             selectedMeetingIDs: selectedMeetingIDs)
        let ids = nextState.selectedMeetingIDs
        let selectedRow = visibleRows.first { $0.id == reconciled }
        let selectedPathChanged = selectedRow != nil && detail.detail != nil &&
            selectedRow?.meetingRelativePath != detail.detail?.row.meetingRelativePath
        if (reconciled != selectedMeetingID || ids != selectedMeetingIDs || selectedPathChanged) && detail.hasDirtyDrafts {
            pendingSelection = (reconciled, ids)
            pendingSelectionDecision = true
            if pendingSelection == nil { pendingSelectionDecision = false }
            return
        }
        mutableSelectionState = nextState
        selectedMeetingID = reconciled
        selectedMeetingIDs = ids
        if selectedRow?.id != detail.selectedMeetingID || selectedRow?.meetingRelativePath != detail.detail?.row.meetingRelativePath {
            detail.select(selectedRow.map(MeetingReference.init(row:)))
            needsSelectedDetailRefresh = false
        } else if needsSelectedDetailRefresh {
            needsSelectedDetailRefresh = false
            detail.refreshSelectedDetail()
        }
    }

    private func receive(_ event: MeetingReadChangeEvent) {
        // Wait for the new browser projection before reading detail: its latest row may
        // still have the pre-edit title if a detail read races ahead of the browser read.
        if event.requiresRescan ||
            (selectedMeetingID.map { event.affectedMeetingIDs.contains($0) } ?? false) {
            needsSelectedDetailRefresh = true
        }
        refresh()
    }

    private static func message(for error: MeetingReadError) -> String {
        switch error {
        case .workspaceUnavailable: return "Meeting workspace is unavailable."
        case .stopped: return "Meeting reads have stopped."
        case let .meetingNotInBrowser(reference): return "Meeting is no longer available: \(reference.meetingRelativePath)"
        case let .sourceFailure(sourceError):
            if (sourceError as? MeetingManagementError) == .some(.unavailable) {
                return "Choose a workspace in Settings to see Meetings."
            }
            return "Could not load Meetings: \(sourceError.localizedDescription)"
        }
    }
}
