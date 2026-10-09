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
    case finalized
    case failed(String)
    case recovered
    case reset
}

public enum CaptureError: Error, Equatable, CustomStringConvertible {
    case invalidTransition(state: CaptureState, event: CaptureEvent)
    case noActiveSession
    case emptyLiveNote
    case preflightFailed(AudioCapturePreflightReport)

    public var description: String {
        switch self {
        case let .invalidTransition(state, event):
            return "Capture cannot apply \(event) while \(state.rawValue)"
        case .noActiveSession:
            return "There is no active capture session"
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
    public let startedAt: Date
    public var endedAt: Date?

    public init(id: String, title: String, meetingRelativePath: String, startedAt: Date, endedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.meetingRelativePath = meetingRelativePath
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct CaptureSnapshot: Equatable {
    public let state: CaptureState
    public let meetingTitle: String?
    public let meetingRelativePath: String?
    public let elapsedSeconds: Int
    public let failureMessage: String?
    public let processingStatus: [String]
    public let preflightReport: AudioCapturePreflightReport?
    public let micRecording: MicTrackRecordingMetadata?
    public let systemAudioRecording: SystemAudioTrackRecordingMetadata?
    public let recordingBundle: RecordingBundle?
    public let transcriptionAudio: TranscriptionAudioSidecar?
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
    private var session: MeetingCaptureSession?
    private var observers: [(CaptureSnapshot) -> Void] = []
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

    public var snapshot: CaptureSnapshot {
        let elapsed: Int
        if let session = session {
            elapsed = max(0, Int((session.endedAt ?? now()).timeIntervalSince(session.startedAt)))
        } else {
            elapsed = 0
        }
        return CaptureSnapshot(
            state: machine.state,
            meetingTitle: session?.title,
            meetingRelativePath: session?.meetingRelativePath,
            elapsedSeconds: elapsed,
            failureMessage: machine.failureMessage,
            processingStatus: processingStatus,
            preflightReport: preflightReport,
            micRecording: micRecording,
            systemAudioRecording: systemAudioRecording,
            recordingBundle: recordingBundle,
            transcriptionAudio: transcriptionAudio
        )
    }

    public func observe(_ observer: @escaping (CaptureSnapshot) -> Void) {
        observers.append(observer)
        observer(snapshot)
    }

    @discardableResult
    public func startManual(titleHint: String? = nil) throws -> MeetingCaptureSession {
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
                        startedAt: startedAt
                    )
                    processingStatus.append("Separate system-audio recovery/preview recording active")
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

    /// Finalizes the active capture synchronously for callers that do not own a UI thread.
    @discardableResult
    public func stopManual() throws -> JobRecord? {
        let (stoppedSession, endedAt) = try prepareStop()
        do {
            let finalized = try CaptureFinalization.run(
                endedAt: endedAt,
                micRecorder: micRecorder,
                systemAudioRecorder: systemAudioRecorder,
                priorSystem: systemAudioRecording,
                bundleFinalizer: bundleFinalizer,
                generator: transcriptionSidecarGenerator
            )
            return try completeStop(stoppedSession, finalized: finalized)
        } catch {
            try? transition(.failed(String(describing: error)))
            throw error
        }
    }

    /// Finalizes blocking recorder work off the UI thread and delivers state and completion on main.
    public func stopManualAsync(completion: @escaping (Result<JobRecord?, Error>) -> Void) {
        let stoppedSession: MeetingCaptureSession
        let endedAt: Date
        do { (stoppedSession, endedAt) = try prepareStop() }
        catch {
            completion(.failure(error))
            return
        }
        let micRecorder = self.micRecorder
        let systemAudioRecorder = self.systemAudioRecorder
        let bundleFinalizer = self.bundleFinalizer
        let generator = transcriptionSidecarGenerator
        let priorSystem = systemAudioRecording
        Task.detached(priority: .userInitiated) { [self] in
            let result = Result {
                try CaptureFinalization.run(
                    endedAt: endedAt,
                    micRecorder: micRecorder,
                    systemAudioRecorder: systemAudioRecorder,
                    priorSystem: priorSystem,
                    bundleFinalizer: bundleFinalizer,
                    generator: generator
                )
            }
            await MainActor.run {
                do {
                    completion(.success(try self.completeStop(stoppedSession, finalized: result.get())))
                } catch {
                    try? self.transition(.failed(String(describing: error)))
                    completion(.failure(error))
                }
            }
        }
    }

    private func prepareStop() throws -> (MeetingCaptureSession, Date) {
        guard var activeSession = session else { throw CaptureError.noActiveSession }
        try transition(.stopRequested)
        let endedAt = now()
        activeSession.endedAt = endedAt
        session = activeSession
        return (activeSession, endedAt)
    }

    private func completeStop(_ stoppedSession: MeetingCaptureSession, finalized: CaptureFinalization) throws -> JobRecord? {
        micRecording = finalized.mic
        systemAudioRecording = finalized.system
        recordingBundle = finalized.bundle
        transcriptionAudio = finalized.selection
        processingStatus = finalized.statuses
        try replaceProcessingSection(relativePath: stoppedSession.meetingRelativePath)
        let job = try enqueueProcessingJob(for: stoppedSession)
        try transition(.captureStopped)
        try transition(.finalized)
        if stoppedSession.title.hasPrefix("Untitled Meeting at ") {
            try inbox?.requireTitleReview(
                id: MeetingTitleReviewService.reviewID(sessionID: stoppedSession.id),
                title: suggestedReviewTitle(for: stoppedSession),
                sourceRef: stoppedSession.meetingRelativePath
            )
        }
        return job
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
        let job = try jobStore.enqueue(manifest: TranscriptionJob.manifest(
            title: session?.title ?? "meeting",
            bundle: bundle,
            selection: transcriptionAudio,
            language: language
        ))
        processingStatus.append("Transcript regeneration queued in \(language.displayName)")
        notifyObservers()
        return job
    }

    public func titleReviewAccepted(meetingRelativePath: String, title: String, newPath: String) {
        guard let current = session, current.meetingRelativePath == meetingRelativePath else { return }
        session = MeetingCaptureSession(
            id: current.id, title: title, meetingRelativePath: newPath,
            startedAt: current.startedAt, endedAt: current.endedAt
        )
        notifyObservers()
    }

    public func beginDetection() throws { try transition(.detectionStarted) }
    public func endDetection() throws { try transition(.detectionEnded) }
    public func markRecovered() throws { try transition(.recovered) }
    public func resetRecovered() throws { try transition(.reset) }

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

    private func replaceProcessingSection(relativePath: String) throws {
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
        if let mic = micRecording {
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
        if let bundle = recordingBundle {
            audioLines += [
                "- [x] Recording bundle (`\(bundle.state.rawValue)`): `\(bundle.bundleFilePath)`",
                "- [x] Recording bundle validated for downstream processing"
            ]
        }
        if let selection = transcriptionAudio {
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
        if let system = systemAudioRecording {
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
        } else if let systemItem = preflightReport?.items.first(where: { $0.id == "system-audio" }), systemItem.status != .ready {
            audioLines.append("- [!] System audio unavailable; microphone-only capture retained: \(systemItem.detail)")
        }
        let replacement = """
        ## Processing

        \(audioLines.joined(separator: "\n"))
        - [ ] Transcription and summary
        """
        var updated = markdown.replacingCharacters(in: markerRange.lowerBound..<liveNotesRange.lowerBound, with: replacement)
        if let bundle = recordingBundle {
            updated = updated.replacingOccurrences(
                of: "capture: placeholder",
                with: "capture: \(bundle.state == .ready ? "finalized" : bundle.state.rawValue)\nrecording_bundle: \(bundle.bundleFilePath)"
            )
        }
        _ = try vault.writeMarkdown(Data(updated.utf8), relativePath: relativePath, expectedVersion: current.version)
    }

    private func enqueueProcessingJob(for session: MeetingCaptureSession) throws -> JobRecord? {
        guard let jobStore = jobStore else { return nil }
        if let bundle = recordingBundle {
            let manifest = TranscriptionJob.manifest(
                title: session.title,
                bundle: bundle,
                selection: transcriptionAudio,
                language: transcriptionLanguage
            )
            return try jobStore.enqueue(manifest: manifest)
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
        return try jobStore.enqueue(manifest: manifest)
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
        capture: placeholder
        ---
        # \(session.title)

        ## Processing

        - [ ] Placeholder capture active

        ## Live notes

        """
    }
}
