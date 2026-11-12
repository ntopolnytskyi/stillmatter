import AppKit
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
    private let makeAnalysis: (URL) -> JobExecuting
    private let wakeNotificationCenter: NotificationCenter
    private let schedulerClock: () -> Date
    private(set) var transcriptionScheduler: JobScheduler?
    private(set) var configurationError: String?
    private var configurationKey: String?
    private var stopped = false
    private var wakeObserver: NSObjectProtocol?

    init(applicationSupportURL: URL, componentInstaller: TranscriptionComponentInstaller,
         jobStore: @escaping () -> JobStore?, mayResumeTranscription: @escaping (String) -> Bool,
         isProbe: @escaping () -> Bool = { false },
         makeTranscription: ((URL, SearchIndex?) -> JobExecuting)? = nil,
         makeAnalysis: ((URL) -> JobExecuting)? = nil,
         wakeNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         schedulerClock: @escaping () -> Date = Date.init,
         analysis: JobExecuting = UnavailableJobHandler(guidance:
            "ChatGPT analysis is not approved. Enable it in Settings, then Retry this stage. Recording and Transcript are retained; no Meeting text was sent.")) {
        self.applicationSupportURL = applicationSupportURL
        self.componentInstaller = componentInstaller
        self.jobStore = jobStore
        self.mayResumeTranscription = mayResumeTranscription
        self.isProbe = isProbe
        self.makeTranscription = makeTranscription
        self.makeAnalysis = makeAnalysis ?? { _ in analysis }
        self.wakeNotificationCenter = wakeNotificationCenter
        self.schedulerClock = schedulerClock
        wakeObserver = wakeNotificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.transcriptionScheduler?.wake()
        }
    }

    var schedulers: [JobScheduler] { [transcriptionScheduler].compactMap { $0 } }
    func scheduler(for type: String) -> JobScheduler? {
        MeetingWorkflowJob.supportedTypes.contains(type) ? transcriptionScheduler : nil
    }
    func pauseSynchronously() { transcriptionScheduler?.pauseSynchronously() }
    func start() { guard !stopped else { return }; transcriptionScheduler?.start() }
    func stop() {
        stopped = true
        if let wakeObserver { wakeNotificationCenter.removeObserver(wakeObserver); self.wakeObserver = nil }
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
        let key = [owner, component, String(indexGeneration), String(settings.allowChatGPTMeetingAnalysis)].joined(separator: "\n")
        guard configurationKey != key else { return }
        transcriptionScheduler?.pauseSynchronously()
        do {
            try MeetingWorkflowJob.migrate(store: store, workspaceRootURL: root)
            let transcription = makeTranscription?(root, searchIndex) ?? localTranscription(root: root, index: searchIndex)
            let analysis = makeAnalysis(root)
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
                }, clock: schedulerClock)
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
        let diarizationComponent = componentInstaller.installedModelURL() ?? componentInstaller.paths.modelURL
        let diarization = SherpaOnnxSpeakerDiarizationEngine(componentURL: diarizationComponent)
        return TranscriptionJobExecutor(pipeline: TranscriptionPipeline(workspaceRootURL: root,
            bundleValidator: RecordingBundleFinalizer(), engine: engine,
            diarizationEngine: diarization, searchIndex: index))
    }
}

enum ChatGPTMeetingAnalysisFactory {
    static func make(settings: AppSettings, workspaceRootURL: URL, applicationSupportURL: URL,
                     inbox: TasksInbox?, piExecutableURL: URL?,
                     currentTransferApproval: @escaping () -> Bool) -> JobExecuting {
        guard settings.allowChatGPTMeetingAnalysis else {
            return UnavailableJobHandler(guidance: "Enable ChatGPT Meeting analysis in Settings, then Retry. This sends the Meeting Transcript and My Notes to ChatGPT through your installed Pi sign-in. No text is sent until enabled.")
        }
        guard let piExecutableURL else {
            return UnavailableJobHandler(guidance: "Pi CLI is unavailable. Install Pi and sign in to ChatGPT, then Retry analysis. No Meeting text was sent.")
        }
        guard let inbox else {
            return UnavailableJobHandler(guidance: "The Meeting task inbox is unavailable. Check the workspace in Settings, then Retry. No Meeting text was sent.")
        }
        let worker = PiCodexWorker(executableURL: piExecutableURL, vaultRootURL: workspaceRootURL,
                                   hasTransferApproval: currentTransferApproval)
        return MeetingSummaryJobExecutor(worker: worker, workspaceRootURL: workspaceRootURL,
            vault: WorkspaceVault(workspaceRootURL: workspaceRootURL, appSupportRootURL: applicationSupportURL),
            inbox: inbox)
    }
}
