import Foundation

public enum CaptureState: String, Codable, Equatable, CaseIterable {
    case idle
    case detecting
    case starting
    case recording
    case stopping
    case finalizing
    case failed
    case recovered
}

public enum CaptureEvent: Equatable {
    case detectionStarted
    case detectionEnded
    case startRequested
    case captureStarted
    case stopRequested
    case captureStopped
    case captureReleased
    case finalized
    case failed(String)
    case recovered
    case reset
}

public enum CaptureError: Error, Equatable, CustomStringConvertible {
    case invalidTransition(state: CaptureState, event: CaptureEvent)
    case noActiveSession
    case sourceStopUnconfirmed
    case emptyLiveNote
    case preflightFailed(AudioCapturePreflightReport)

    public var description: String {
        switch self {
        case let .invalidTransition(state, event):
            return "Capture cannot apply \(event) while \(state.rawValue)"
        case .noActiveSession:
            return "There is no active capture session"
        case .sourceStopUnconfirmed:
            return "The previous audio source has not been confirmed stopped; restart recovery before another capture"
        case .emptyLiveNote:
            return "Live notes cannot be empty"
        case let .preflightFailed(report):
            return report.summary
        }
    }
}

public struct CaptureStateMachine: Equatable {
    public private(set) var state: CaptureState
    public private(set) var failureMessage: String?

    public init(state: CaptureState = .idle, failureMessage: String? = nil) {
        self.state = state
        self.failureMessage = failureMessage
    }

    public mutating func apply(_ event: CaptureEvent) throws {
        let next: CaptureState
        switch (state, event) {
        case (.idle, .detectionStarted): next = .detecting
        case (.detecting, .detectionEnded): next = .idle
        case (.idle, .startRequested), (.detecting, .startRequested), (.failed, .startRequested), (.recovered, .startRequested): next = .starting
        case (.starting, .captureStarted): next = .recording
        case (.recording, .stopRequested): next = .stopping
        case (.stopping, .captureStopped): next = .finalizing
        case (.stopping, .captureReleased): next = .idle
        case (.finalizing, .finalized): next = .idle
        case (.failed, .recovered): next = .recovered
        case (.recovered, .reset): next = .idle
        case (_, .failed): next = .failed
        default: throw CaptureError.invalidTransition(state: state, event: event)
        }

        state = next
        switch event {
        case let .failed(message): failureMessage = message
        case .recovered, .reset, .startRequested: failureMessage = nil
        default: break
        }
    }
}

public struct MeetingCaptureSession: Equatable {
    public let id: String
    public let title: String
    public let meetingRelativePath: String
    public let source: CaptureAudioSource
    public let startedAt: Date
    public var endedAt: Date?

