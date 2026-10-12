import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterTranscriptionRuntime
#endif

/// Owns both workspace-bound processing schedulers and the process-wide heavy gate.
/// A worker captures its root. Changing Settings cannot retarget an in-flight stage.
final class ProcessingRuntime {
    let heavyExecutionGate = JobHeavyExecutionGate()
    private let applicationSupportURL: URL
    private let componentInstaller: TranscriptionComponentInstaller
    private let jobStore: () -> JobStore?
    private let inbox: () -> TasksInbox?
    private let isCurrent: (String) -> Bool
    private let mayResumeTranscription: (String) -> Bool
    private let onSummaryApplied: () -> Void
    private let isProbe: () -> Bool
    private(set) var transcriptionScheduler: JobScheduler?
    private(set) var meetingSummaryScheduler: JobScheduler?
    private var transcriptionKey: String?
    private var summaryKey: String?
    private var stopped = false

    init(applicationSupportURL: URL, componentInstaller: TranscriptionComponentInstaller,
         jobStore: @escaping () -> JobStore?, inbox: @escaping () -> TasksInbox?,
         isCurrent: @escaping (String) -> Bool,
         mayResumeTranscription: @escaping (String) -> Bool,
         onSummaryApplied: @escaping () -> Void, isProbe: @escaping () -> Bool = { false }) {
        self.applicationSupportURL = applicationSupportURL
        self.componentInstaller = componentInstaller
        self.jobStore = jobStore
        self.inbox = inbox
        self.isCurrent = isCurrent
        self.mayResumeTranscription = mayResumeTranscription
        self.onSummaryApplied = onSummaryApplied
        self.isProbe = isProbe
    }

    var schedulers: [JobScheduler] { [transcriptionScheduler, meetingSummaryScheduler].compactMap { $0 } }
    func scheduler(for type: String) -> JobScheduler? {
        switch type {
        case TranscriptionJob.type: return transcriptionScheduler
        case MeetingSummaryJob.type: return meetingSummaryScheduler
        default: return nil
        }
    }
    func pauseSynchronously() { schedulers.forEach { $0.pauseSynchronously() } }
    func start() { guard !stopped else { return }; schedulers.forEach { $0.start() } }
    func stop() {
        stopped = true
        schedulers.forEach { $0.stop() }
        transcriptionScheduler = nil
        meetingSummaryScheduler = nil
        transcriptionKey = nil
        summaryKey = nil
    }

    func configure(settings: AppSettings, searchIndex: SearchIndex?, indexGeneration: Int) {
        guard !stopped else { return }
        configureSummary(settings: settings)
        configureTranscription(settings: settings, searchIndex: searchIndex, indexGeneration: indexGeneration)
    }

    func configureTranscription(settings: AppSettings, searchIndex: SearchIndex?, indexGeneration: Int) {
        guard !stopped else { return }
        guard !isProbe(), let rootURL = settings.stillmatterRootURL, let store = jobStore() else {
            transcriptionScheduler?.pause(); transcriptionScheduler = nil; transcriptionKey = nil
            return
        }
        let engine: TranscriptionEngine
        let engineKey: String
        if let cli = TranscriptionComponentPaths.developerCLIConfiguration(
            environment: ProcessInfo.processInfo.environment, applicationSupportURL: applicationSupportURL) {
            engine = WhisperCLITranscriptionEngine(executableURL: cli.executableURL, modelURL: cli.modelURL)
            engineKey = "cli\n\(cli.executableURL.path)\n\(cli.modelURL.path)"
        } else if let modelURL = componentInstaller.installedModelURL(),
                  let choice = componentInstaller.installedModelChoice(),
                  TranscriptionModelCompatibility.isSupported(choice, hardwareModel: FasterWhisperRuntimeSupport.deviceName()) {
            engine = FasterWhisperTranscriptionEngine(componentURL: modelURL, modelIdentifier: choice.variant)
            engineKey = "faster-whisper\n\(modelURL.path)"
        } else {
            transcriptionScheduler?.pause(); transcriptionScheduler = nil; transcriptionKey = nil
            return
        }
        let key = [rootURL.standardizedFileURL.path, engineKey,
                   searchIndex == nil ? "<no-index>" : "index-generation:\(indexGeneration)"].joined(separator: "\n")
        guard key != transcriptionKey else { return }
        let pipeline = TranscriptionPipeline(workspaceRootURL: rootURL,
            bundleValidator: RecordingBundleFinalizer(), engine: engine, searchIndex: searchIndex)
        let scheduler = JobScheduler(store: store,
            executor: TranscriptionJobExecutor(pipeline: pipeline,
                onTranscriptGenerated: { [weak self] job, artifacts in
                    try self?.enqueueSummary(after: job, artifacts: artifacts)
                }),
            eligibleJobTypes: [TranscriptionJob.type], workspaceRootURL: rootURL,
            heavyExecutionGate: heavyExecutionGate,
            onWorkQueuedWhilePaused: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped,
                          self.mayResumeTranscription(rootURL.standardizedFileURL.resolvingSymlinksInPath().path) else { return }
                    self.transcriptionScheduler?.start()
                }
            })
        transcriptionScheduler?.pause()
        transcriptionScheduler = scheduler
        transcriptionKey = key
        scheduler.start()
    }

    private func configureSummary(settings: AppSettings) {
        guard !isProbe(), let rootURL = settings.stillmatterRootURL,
              let store = jobStore(), let inbox = inbox(),
              let executableURL = PiIntegration().detectedExecutableURL() else {
            meetingSummaryScheduler?.pause(); meetingSummaryScheduler = nil; summaryKey = nil
            return
        }
        let key = rootURL.standardizedFileURL.path + "\n" + executableURL.standardizedFileURL.path
        guard key != summaryKey else { return }
        let worker = PiCodexWorker(executableURL: executableURL, vaultRootURL: rootURL)
        let executor = MeetingSummaryJobExecutor(worker: worker, workspaceRootURL: rootURL,
            vault: WorkspaceVault(workspaceRootURL: rootURL, appSupportRootURL: applicationSupportURL),
            inbox: inbox, onApplied: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.stopped,
                          self.isCurrent(rootURL.standardizedFileURL.resolvingSymlinksInPath().path) else { return }
                    self.onSummaryApplied()
                }
            })
        let scheduler = JobScheduler(store: store, executor: executor,
            eligibleJobTypes: [MeetingSummaryJob.type], workspaceRootURL: rootURL,
            heavyExecutionGate: heavyExecutionGate)
        meetingSummaryScheduler?.pause()
        meetingSummaryScheduler = scheduler
        summaryKey = key
        scheduler.start()
    }

    private func enqueueSummary(after transcriptionJob: JobRecord, artifacts: TranscriptionArtifacts) throws {
        guard let store = jobStore() else { return }
        let id = "meeting-summary:\(transcriptionJob.id)"
        guard try store.job(id: id) == nil else { return }
        let manifest = try MeetingSummaryJob.manifest(transcript: artifacts.document,
            transcriptJSONRelativePath: artifacts.jsonRelativePath)
        guard let owner = transcriptionJob.manifest.workspaceOwner else {
            throw JobsError.invalidManifest("Transcription Job has unknown workspace ownership; summary generation is quarantined.")
        }
        _ = try store.enqueue(id: id, manifest: manifest.owned(by: URL(fileURLWithPath: owner, isDirectory: true)))
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopped, self.isCurrent(owner) else { return }
            self.meetingSummaryScheduler?.start()
        }
    }
}
