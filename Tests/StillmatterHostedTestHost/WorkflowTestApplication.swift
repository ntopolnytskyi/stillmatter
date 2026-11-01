// Test-only native surface: real ProcessingRuntime, MeetingManagementView and
// CaptureRecordingView, isolated stores, controlled stage completions, no devices/models.
import AppKit
import StillmatterCore
import StillmatterPresentation

final class WorkflowTestApplication: NSObject, NSApplicationDelegate {
    private let root: URL
    private var window: NSWindow!
    private var runtime: ProcessingRuntime!
    private var readModel: MeetingReadModel!
    private var capture: MeetingCaptureService!
    private var recordingView: CaptureRecordingView!
    private var meetingsView: MeetingManagementView!
    private var store: JobStore!
    private var handler: NativeWorkflowHandler!
    private var observation: UUID?
    private let advance = NSButton(title: "Advance controlled stage", target: nil, action: nil)
    private let fail = NSButton(title: "Fail controlled stage", target: nil, action: nil)
    init(root: URL) { self.root = root; super.init() }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do { try launch() }
        catch { fatalError("Synthetic workflow host setup failed: \(error)") }
    }
    private func launch() throws {
        let workspace = root.appendingPathComponent("workspace"), support = root.appendingPathComponent("support")
        store = try JobStore(databaseURL: support.appendingPathComponent("jobs.sqlite"))
        for id in ["A", "B"] {
            let directory = workspace.appendingPathComponent("Meetings/\(id)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "---\ntitle: Workflow \(id)\ncapture_session_id: \(id)\n---\n# Workflow \(id)\n\n## Notes\n\nHidden while processing\n".write(to: directory.appendingPathComponent("meeting.md"), atomically: true, encoding: .utf8)
            try "## Summary\n\nStale generated content must remain hidden\n".write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
            if try store.job(id: id) == nil {
                let old = JobManifest(type: TranscriptionJob.type, title: "Transcribe \(id)", executionClass: .heavy,
                    stages: [.init(id: "transcribe", title: "Transcribe \(id)")],
                    sourceArtifacts: [.init(relativePath: "Meetings/\(id)/meeting.md", role: "meeting-doorway")], metadata: ["capture_session_id": id])
                _ = try store.enqueue(id: id, manifest: MeetingWorkflowJob.manifest(transcription: old).owned(by: workspace))
            }
        }
        handler = NativeWorkflowHandler()
        let installer = TranscriptionComponentInstaller(paths: TranscriptionComponentPaths(applicationSupportURL: support), acquirer: NativeUnusedAcquirer())
        runtime = ProcessingRuntime(applicationSupportURL: support, componentInstaller: installer, jobStore: { [weak self] in self?.store },
            mayResumeTranscription: { _ in true }, makeTranscription: { [handler] _, _ in handler! }, analysis: handler)
        capture = MeetingCaptureService(vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support), preflight: { .readyForTesting })
        readModel = MeetingReadModel(workspaceID: workspace.path, sourceFactory: { [store] in
            MeetingManagementReadSource(serviceProvider: {
                MeetingManagementService(vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support), jobStore: store, enforceWorkspaceOwner: true)
            })
        })
        meetingsView = MeetingManagementView(readModelProvider: { [weak self] in self?.readModel }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        recordingView = CaptureRecordingView(serviceProvider: { [weak self] in self?.capture }, rootURLProvider: { workspace },
            teamsDetectionProvider: { nil }, jobRecordsProvider: { [store] in (try? store?.jobs()) ?? [] }, onOpenSettings: {})
        observation = store.observeChanges { [weak self] change in
            DispatchQueue.main.async { [weak self] in
                self?.readModel.invalidate(.jobTransition(meetingPaths: change.meetingPaths))
                self?.recordingView.refresh(isVisible: true)
            }
        }
        advance.target = self; advance.action = #selector(advanceStage)
        advance.setAccessibilityIdentifier("workflow-advance-stage")
        advance.keyEquivalent = "n"; advance.keyEquivalentModifierMask = [.command]
        let recordingScroll = NSScrollView()
        recordingScroll.hasVerticalScroller = true
        recordingScroll.documentView = recordingView
        recordingView.widthAnchor.constraint(equalTo: recordingScroll.contentView.widthAnchor).isActive = true
        let split = NSSplitView()
        split.isVertical = true
        split.addArrangedSubview(meetingsView.browserView)
        split.addArrangedSubview(meetingsView)
        split.addArrangedSubview(recordingScroll)
        fail.target = self; fail.action = #selector(failStage)
        fail.setAccessibilityIdentifier("workflow-fail-stage")
        let steps = NSStackView(views: [advance, fail])
        let stack = NSStackView(views: [steps, split])
        stack.orientation = .vertical; stack.alignment = .leading; stack.translatesAutoresizingMaskIntoConstraints = false
        split.translatesAutoresizingMaskIntoConstraints = false
        split.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 1400, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Workflow Native Tests"
        let content = NSView(); window.contentView = content; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            meetingsView.browserView.widthAnchor.constraint(greaterThanOrEqualToConstant: 220), recordingScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 390)])
        runtime.configure(settings: configured(workspace), searchIndex: nil, indexGeneration: 0)
        meetingsView.refresh(isVisible: true); recordingView.refresh(isVisible: true)
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    private func configured(_ workspace: URL) -> AppSettings { var settings = AppSettings(); settings.stillmatterRootURL = workspace; return settings }
    @objc private func advanceStage() { handler.complete() }
    @objc private func failStage() { handler.failCurrentJob() }
    func applicationWillTerminate(_ notification: Notification) { runtime?.stop(); readModel?.stop() }
}

private struct NativeUnusedAcquirer: TranscriptionModelAcquiring {
    func acquireModel(_ model: TranscriptionModelChoice, in stagingURL: URL, cancellation: TranscriptionInstallCancellation,
                      progress: @escaping (TranscriptionInstallProgress) -> Void) throws -> URL { throw JobsError.invalidManifest("No model downloads in native tests") }
}
private final class NativeWorkflowHandler: JobExecuting {
    private let lock = NSLock()
    private var pending: (JobRecord, JobStageDefinition, (Result<JobStageResult, Error>) -> Void)?
    private var failedJobID: String?
    func execute(job: JobRecord, stage: JobStageDefinition, completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        lock.lock()
        let fails = job.id == failedJobID
        if !fails { pending = (job, stage, completion) }
        lock.unlock()
        if fails { completion(.failure(JobsError.invalidManifest("Synthetic controlled stage failed"))) }
    }
    func failCurrentJob() {
        lock.lock(); let next = pending; pending = nil; failedJobID = next?.0.id; lock.unlock()
        next?.2(.failure(JobsError.invalidManifest("Synthetic controlled stage failed")))
    }
    func complete() {
        lock.lock(); let next = pending; pending = nil; lock.unlock()
        guard let (job, stage, completion) = next else { return }
        let artifacts = job.manifest.expectedOutputs.filter { $0.stageID == stage.id }.map { output in
            let text = output.validatorID == "markdown" ? "---\n" + output.requiredFrontmatterFields.map { $0 + ": synthetic" }.joined(separator: "\n") + "\n---\n" + output.requiredHeadings.map { "## " + $0 }.joined(separator: "\n") : "{}"
            return GeneratedArtifact(relativePath: output.relativePath, data: Data(text.utf8))
        }
        completion(.success(JobStageResult(artifacts: artifacts)))
    }
}