    public init(id: String, title: String, meetingRelativePath: String, source: CaptureAudioSource = .teams,
                startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.meetingRelativePath = meetingRelativePath
        self.source = source
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

private struct CaptureFinalizationRequest {
    let session: MeetingCaptureSession
    let endedAt: Date
    let releasedMic: MicTrackRecordingMetadata?
    let releasedSystem: SystemAudioTrackRecordingMetadata?
    let preflightReport: AudioCapturePreflightReport?
    let transcriptionLanguage: TranscriptLanguage
}

public enum PriorCaptureFinalizationState: Equatable {
    case finalizing
    case failed(String)
}

public struct PriorCaptureFinalization: Equatable {
    public let sessionID: String
    public let meetingTitle: String
    public let meetingRelativePath: String
    public let state: PriorCaptureFinalizationState

    public init(sessionID: String, meetingTitle: String, meetingRelativePath: String, state: PriorCaptureFinalizationState) {
        self.sessionID = sessionID
        self.meetingTitle = meetingTitle
        self.meetingRelativePath = meetingRelativePath
        self.state = state
    }
}

public struct CaptureSnapshot: Equatable {
    public let state: CaptureState
    public let meetingTitle: String?
    public let meetingRelativePath: String?
    public let source: CaptureAudioSource?
    public let elapsedSeconds: Int
    public let failureMessage: String?
    public let processingStatus: [String]
    public let preflightReport: AudioCapturePreflightReport?
    public let micRecording: MicTrackRecordingMetadata?
    public let systemAudioRecording: SystemAudioTrackRecordingMetadata?
    public let recordingBundle: RecordingBundle?
    public let transcriptionAudio: TranscriptionAudioSidecar?
    public let priorCaptureFinalizations: [PriorCaptureFinalization]

    public init(
        state: CaptureState,
        meetingTitle: String?,
        meetingRelativePath: String?,
        source: CaptureAudioSource? = nil,
        elapsedSeconds: Int,
        failureMessage: String?,
        processingStatus: [String],
        preflightReport: AudioCapturePreflightReport?,
        micRecording: MicTrackRecordingMetadata?,
        systemAudioRecording: SystemAudioTrackRecordingMetadata?,
        recordingBundle: RecordingBundle?,
        transcriptionAudio: TranscriptionAudioSidecar?,
        priorCaptureFinalizations: [PriorCaptureFinalization] = []
    ) {
        self.state = state
        self.meetingTitle = meetingTitle
        self.meetingRelativePath = meetingRelativePath
        self.source = source
        self.elapsedSeconds = elapsedSeconds
        self.failureMessage = failureMessage
        self.processingStatus = processingStatus
        self.preflightReport = preflightReport
        self.micRecording = micRecording
        self.systemAudioRecording = systemAudioRecording
        self.recordingBundle = recordingBundle
        self.transcriptionAudio = transcriptionAudio
        self.priorCaptureFinalizations = priorCaptureFinalizations
    }
}

/// Application service for the capture lifecycle. The microphone recorder is injected so the
/// state/artifact policy remains deterministic while the app target owns AVFoundation.
public final class MeetingCaptureService {
    private let vault: WorkspaceVault
    private let jobStore: JobStore?
    private let inbox: TasksInbox?
    private let micRecorder: MicTrackRecordingManaging?
    private let systemAudioRecorder: SystemAudioTrackRecordingManaging?
    private let bundleFinalizer: RecordingBundleFinalizing?
    private let transcriptionSidecarGenerator: TranscriptionSidecarGenerating?
    private let preflight: () -> AudioCapturePreflightReport
    private let now: () -> Date
    private let timeZone: TimeZone
    private let makeID: () -> String
    private var machine = CaptureStateMachine()
    private var sourceStopUnconfirmed = false
    private var session: MeetingCaptureSession?
    private var mostRecentSession: MeetingCaptureSession?
    private var observers: [(CaptureSnapshot) -> Void] = []
    private var priorCaptureFinalizations: [PriorCaptureFinalization] = []
    private var processingStatus: [String] = []
    private var preflightReport: AudioCapturePreflightReport?
    private var micRecording: MicTrackRecordingMetadata?
    private var systemAudioRecording: SystemAudioTrackRecordingMetadata?
    private var recordingBundle: RecordingBundle?
    private var transcriptionAudio: TranscriptionAudioSidecar?
    public private(set) var transcriptionLanguage: TranscriptLanguage

    public init(
        vault: WorkspaceVault,
        jobStore: JobStore? = nil,
        inbox: TasksInbox? = nil,
        micRecorder: MicTrackRecordingManaging? = nil,
        systemAudioRecorder: SystemAudioTrackRecordingManaging? = nil,
        bundleFinalizer: RecordingBundleFinalizing? = nil,
        transcriptionSidecarGenerator: TranscriptionSidecarGenerating? = nil,
        preflight: @escaping () -> AudioCapturePreflightReport,
        transcriptionLanguage: TranscriptLanguage = .english,
        now: @escaping () -> Date = Date.init,
        timeZone: TimeZone = .current,
        makeID: @escaping () -> String = { UUID().uuidString }
    ) {
        self.vault = vault
        self.jobStore = jobStore
        self.inbox = inbox
        self.micRecorder = micRecorder
        self.systemAudioRecorder = systemAudioRecorder
        self.bundleFinalizer = bundleFinalizer
        self.transcriptionSidecarGenerator = transcriptionSidecarGenerator
        self.preflight = preflight
        self.transcriptionLanguage = transcriptionLanguage
        self.now = now
        self.timeZone = timeZone
        self.makeID = makeID
    }

    public var canStartCapture: Bool {
        !sourceStopUnconfirmed && micRecorder?.activeMetadata == nil && systemAudioRecorder?.activeMetadata == nil
    }

    public var snapshot: CaptureSnapshot {
        let visibleSession = session ?? mostRecentSession
        let elapsed = visibleSession.map { max(0, Int(($0.endedAt ?? now()).timeIntervalSince($0.startedAt))) } ?? 0
        return CaptureSnapshot(
            state: machine.state,
            meetingTitle: visibleSession?.title,
            meetingRelativePath: visibleSession?.meetingRelativePath,
            source: visibleSession?.source,
            elapsedSeconds: elapsed,
            failureMessage: machine.failureMessage,
            processingStatus: processingStatus,
            preflightReport: preflightReport,
            micRecording: micRecording,
            systemAudioRecording: systemAudioRecording,
            recordingBundle: recordingBundle,
            transcriptionAudio: transcriptionAudio,
            priorCaptureFinalizations: priorCaptureFinalizations
        )
    }

    public func observe(_ observer: @escaping (CaptureSnapshot) -> Void) {
        observers.append(observer)
        observer(snapshot)
    }

    @discardableResult
    public func startManual(titleHint: String? = nil, source: CaptureAudioSource = .teams) throws -> MeetingCaptureSession {
        guard !sourceStopUnconfirmed, micRecorder?.activeMetadata == nil,
              systemAudioRecorder?.activeMetadata == nil else { throw CaptureError.sourceStopUnconfirmed }
        try transition(.startRequested)
        let report = preflight()
        preflightReport = report
        guard report.canStart else {
            let error = CaptureError.preflightFailed(report)
            try transition(.failed(error.description))
            throw error
        }
        notifyObservers()
        let startedAt = now()
        micRecording = nil
        systemAudioRecording = nil
        recordingBundle = nil
        transcriptionAudio = nil
        let title = normalizedTitle(titleHint, at: startedAt)
        do {
            let relativePath = try availableMeetingPath(title: title, at: startedAt)
            let newSession = MeetingCaptureSession(
                id: makeID(),
                title: title,
                meetingRelativePath: relativePath,
                source: source,
                startedAt: startedAt
            )
            let directory = (relativePath as NSString).deletingLastPathComponent
            try vault.createDirectory(relativePath: directory)
            _ = try vault.writeMarkdown(
                Data(doorwayMarkdown(for: newSession).utf8),
                relativePath: relativePath,
                expectedVersion: nil
            )
            session = newSession
            mostRecentSession = newSession
            if let micRecorder = micRecorder {
                micRecording = try micRecorder.start(
                    sessionID: newSession.id,
                    meetingRelativePath: newSession.meetingRelativePath,
                    startedAt: startedAt
                )
                processingStatus = ["Microphone recovery/preview recording active"]
            } else {
                processingStatus = ["Placeholder capture active"]
            }
            let systemItem = report.items.first(where: { $0.id == "system-audio" })
            let canStartSystemAudio = systemItem == nil || systemItem?.status == .ready
            if let systemAudioRecorder = systemAudioRecorder, canStartSystemAudio {
                do {
                    systemAudioRecording = try systemAudioRecorder.start(
                        sessionID: newSession.id,
                        meetingRelativePath: newSession.meetingRelativePath,
                        startedAt: startedAt,
                        source: source
                    )
                    processingStatus.append("\(source.scope == .teamsApplication ? "Teams application" : "All system") audio recovery/preview recording active")
                } catch {
                    systemAudioRecording = systemAudioRecorder.latestMetadata
                    processingStatus.append("System audio unavailable; capture is continuing microphone-only: \(error)")
                }
            } else if let systemItem = systemItem, systemItem.status != .ready {
                processingStatus.append("System audio unavailable; capture is continuing microphone-only: \(systemItem.detail)")
            }
            try transition(.captureStarted)
            return newSession
        } catch {
            try? transition(.failed(String(describing: error)))
            throw error
        }
    }

    public func appendLiveNote(_ text: String) throws {
        try append(text, prefix: "- ")
    }

    public func appendActionItem(_ text: String) throws {
        try append(text, prefix: "- [ ] ")
    }

    /// Finalizes a stopped session synchronously for callers that do not own a UI thread.
    @discardableResult
    public func stopManual() throws -> JobRecord? {
        let request: CaptureFinalizationRequest
        do { request = try prepareStop() }
        catch {
            recordCaptureReleaseFailure(error)
            throw error
        }
        do {
            let finalized = try runFinalization(request)
            return try completeStop(request, finalized: finalized)
        } catch {
            recordFinalizationFailure(request, error: error)
            throw error
        }
    }

    /// Releases capture inputs immediately, then finishes encoding and handoff away from the UI.
    /// The completion belongs to the stopped session and cannot publish that session as current.
    public func stopManualAsync(completion: @escaping (Result<JobRecord?, Error>) -> Void) {
        let request: CaptureFinalizationRequest
        do { request = try prepareStop() }
        catch {
            recordCaptureReleaseFailure(error)
            completion(.failure(error))
            return
        }
        let micRecorder = self.micRecorder
        let systemAudioRecorder = self.systemAudioRecorder
        let bundleFinalizer = self.bundleFinalizer
        let generator = transcriptionSidecarGenerator
        Task.detached(priority: .userInitiated) { [self] in
            let result = Result {
                try CaptureFinalization.run(
                    releasedMic: request.releasedMic,
                    releasedSystem: request.releasedSystem,
                    micRecorder: micRecorder,
                    systemAudioRecorder: systemAudioRecorder,
                    bundleFinalizer: bundleFinalizer,
                    generator: generator
                )
            }
            await MainActor.run {
                do {
                    completion(.success(try self.completeStop(request, finalized: result.get())))
                } catch {
                    self.recordFinalizationFailure(request, error: error)
                    completion(.failure(error))
                }
            }
        }
    }

    private func runFinalization(_ request: CaptureFinalizationRequest) throws -> CaptureFinalization {
        try CaptureFinalization.run(
            releasedMic: request.releasedMic,
            releasedSystem: request.releasedSystem,
            micRecorder: micRecorder,
            systemAudioRecorder: systemAudioRecorder,
            bundleFinalizer: bundleFinalizer,
            generator: transcriptionSidecarGenerator
        )
    }

    private func prepareStop() throws -> CaptureFinalizationRequest {
        guard var activeSession = session else { throw CaptureError.noActiveSession }
        try transition(.stopRequested)
        let endedAt = now()
        activeSession.endedAt = endedAt

        let releasedMic = try micRecorder?.releaseForFinalization(endedAt: endedAt)
        var releasedSystem = systemAudioRecording
        if systemAudioRecorder?.activeMetadata != nil {
            do {
                releasedSystem = try systemAudioRecorder?.releaseForFinalization(endedAt: endedAt)
            } catch {
                // A failed stop can leave the OS stream live. Never offer B until recovery.
                throw error
            }
        }

        try? markCaptureFinalizing(relativePath: activeSession.meetingRelativePath)
        let request = CaptureFinalizationRequest(
            session: activeSession,
            endedAt: endedAt,
            releasedMic: releasedMic,
            releasedSystem: releasedSystem,
            preflightReport: preflightReport,
            transcriptionLanguage: transcriptionLanguage
        )
        session = nil
        mostRecentSession = activeSession
        priorCaptureFinalizations.removeAll { $0.sessionID == activeSession.id }
        priorCaptureFinalizations.append(PriorCaptureFinalization(
            sessionID: activeSession.id,
            meetingTitle: activeSession.title,
            meetingRelativePath: activeSession.meetingRelativePath,
            state: .finalizing
        ))
        micRecording = releasedMic
        systemAudioRecording = releasedSystem
        recordingBundle = nil
        transcriptionAudio = nil
        processingStatus = ["Capture source stopped; previous-session audio finalization is continuing"]
        try transition(.captureReleased)
        return request
    }

    private func completeStop(_ request: CaptureFinalizationRequest, finalized: CaptureFinalization) throws -> JobRecord? {
        try replaceProcessingSection(
            relativePath: request.session.meetingRelativePath,
            mic: finalized.mic,
            system: finalized.system,
            bundle: finalized.bundle,
            selection: finalized.selection,
            preflight: request.preflightReport
        )
        let job = try enqueueProcessingJob(
            for: request.session,
            bundle: finalized.bundle,
            selection: finalized.selection,
            language: request.transcriptionLanguage
        )
        if request.session.title.hasPrefix("Untitled Meeting at ") {
            try inbox?.requireTitleReview(
                id: MeetingTitleReviewService.reviewID(sessionID: request.session.id),
                title: suggestedReviewTitle(for: request.session),
                sourceRef: request.session.meetingRelativePath
            )
        }
        if let mic = finalized.mic { _ = try micRecorder?.completeHandoff(mic) }
        if let system = finalized.system { _ = try systemAudioRecorder?.completeHandoff(system) }
        priorCaptureFinalizations.removeAll { $0.sessionID == request.session.id }
        if mostRecentSession?.id == request.session.id {
            micRecording = finalized.mic
            systemAudioRecording = finalized.system
            recordingBundle = finalized.bundle
            transcriptionAudio = finalized.selection
            processingStatus = finalized.statuses
            notifyObservers()
        }
        return job
    }

    private func recordFinalizationFailure(_ request: CaptureFinalizationRequest, error: Error) {
        let message = "Capture source stopped; audio evidence retained, but finalization or processing handoff failed: \(error)"
        try? updateFinalizationFailure(relativePath: request.session.meetingRelativePath, message: message)
        priorCaptureFinalizations = priorCaptureFinalizations.map { finalization in
            guard finalization.sessionID == request.session.id else { return finalization }
            return PriorCaptureFinalization(
                sessionID: finalization.sessionID,
                meetingTitle: finalization.meetingTitle,
                meetingRelativePath: finalization.meetingRelativePath,
                state: .failed(message)
            )
        }
        if mostRecentSession?.id == request.session.id { processingStatus = [message] }
        notifyObservers()
    }

    private func recordCaptureReleaseFailure(_ error: Error) {
        guard var failedSession = session else { return }
        sourceStopUnconfirmed = true
        failedSession.endedAt = failedSession.endedAt ?? now()
        let message = "Capture input could not be confirmed stopped; recovery evidence is retained: \(error)"
        try? updateFinalizationFailure(relativePath: failedSession.meetingRelativePath, message: message)
        mostRecentSession = failedSession
        priorCaptureFinalizations.removeAll { $0.sessionID == failedSession.id }
        priorCaptureFinalizations.append(PriorCaptureFinalization(
            sessionID: failedSession.id,
            meetingTitle: failedSession.title,
            meetingRelativePath: failedSession.meetingRelativePath,
            state: .failed(message)
        ))
        if var mic = micRecording, mic.captureSessionID == failedSession.id {
            mic.status = .failed
            mic.diagnostics.append(message)
            micRecording = mic
        }
        if let system = systemAudioRecorder?.latestMetadata, system.captureSessionID == failedSession.id {
            systemAudioRecording = system
        }
        processingStatus = [message]
        session = nil
        try? machine.apply(.failed(message))
        notifyObservers()
    }

    /// Selects the only two first-class languages. The next capture uses this language.
    public func setTranscriptionLanguage(_ language: TranscriptLanguage) {
        transcriptionLanguage = language
        notifyObservers()
    }

    /// Queues a fresh transcript generation from immutable recording inputs. Existing transcript
    /// artifacts are replaced only after the new engine output has been validated and rendered.
    @discardableResult
    public func regenerateTranscript(language: TranscriptLanguage) throws -> JobRecord {
        guard let jobStore = jobStore, let bundle = recordingBundle else {
            throw TranscriptionError.unsupportedJob("no finalized Recording Bundle is available")
        }
        transcriptionLanguage = language
        let job = try jobStore.enqueue(manifest: try MeetingWorkflowJob.manifest(transcription: TranscriptionJob.manifest(
            title: session?.title ?? "meeting",
            bundle: bundle,
            selection: transcriptionAudio,
            language: language
        )).owned(by: vault.rootURL))
        processingStatus.append("Transcript regeneration queued in \(language.displayName)")
        notifyObservers()
        return job
    }

    public func titleReviewAccepted(meetingRelativePath: String, title: String, newPath: String) {
        guard let current = session, current.meetingRelativePath == meetingRelativePath else { return }
        session = MeetingCaptureSession(
            id: current.id, title: title, meetingRelativePath: newPath, source: current.source,
            startedAt: current.startedAt, endedAt: current.endedAt
        )
        notifyObservers()
    }

    private func transition(_ event: CaptureEvent) throws {
        try machine.apply(event)
        notifyObservers()
    }

    private func notifyObservers() {
        let current = snapshot
        observers.forEach { $0(current) }
    }

    private func append(_ text: String, prefix: String) throws {
        guard machine.state == .recording, let session = session else {
            throw CaptureError.noActiveSession
        }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw CaptureError.emptyLiveNote }
        let line = prefix + normalized.replacingOccurrences(of: "\n", with: " ")
        let current = try vault.readMarkdown(relativePath: session.meetingRelativePath)
        guard var markdown = String(data: current.data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        if !markdown.hasSuffix("\n") { markdown += "\n" }
        markdown += line + "\n"
        _ = try vault.writeMarkdown(
            Data(markdown.utf8),
            relativePath: session.meetingRelativePath,
            expectedVersion: current.version
        )
        notifyObservers()
    }

    private func markCaptureFinalizing(relativePath: String) throws {
        let current = try vault.readMarkdown(relativePath: relativePath)
        guard let markdown = String(data: current.data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let updated = markdown.replacingOccurrences(of: "capture: placeholder", with: "capture: finalizing")
        _ = try vault.writeMarkdown(Data(updated.utf8), relativePath: relativePath, expectedVersion: current.version)
    }

    private func updateFinalizationFailure(relativePath: String, message: String) throws {
        let current = try vault.readMarkdown(relativePath: relativePath)
        guard var markdown = String(data: current.data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let marker = "## Processing\n"
        if let range = markdown.range(of: marker) {
            markdown.insert(contentsOf: "\n- [!] \(message)\n", at: range.upperBound)
        }
        _ = try vault.writeMarkdown(Data(markdown.utf8), relativePath: relativePath, expectedVersion: current.version)
    }

    private func replaceProcessingSection(
        relativePath: String,
        mic: MicTrackRecordingMetadata?,
        system: SystemAudioTrackRecordingMetadata?,
        bundle: RecordingBundle?,
        selection: TranscriptionAudioSidecar?,
        preflight: AudioCapturePreflightReport?
    ) throws {
        let current = try vault.readMarkdown(relativePath: relativePath)
        guard let markdown = String(data: current.data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        let marker = "## Processing\n"
        guard let markerRange = markdown.range(of: marker),
              let liveNotesRange = markdown.range(of: "\n## Live notes", range: markerRange.upperBound..<markdown.endIndex) else {
            return
        }
        var audioLines: [String] = []
        if let mic = mic {
            audioLines += [
                "- [x] Microphone track finalized: `\(mic.finalFilePath)`",
                "- [x] Microphone recovery/preview retained: `\(mic.recoveryFilePath)`",
                "- [x] Microphone recording metadata: `\(mic.metadataFilePath)`"
            ]
        } else {
            audioLines += [
                "- [x] Placeholder capture finalized",
                "- [ ] Audio finalization (available in a later capture ticket)"
            ]
        }
        if let bundle = bundle {
            audioLines += [
                "- [x] Recording bundle (`\(bundle.state.rawValue)`): `\(bundle.bundleFilePath)`",
                "- [x] Recording bundle validated for downstream processing"
            ]
        }
        if let selection = selection {
            if selection.selection == .echoCancelledSidecar {
                audioLines += [
                    "- [x] Echo-cancelled transcription sidecar: `\(selection.selectedAudioFilePath)`",
                    "- [x] Transcription audio diagnostics: `\(selection.metadataFilePath)`"
                ]
            } else {
                audioLines += [
                    "- [!] Echo cancellation not selected; transcription will use original microphone audio",
                    "- [x] Transcription audio diagnostics: `\(selection.metadataFilePath)`"
                ]
            }
        }
        if let system = system {
            if system.status == .completed || system.status == .recovered {
                audioLines += [
                    "- [x] System audio track finalized: `\(system.finalFilePath)`",
                    "- [x] System-audio recovery/preview retained: `\(system.recoveryFilePath)`",
                    "- [x] System audio recording metadata: `\(system.metadataFilePath)`"
                ]
            } else {
                audioLines += [
                    "- [!] System audio unavailable; microphone-only capture retained",
                    "- [x] System audio diagnostic metadata: `\(system.metadataFilePath)`"
                ]
            }
        } else if let systemItem = preflight?.items.first(where: { $0.id == "system-audio" }), systemItem.status != .ready {
            audioLines.append("- [!] System audio unavailable; microphone-only capture retained: \(systemItem.detail)")
        }
        let replacement = """
        ## Processing

        \(audioLines.joined(separator: "\n"))
        - [ ] Transcription and summary
        """
        var updated = markdown.replacingCharacters(in: markerRange.lowerBound..<liveNotesRange.lowerBound, with: replacement)
        if let bundle = bundle {
            updated = updated.replacingOccurrences(
                of: "capture: finalizing",
                with: "capture: \(bundle.state == .ready ? "finalized" : bundle.state.rawValue)\nrecording_bundle: \(bundle.bundleFilePath)"
            )
        } else {
            updated = updated.replacingOccurrences(of: "capture: finalizing", with: "capture: finalized")
        }
        _ = try vault.writeMarkdown(Data(updated.utf8), relativePath: relativePath, expectedVersion: current.version)
    }

    private func enqueueProcessingJob(
        for session: MeetingCaptureSession,
        bundle: RecordingBundle?,
        selection: TranscriptionAudioSidecar?,
        language: TranscriptLanguage
    ) throws -> JobRecord? {
        guard let jobStore = jobStore else { return nil }
        let jobID = MeetingWorkflowJob.captureProcessingJobID(sessionID: session.id)
        if let existing = try jobStore.job(id: jobID) { return existing }
        if let bundle = bundle {
            let manifest = try MeetingWorkflowJob.manifest(transcription: TranscriptionJob.manifest(
                title: session.title,
                bundle: bundle,
                selection: selection,
                language: language
            ))
            return try enqueueOnce(id: jobID, manifest: manifest.owned(by: vault.rootURL))
        }
        let manifest = JobManifest(
            type: "meeting-capture-placeholder",
            title: "Process \(session.title)",
            executionClass: .heavy,
            stages: [
                JobStageDefinition(id: "finalize-placeholder", title: "Finalize placeholder capture"),
                JobStageDefinition(id: "prepare-processing", title: "Prepare audio/transcription processing")
            ],
            sourceArtifacts: [
                JobArtifactReference(relativePath: session.meetingRelativePath, role: "meeting-doorway")
            ],
            metadata: ["capture_session_id": session.id],
            maxAutomaticRetries: 1
        )
        return try enqueueOnce(id: jobID, manifest: manifest.owned(by: vault.rootURL))
    }

    private func enqueueOnce(id: String, manifest: JobManifest) throws -> JobRecord? {
        guard let jobStore = jobStore else { return nil }
        do {
            return try jobStore.enqueue(id: id, manifest: manifest)
        } catch {
            if let existing = try jobStore.job(id: id) { return existing }
            throw error
        }
    }

    private func availableMeetingPath(title: String, at date: Date) throws -> String {
        let datePath = formatter("yyyy/MM/dd").string(from: date)
        let time = formatter("HH-mm").string(from: date)
        let base = "Meetings/\(datePath)/\(time)-\(slug(title))"
        var candidate = "\(base)/meeting.md"
        var suffix = 2
        while try vault.versionOfMarkdown(relativePath: candidate) != nil {
            candidate = "\(base)-\(suffix)/meeting.md"
            suffix += 1
        }
        return candidate
    }

    private func suggestedReviewTitle(for session: MeetingCaptureSession) -> String {
        let start = formatter("HH:mm").string(from: session.startedAt)
        let end = formatter("HH:mm").string(from: session.endedAt ?? now())
        return "Untitled meeting \(start)-\(end)"
    }

    private func normalizedTitle(_ hint: String?, at date: Date) -> String {
        let trimmed = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        return "Untitled Meeting at \(formatter("yyyy-MM-dd HH:mm").string(from: date))"
    }

    private func slug(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let words = title.lowercased().components(separatedBy: allowed.inverted).filter { !$0.isEmpty }
        if title.hasPrefix("Untitled Meeting at ") { return "untitled-meeting" }
        return words.prefix(8).joined(separator: "-").isEmpty ? "untitled-meeting" : words.prefix(8).joined(separator: "-")
    }

    private func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private func doorwayMarkdown(for session: MeetingCaptureSession) -> String {
        let timestamp = ISO8601DateFormatter().string(from: session.startedAt)
        return """
        ---
        schema_version: 1
        type: meeting
        title: \(session.title)
        started_at: \(timestamp)
        capture_session_id: \(session.id)
        meeting_source: \(session.source.rawValue)
        audio_scope: \(session.source.scope.rawValue)
        capture: placeholder
        ---
        # \(session.title)

        ## Processing

        - [ ] Placeholder capture active

        ## Live notes

        """
    }
}
