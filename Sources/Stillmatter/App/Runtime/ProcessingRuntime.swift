import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterTranscriptionRuntime
#endif

/// One workspace-bound scheduler holds each complete Meeting turn. Handler
/// instances capture their workspace; capture never acquires the processing gate.
final class ProcessingRuntime {
    let heavyExecutionGate = JobHeavyExecutionGate()
    private let applicationSupportURL: URL
    private let componentInstaller: TranscriptionComponentInstaller
    private let jobStore: () -> JobStore?
    private let mayResumeTranscription: (String) -> Bool
    private let isProbe: () -> Bool
    private let makeTranscription: ((URL, SearchIndex?) -> JobExecuting)?
    private let analysis: JobExecuting
    private(set) var transcriptionScheduler: JobScheduler?
    private(set) var configurationError: String?
    private var configurationKey: String?
    private var stopped = false

    init(applicationSupportURL: URL, componentInstaller: TranscriptionComponentInstaller,
         jobStore: @escaping () -> JobStore?, mayResumeTranscription: @escaping (String) -> Bool,
         isProbe: @escaping () -> Bool = { false },
         makeTranscription: ((URL, SearchIndex?) -> JobExecuting)? = nil,
         analysis: JobExecuting = UnavailableJobHandler(guidance:
            "A fully local analysis provider is required. Configure the local model, then Retry this stage. Recording and Transcript are retained; no Meeting text was uploaded.")) {
        self.applicationSupportURL = applicationSupportURL
        self.componentInstaller = componentInstaller
        self.jobStore = jobStore
        self.mayResumeTranscription = mayResumeTranscription
        self.isProbe = isProbe
        self.makeTranscription = makeTranscription
        self.analysis = analysis
    }

    var schedulers: [JobScheduler] { [transcriptionScheduler].compactMap { $0 } }
    func scheduler(for type: String) -> JobScheduler? {
        MeetingWorkflowJob.supportedTypes.contains(type) ? transcriptionScheduler : nil
    }
    func pauseSynchronously() { transcriptionScheduler?.pauseSynchronously() }
    func start() { guard !stopped else { return }; transcriptionScheduler?.start() }
    func stop() {
        stopped = true
        transcriptionScheduler?.stop()
        transcriptionScheduler = nil
        configurationKey = nil
    }

    func configure(settings: AppSettings, searchIndex: SearchIndex?, indexGeneration: Int) {
        configureTranscription(settings: settings, searchIndex: searchIndex, indexGeneration: indexGeneration)
    }

    func configureTranscription(settings: AppSettings, searchIndex: SearchIndex?, indexGeneration: Int) {
        guard !stopped else { return }
        guard !isProbe(), let root = settings.stillmatterRootURL, let store = jobStore() else {
            transcriptionScheduler?.pauseSynchronously()
            transcriptionScheduler = nil
            configurationKey = nil
            configurationError = nil
            return
        }
        let component = componentInstaller.installedModelURL()?.path ?? "missing-model"
        let owner = root.standardizedFileURL.resolvingSymlinksInPath().path
        let key = [owner, component, String(indexGeneration)].joined(separator: "\n")
        guard configurationKey != key else { return }
        transcriptionScheduler?.pauseSynchronously()
        do {
            try MeetingWorkflowJob.migrate(store: store, workspaceRootURL: root)
            let transcription = makeTranscription?(root, searchIndex) ?? localTranscription(root: root, index: searchIndex)
            let registry = JobHandlerRegistry(handlers: [
                MeetingWorkflowJob.type: MeetingWorkflowHandler(transcription: transcription, analysis: analysis),
                TranscriptionJob.type: transcription, MeetingSummaryJob.type: analysis
            ])
            let scheduler = JobScheduler(store: store, executor: registry, eligibleJobTypes: registry.jobTypes,
                workspaceRootURL: root, heavyExecutionGate: heavyExecutionGate,
                onWorkQueuedWhilePaused: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.stopped, self.mayResumeTranscription(owner) else { return }
                        self.transcriptionScheduler?.start()
                    }
                })
            transcriptionScheduler = scheduler
            configurationKey = key
            configurationError = nil
            scheduler.start()
        } catch {
            transcriptionScheduler = nil
            configurationKey = nil
            configurationError = "Meeting workflow migration needs attention: \(error)"
        }
    }

    private func localTranscription(root: URL, index: SearchIndex?) -> JobExecuting {
        let engine: TranscriptionEngine
        if let cli = TranscriptionComponentPaths.developerCLIConfiguration(
            environment: ProcessInfo.processInfo.environment, applicationSupportURL: applicationSupportURL) {
            engine = WhisperCLITranscriptionEngine(executableURL: cli.executableURL, modelURL: cli.modelURL)
        } else if let model = componentInstaller.installedModelURL(), let choice = componentInstaller.installedModelChoice(),
                  TranscriptionModelCompatibility.isSupported(choice, hardwareModel: FasterWhisperRuntimeSupport.deviceName()) {
            engine = FasterWhisperTranscriptionEngine(componentURL: model, modelIdentifier: choice.variant)
        } else {
            return UnavailableJobHandler(guidance: "Install the local transcription model in Settings, then Retry. The recording is retained.")
        }
        return TranscriptionJobExecutor(pipeline: TranscriptionPipeline(workspaceRootURL: root,
            bundleValidator: RecordingBundleFinalizer(), engine: engine, searchIndex: index))
    }
}
