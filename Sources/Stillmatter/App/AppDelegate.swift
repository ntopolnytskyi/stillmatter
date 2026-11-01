import AppKit
import Darwin
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterTranscriptionRuntime
import StillmatterPresentation
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let minimumWindowFrameSize = NSSize(width: 720, height: 520)
    let stateStore = ShellStateStore()
    private let meetingPresentationMetrics: MeetingPresentationMetrics? = {
        guard let path = ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_MEETING_METRICS_PATH"] else {
            return nil
        }
        let destination = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        return MeetingPresentationMetrics(onChange: { snapshot in
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: destination, options: .atomic)
        })
    }()
    let settingsStore: SettingsStore = {
        guard let fixtureRoot = ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] else {
            return SettingsStore()
        }
        // A disposable workspace must never share preferences with another test run.
        let suiteRoot = ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] ?? fixtureRoot
        let suiteName = "works.stillmatter.validation.\(suiteRoot.utf8.map(String.init).joined(separator: "-"))"
        let defaults = UserDefaults(suiteName: suiteName)!
        let env = ProcessInfo.processInfo.environment
        let calendarProbe = env["STILLMATTER_TASK06_CALENDAR_PROBE"] == "1"
            && env["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] != nil
            && env["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] != nil
        #if DEBUG
        if env["STILLMATTER_TASK05_LIFECYCLE"] == nil && !calendarProbe {
            defaults.removePersistentDomain(forName: suiteName)
        }
        #else
        if !calendarProbe { defaults.removePersistentDomain(forName: suiteName) }
        #endif
        let store = SettingsStore(userDefaults: defaults)
        var settings = store.settings
        let previouslySelectedRoot = settings.stillmatterRootURL?.standardizedFileURL.resolvingSymlinksInPath().path
        #if DEBUG
        if ProcessInfo.processInfo.environment["STILLMATTER_TASK05_LIFECYCLE"] == nil || settings.stillmatterRootURL == nil {
            settings.stillmatterRootURL = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        }
        if ProcessInfo.processInfo.environment["STILLMATTER_TASK05_LIFECYCLE"] != nil {
            settings.calendarSourceSelection = .none
        }
        #else
        settings.stillmatterRootURL = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        #endif
        if let mediaRoot = ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] {
            settings.recordingMediaURL = URL(fileURLWithPath: mediaRoot, isDirectory: true)
        }
        // Only a consented, isolated single-source probe may retain the user's
        // test-calendar choice across relaunch. Never default to reading all
        // calendars, including when a fixture root or support directory changes.
        let allowSelectedCalendar = calendarProbe && env["STILLMATTER_VALIDATION_ALLOW_CALENDAR"] == "1"
            && previouslySelectedRoot == URL(fileURLWithPath: fixtureRoot).standardizedFileURL.resolvingSymlinksInPath().path
            && settings.calendarSourceSelection.mode == .selected
            && settings.calendarSourceSelection.selectedCalendarIdentifiers.count == 1
        if !allowSelectedCalendar { settings.calendarSourceSelection = .none }
        store.settings = settings
        return store
    }()
    private let lifecyclePolicy = AppLifecyclePolicy()
    #if DEBUG
    private static var isLifecycleProbe: Bool {
        ProcessInfo.processInfo.environment["STILLMATTER_TASK05_LIFECYCLE"] != nil
    }
    #endif
    private lazy var composition = AppComposition(settingsStore: settingsStore, applicationSupportURL: Self.applicationSupportURL,
        onCaptureSnapshot: { [weak self] in self?.handleCaptureSnapshot($0) },
        captureBuild: { [weak self] in
            #if DEBUG
            guard Self.isLifecycleProbe else { return nil }
            return { [weak self, support = Self.applicationSupportURL] settings, jobs, inbox in
                MeetingCaptureService(vault: WorkspaceVault(workspaceRootURL: settings.stillmatterRootURL!,
                    appSupportRootURL: support), jobStore: jobs, inbox: inbox,
                    micRecorder: self?.task05Microphone, preflight: { .readyForTesting })
            }
            #else
            return nil
            #endif
        }())
    var tasksInbox: TasksInbox? {
        guard let root = settingsStore.settings.stillmatterRootURL else { return nil }
        return try? composition.tasksInbox?.scoped(to: root)
    }
    var jobStore: JobStore? { composition.jobStore }
    lazy var indexRuntime = SearchIndexRuntime(databaseURL: Self.searchDatabaseURL,
        onChange: { [weak self] index, generation in
            guard let self, !self.isShuttingDown else { return }
            self.meetingReadModel?.updateSearchIndex(index)
            self.meetingMutationExecutor?.updateSearchIndex(index)
            self.stateStore.publish(.searchIndex)
            if index != nil {
                self.processingRuntime.configureTranscription(settings: self.settingsStore.settings,
                    searchIndex: index, indexGeneration: generation)
            }
        })
    var searchIndex: SearchIndex? { indexRuntime.index }
    private var meetingReadModel: MeetingReadModel?
    private var meetingWorkspaceChangeMonitor: MeetingWorkspaceChangeMonitor?
    private var workbenchWorkspaceChangeMonitor: WorkbenchWorkspaceChangeMonitor?
    private var meetingReadWorkspaceKey: String?
    private var meetingJobChangeObserver: UUID?
    private var meetingReadChangeObservation: MeetingChangeObservation?
    private var meetingMutationExecutor: MeetingMutationExecutor?
    private var meetingPlaybackController: MeetingAudioPlaybackController?
    var indexGeneration: Int { indexRuntime.generation }
    private var workspaceRuntime: WorkspaceRuntime { composition.workspaceRuntime }
    private var workspaceGeneration: Int { workspaceRuntime.generation }
    var effectiveWorkspacePath: String? { workspaceRuntime.identity }
    private var isShuttingDown: Bool { workspaceRuntime.isStopped }
    private lazy var processingRuntime = ProcessingRuntime(
        applicationSupportURL: Self.applicationSupportURL, componentInstaller: transcriptionComponentInstaller,
        jobStore: { [weak self] in self?.jobStore },
        mayResumeTranscription: { [weak self] owner in
            guard let self else { return false }
            return !self.isShuttingDown && self.settingsStore.pendingWorkspace == nil &&
                   self.effectiveWorkspacePath == owner
        },
        isProbe: {
            #if DEBUG
            return Self.isLifecycleProbe
            #else
            return false
            #endif
        },
        analysisConfiguration: { PiIntegration().detectedExecutableURL()?.standardizedFileURL.path ?? "missing-pi" },
        makeAnalysis: { [weak self] root in
            guard let self, let inbox = self.tasksInbox,
                  let executable = PiIntegration().detectedExecutableURL() else {
                return UnavailableJobHandler(guidance: "Pi CLI is unavailable. Install/configure Pi, then Retry this stage. No Meeting text was uploaded.")
            }
            let worker = PiCodexWorker(executableURL: executable, vaultRootURL: root)
            return MeetingSummaryJobExecutor(worker: worker, workspaceRootURL: root,
                vault: WorkspaceVault(workspaceRootURL: root, appSupportRootURL: Self.applicationSupportURL), inbox: inbox,
                onApplied: { [weak self] in
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.isShuttingDown,
                              self.effectiveWorkspacePath == root.standardizedFileURL.resolvingSymlinksInPath().path else { return }
                        self.stateStore.publish(.tasks)
                        self.stateStore.publish(.jobStatus)
                    }
                })
        }
    )
    var heavyExecutionGate: JobHeavyExecutionGate { processingRuntime.heavyExecutionGate }
    private var transcriptionScheduler: JobScheduler? { processingRuntime.transcriptionScheduler }
    private func schedulerForMeetingRetry(_ type: String) -> JobScheduler? { processingRuntime.scheduler(for: type) }
    private var transcriptionComponentInstaller: TranscriptionComponentInstaller { composition.transcriptionComponentInstaller }
    private var transcriptionComponentObserver: UUID?
    private var captureRuntime: CaptureSessionRuntime { composition.captureRuntime }
    var captureService: MeetingCaptureService? { captureRuntime.service }
    lazy var teamsAutomation = TeamsAutomationRuntime(
        mode: { [weak self] in self?.settingsStore.settings.teamsRecordingMode ?? .manual },
        capture: { [weak self] in self?.captureService },
        askWindow: { [weak self] in
            self?.showMainWindow(selecting: .recording)
            return self?.mainWindow
        },
        onStatus: { [weak self] in self?.stateStore.publish(.teamsStatus) },
        onDetection: { [weak self] snapshot in
            guard let self else { return }
            self.updateAttentionEnvironment()
            if snapshot.isMeetingDetected { self.dismissTitleReviewForMeeting() }
            else { self.refreshInboxAttention() }
        }
    )
    var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var titleReviewTimer: Timer?
    private var titleReviewLastPrompt: [String: Date] = [:]
    private var titleReviewIsPresenting = false
    private weak var titleReviewAlert: NSAlert?
    private var isMeetingOrRecordingActive = false {
        didSet { updateAttentionEnvironment() }
    }
    private lazy var attention = AppAttentionController(
        inbox: { [weak self] in self?.tasksInbox },
        onPopup: { [weak self] target in self?.presentAttention(target) },
        onOpen: { [weak self] target in self?.openAttention(target) }
    )
    private var quitRequested = false
    #if DEBUG
    var validationJobScheduler: JobScheduler?
    let task05Microphone = Task05FakeMicrophone()
    let task05Worker = Task05FakeWorker()
    var task05MeetingGate: Task05MeetingMutationGate?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        configureApplicationMenu()
        #if DEBUG || STILLMATTER_NATIVE_PROBES
        if runValidationLaunchIfRequested() { return }
        #endif
        configureStatusItem()
        settingsStore.onWorkspaceWillChange = { [weak self] settings in
            guard let self else { return }
            // Settings are written by the native Settings UI on the main executor.
            // Install the new lifetime before SettingsStore publishes it to Shell observers.
            precondition(Thread.isMainThread, "Workspace changes must be made on the UI executor")
            try self.workspaceRuntime.validate(.init(root: settings.stillmatterRootURL, media: settings.recordingMediaURL))
            if let shell = self.mainWindow?.contentViewController as? ShellViewController,
               shell.hasDirtyMeetingDraftForWorkspaceChange {
                // The setter retains this request as pending when preparation throws.
                // Ask after it unwinds so Save can complete asynchronously before retry.
                DispatchQueue.main.async { [weak self, weak shell] in
                    guard let self, let shell, self.settingsStore.pendingWorkspace != nil else { return }
                    shell.prepareMeetingWorkspaceChange { [weak self] proceed in
                        guard let self else { return }
                        if proceed { self.retryPendingWorkspace() }
                        else { self.settingsStore.cancelPendingWorkspace() }
                    }
                }
                throw NSError(domain: "Stillmatter.MeetingDraft", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Resolve Meeting edits before switching"])
            }
            MainActor.assumeIsolated { self.activateWorkspace(settings) }
        }
        attention.start()
        updateAttentionEnvironment()
        settingsStore.observe { [weak self] settings in
            Task { @MainActor [weak self] in
                guard let self, !self.isShuttingDown, settings == self.settingsStore.settings else { return }
                _ = self.workspaceRuntime.activate(settings)
                self.refreshInboxAttention()
                self.configureMeetingReadModel(settings: settings)
                self.indexRuntime.configure(settings)
                self.processingRuntime.configure(settings: settings, searchIndex: self.searchIndex,
                    indexGeneration: self.indexGeneration)
                self.configureCaptureService(settings: settings)
                self.workspaceRuntime.resumeAfterCancellation(settingsStore: self.settingsStore,
                    schedulers: self.processingRuntime.schedulers)
                self.teamsAutomation.reconcileCurrent()
            }
        }
        transcriptionComponentObserver = transcriptionComponentInstaller.observe { [weak self] state in
            guard case .ready = state else { return }
            guard let self else { return }
            self.processingRuntime.configureTranscription(settings: self.settingsStore.settings,
                searchIndex: self.searchIndex, indexGeneration: self.indexGeneration)
        }
        #if DEBUG
        teamsAutomation.start(polling: !Self.isLifecycleProbe)
        #else
        teamsAutomation.start()
        #endif
        titleReviewTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshInboxAttention()
        }
        #if DEBUG || STILLMATTER_NATIVE_PROBES
        seedProposalReviewValidationFixtureIfRequested()
        #endif
        // The initial Meetings screen connects to this provider while loading its view.
        // The settings observer above schedules its work asynchronously, so create the
        // model before showing the window rather than leaving that first view disconnected.
        configureMeetingReadModel(settings: settingsStore.settings)
        showMainWindow(selecting: .meetings)
        #if DEBUG
        if Self.isLifecycleProbe {
            #if DEBUG
            if ProcessInfo.processInfo.environment["STILLMATTER_TASK05_LIFECYCLE"] == "regression" {
                runTask05NativeRegressionProbe()
            } else {
                runTask05NativeLifecycleProbe()
            }
            #endif
        }
        startDisposableRunningJobFixtureIfRequested()
        #endif
        DispatchQueue.main.async { [weak self] in self?.refreshInboxAttention() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        workspaceRuntime.stop()
        indexRuntime.stop()
        processingRuntime.stop()
        #if DEBUG
        validationJobScheduler?.stop()
        #endif
        teamsAutomation.stop()
        titleReviewTimer?.invalidate()
        attention.stop()
        workbenchWorkspaceChangeMonitor?.stop()
        workbenchWorkspaceChangeMonitor = nil
        meetingWorkspaceChangeMonitor?.stop()
        meetingWorkspaceChangeMonitor = nil
        meetingReadChangeObservation?.cancel()
        meetingReadChangeObservation = nil
        meetingReadModel?.stop()
        meetingReadModel = nil
        if let observer = meetingJobChangeObserver { jobStore?.removeChangeObserver(observer) }
        meetingJobChangeObserver = nil
        meetingMutationExecutor = nil
        meetingPlaybackController?.stop()
        meetingPlaybackController = nil
        #if DEBUG
        if Self.isLifecycleProbe {
            precondition(workspaceRuntime.isStopped)
            print("TASK05_NATIVE applicationWillTerminate stopped workspace and schedulers")
            fflush(stdout)
        }
        #endif
    }

    func applicationDidResignActive(_ notification: Notification) {
        updateAttentionEnvironment()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        updateAttentionEnvironment()
        DispatchQueue.main.async { [weak self] in self?.refreshInboxAttention() }
    }

    /// Capture/meeting integrations report activity here so required prompts stay deferred.
    func meetingOrRecordingActivityDidChange(isActive: Bool) {
        isMeetingOrRecordingActive = isActive
        if isActive { dismissTitleReviewForMeeting() }
        else { refreshInboxAttention() }
    }

    private func currentInboxID(from qualified: String) -> String? {
        guard let owner = tasksInbox?.workspaceRootPath,
              qualified.hasPrefix(owner + "\n") else { return nil }
        return String(qualified.dropFirst(owner.count + 1))
    }

    private func titleAttentionTarget(_ id: String) -> AttentionTarget {
        .titleReview((tasksInbox?.workspaceRootPath ?? "") + "\n" + id)
    }

    private func presentAttention(_ target: AttentionTarget) {
        switch target {
        case let .titleReview(qualified):
            guard let id = currentInboxID(from: qualified) else { return }
            // Modal title review starts on the next UI turn, without a timer.
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let item = try? self.tasksInbox?.items(category: .required).first(where: { $0.id == id }) else { return }
                self.offerTitleReview(item: item)
            }
        case .inboxItem, .captureFailure: break
        }
    }

    private func openAttention(_ target: AttentionTarget) {
        switch target {
        case let .titleReview(qualified):
            guard let id = currentInboxID(from: qualified) else { return }
            showMainWindow(selecting: .today)
            (mainWindow?.contentViewController as? ShellViewController)?.focusInboxItem(id: id)
            // The exact row stays visible while the review prompt is suppressed
            // by a Meeting; the required review still flushes after it ends.
            guard let item = try? tasksInbox?.items(category: .required).first(where: { $0.id == id }) else { return }
            offerTitleReview(item: item, explicit: true)
        case let .inboxItem(qualified):
            guard let id = currentInboxID(from: qualified) else { return }
            showMainWindow(selecting: .today)
            (mainWindow?.contentViewController as? ShellViewController)?.focusInboxItem(id: id)
        case .captureFailure:
            showMainWindow(selecting: .recording)
        }
    }

    private func updateAttentionEnvironment() {
        let meetingActive = isMeetingOrRecordingActive || teamsAutomation.snapshot.isMeetingDetected
        let focusedWindow = NSApp.isActive
            ? (mainWindow?.isVisible == true ? mainWindow : NSApp.keyWindow)
            : nil
        attention.setEnvironment(meetingActive: meetingActive, focusedWindow: focusedWindow)
    }

    private func titleReviewSourceAvailable(_ item: InboxItem) -> Bool {
        guard let root = settingsStore.settings.stillmatterRootURL, let path = item.sourceRef else { return false }
        let vault = WorkspaceVault(workspaceRootURL: root, appSupportRootURL: Self.applicationSupportURL)
        return (try? vault.versionOfMarkdown(relativePath: path)) != nil
    }

    private func refreshInboxAttention() {
        attention.refreshInbox { [weak self] item in
            guard let self = self else { return false }
            return item.kind == .titleReview
                && self.titleReviewSourceAvailable(item)
                && Date().timeIntervalSince(self.titleReviewLastPrompt[item.id] ?? .distantPast) >= 3600
        }
    }

    /// Required Inbox reviews are offered from the app, not from a particular tab.
    private func offerTitleReview(item requested: InboxItem? = nil, explicit: Bool = false) {
        guard !titleReviewIsPresenting, NSApp.isActive, mainWindow?.isVisible == true,
              !isMeetingOrRecordingActive, !teamsAutomation.snapshot.isMeetingDetected,
              let inbox = tasksInbox, let root = settingsStore.settings.stillmatterRootURL else { return }
        // A retained Today row/action cannot be reinterpreted as a colliding B ID.
        if let requested, requested.workspaceOwner != inbox.workspaceRootPath { return }
        do {
            let pending = try inbox.items(category: .required).filter { $0.kind == .titleReview }
            guard let item = requested == nil ? pending.first(where: titleReviewSourceAvailable)
                : pending.first(where: { $0.id == requested?.id }) else { return }
            guard explicit || Date().timeIntervalSince(titleReviewLastPrompt[item.id] ?? .distantPast) >= 3600 else { return }
            guard titleReviewSourceAvailable(item) else {
                if explicit {
                    let missing = NSAlert()
                    missing.messageText = "Meeting unavailable"
                    missing.informativeText = "This meeting is not in the current workspace. Select its original workspace in Settings to review its title. The pending review has been kept."
                    missing.addButton(withTitle: "OK")
                    missing.runModal()
                }
                return
            }
            titleReviewIsPresenting = true
            defer { titleReviewIsPresenting = false }
            let alert = NSAlert()
            titleReviewAlert = alert
            defer { titleReviewAlert = nil }
            alert.messageText = "Review meeting title"
            alert.informativeText = "Edit the suggested title or accept it. The folder stays put if other workspace notes or jobs refer to its current path."
            alert.addButton(withTitle: "Accept title")
            alert.addButton(withTitle: "Later")
            let input = NSTextField(string: item.title)
            input.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
            alert.accessoryView = input
            while true {
                guard !isMeetingOrRecordingActive, !teamsAutomation.snapshot.isMeetingDetected else { return }
                let response = alert.runModal()
                guard !isMeetingOrRecordingActive, !teamsAutomation.snapshot.isMeetingDetected else { return }
                guard response == .alertFirstButtonReturn else {
                    titleReviewLastPrompt[item.id] = Date()
                    attention.clear(titleAttentionTarget(item.id))
                    return
                }
                let title = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else {
                    alert.informativeText = "Enter a title, or choose Later."
                    continue
                }
                do {
                    guard settingsStore.settings.stillmatterRootURL?.standardizedFileURL.resolvingSymlinksInPath() == root.standardizedFileURL.resolvingSymlinksInPath() else { return }
                    let vault = WorkspaceVault(workspaceRootURL: root, appSupportRootURL: Self.applicationSupportURL)
                    let newPath = try MeetingTitleReviewService(vault: vault, inbox: inbox, jobStore: jobStore, searchIndex: searchIndex, enforceWorkspaceOwner: true)
                        .accept(id: item.id, title: title)
                    if let oldPath = item.sourceRef {
                        captureService?.titleReviewAccepted(meetingRelativePath: oldPath, title: title, newPath: newPath)
                        if newPath != oldPath, let index = searchIndex {
                            DispatchQueue.global(qos: .utility).async {
                                do { try index.rebuild() }
                                catch { NSLog("Could not refresh search after meeting rename: \(error)") }
                            }
                        }
                    }
                    titleReviewLastPrompt.removeValue(forKey: item.id)
                    attention.clear(titleAttentionTarget(item.id))
                    stateStore.publish(.tasks)
                    meetingReadModel?.forceRescan()
                    return
                } catch {
                    alert.informativeText = "Could not save title: \(error). Correct it or choose Later."
                }
            }
        } catch {
            NSLog("Could not load Required title reviews: \(error)")
        }
    }

    private func dismissTitleReviewForMeeting() {
        guard let alert = titleReviewAlert else { return }
        NSApp.stopModal(withCode: .abort)
        alert.window.orderOut(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        lifecyclePolicy.shouldTerminateAfterLastWindowClosed
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        lifecyclePolicy.shouldTerminate(quitRequested: quitRequested) ? .terminateNow : .terminateCancel
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow(nil)
        }
        return true
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        // Mutating split regions during windowWillResize re-enters AppKit's layout
        // pass when the 720 pt policy collapses detail to a list, crashing the app.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            (window.contentViewController as? ShellViewController)?.prepareForWindowResize(to: window.frame.width)
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == mainWindow else { return true }
        sender.orderOut(nil)
        DispatchQueue.main.async { [weak self] in self?.updateAttentionEnvironment() }
        return lifecyclePolicy.shouldCloseMainWindow
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow == mainWindow else { return }
        mainWindow = nil
    }

    @objc func showMainWindow(_ sender: Any?) {
        showMainWindow(selecting: nil)
    }

    @objc func showSettings(_ sender: Any?) {
        showMainWindow(selecting: .settings)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        showMainWindow(nil)
        (mainWindow?.contentViewController as? ShellViewController)?.toggleSidebar(sender)
    }

    @objc func focusAreaSearch(_ sender: Any?) {
        showMainWindow(nil)
        (mainWindow?.contentViewController as? ShellViewController)?.focusAreaSearch(sender)
    }

    @objc func selectArea(_ sender: NSMenuItem) {
        guard ShellTab.allCases.indices.contains(sender.tag) else { return }
        showMainWindow(selecting: ShellTab.allCases[sender.tag])
    }

    @objc func quit(_ sender: Any?) {
        quitRequested = true
        NSApp.terminate(nil)
    }

    func makeMainWindow() -> NSWindow {
        let shellViewController = ShellViewController(
            stateStore: stateStore,
            settingsStore: settingsStore,
            tasksInbox: tasksInbox,
            searchIndexProvider: { [weak self] in self?.searchIndex },
            captureServiceProvider: { [weak self] in self?.captureService },
            onReviewTitle: { [weak self] item in self?.offerTitleReview(item: item, explicit: true) },
            teamsDetectionProvider: { [weak self] in self?.teamsAutomation.snapshot },
            teamsRecordingDiagnosticProvider: { [weak self] in self?.teamsAutomation.diagnostic ?? "Capture policy unavailable" },
            onManualCapture: { [weak self] in self?.manualCaptureOverride() },
            jobRecordsProvider: { [weak self] in self?.currentJobRecords() ?? [] },
            jobStatusProvider: { [weak self] in self?.currentJobStatus() ?? "Jobs unavailable" },
            meetingServiceProvider: { [weak self] in
                guard let root = self?.settingsStore.settings.stillmatterRootURL else { return nil }
                return MeetingManagementService(
                    vault: WorkspaceVault(workspaceRootURL: root, appSupportRootURL: Self.applicationSupportURL),
                    jobStore: self?.jobStore,
                    inbox: self?.tasksInbox,
                    searchIndex: self?.searchIndex,
                    recordingMediaURL: self?.settingsStore.settings.recordingMediaURL,
                    captureSnapshot: { [weak self] in self?.captureService?.snapshot },
                    retryUnavailableReason: { [weak self] type in
                        guard let self else { return "Processing is unavailable." }
                        return self.schedulerForMeetingRetry(type) == nil ? "The required processing service is not configured." : nil
                    },
                    retryDispatcher: { [weak self] type, id, meetingPath, session in
                        guard let self else { throw MeetingManagementError.retryRejected("Processing is unavailable.") }
                        guard let scheduler = self.schedulerForMeetingRetry(type) else {
                            throw MeetingManagementError.retryRejected("The required processing service is not configured.")
                        }
                        try scheduler.retry(id: id, meetingRelativePath: meetingPath, captureSessionID: session)
                    },
                    onReprocessQueued: { [weak self] in self?.transcriptionScheduler?.start() },
                    onMeetingChanged: { [weak self] paths in
                        self?.meetingReadModel?.invalidate(.appMutation(paths: paths))
                    },
                    enforceWorkspaceOwner: true
                )
            },
            meetingReadModelProvider: { [weak self] in self?.meetingReadModel },
            meetingMutationExecutorProvider: { [weak self] in
                #if DEBUG
                if let gate = self?.task05MeetingGate { return gate }
                #endif
                return self?.meetingMutationExecutor
            },
            meetingPlaybackTransportProvider: { [weak self] in self?.meetingPlaybackController },
            transcriptionComponentInstaller: transcriptionComponentInstaller,
            onRebuildIndex: { [weak self] completion in
                guard let self else { completion(.failure(NSError(domain: "Stillmatter.SearchIndex", code: 1))); return }
                self.indexRuntime.recover(self.settingsStore.settings, completion: completion)
            },
            onRetryPendingWorkspace: { [weak self] in self?.retryPendingWorkspace() },
            meetingPresentationMetrics: meetingPresentationMetrics
        )
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_200, height: 760)
        let initialContentSize = NSSize(
            width: floor(visibleFrame.width * 0.8),
            height: floor(visibleFrame.height * 0.8)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stillmatter"
        window.contentViewController = shellViewController
        // The supported minimum is the *outer window* size. Convert to content
        // coordinates before assigning contentMinSize so the titlebar is included.
        let minimumFrame = NSRect(origin: .zero, size: Self.minimumWindowFrameSize)
        window.contentMinSize = window.contentRect(forFrameRect: minimumFrame).size
        window.setContentSize(initialContentSize)
        window.collectionBehavior = [.canJoinAllSpaces]
        window.center()
        window.delegate = self
        return window
    }

    private func showMainWindow(selecting tab: ShellTab?) {
        if mainWindow == nil {
            mainWindow = makeMainWindow()
        }

        if let tab = tab {
            stateStore.state.select(tab)
        }

        guard let window = mainWindow else { return }

        NSApp.unhide(nil)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        if !isWindowOnAnyVisibleScreen(window) {
            centerWindowOnMainScreen(window)
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        updateAttentionEnvironment()
    }

    private func isWindowOnAnyVisibleScreen(_ window: NSWindow) -> Bool {
        NSScreen.screens.contains { screen in
            window.frame.intersects(screen.visibleFrame)
        }
    }

    private func centerWindowOnMainScreen(_ window: NSWindow) {
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1120, height: 760)
        let size = window.frame.size
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.midY - size.height / 2
        )
        window.setFrameOrigin(origin)
    }

    @MainActor
    private func activateWorkspace(_ settings: AppSettings) {
        processingRuntime.pauseSynchronously()
        _ = workspaceRuntime.activate(settings)
        // The old index must be invalidated before a new Meeting model can capture it.
        indexRuntime.configure(settings)
        configureMeetingReadModel(settings: settings)
        processingRuntime.configure(settings: settings, searchIndex: searchIndex, indexGeneration: indexGeneration)
        configureCaptureService(settings: settings)
        workspaceRuntime.didActivateSelection()
        // An unchanged-root media reconfiguration can retain the same scheduler instance.
        processingRuntime.start()
    }

    func retryPendingWorkspace() {
        _ = workspaceRuntime.retryPendingSelection(settingsStore: settingsStore, jobStore: jobStore,
            schedulers: processingRuntime.schedulers)
    }

    private func configureCaptureService(settings: AppSettings) {
        if captureRuntime.configure(settings) { stateStore.publish(.recordingStatus) }
        let snapshot = captureService?.snapshot
        meetingReadModel?.updateCaptureSnapshot(snapshot)
        meetingMutationExecutor?.updateCaptureSnapshot(snapshot)
    }

    private func handleCaptureSnapshot(_ snapshot: CaptureSnapshot) {
        meetingReadModel?.updateCaptureSnapshot(snapshot)
        meetingMutationExecutor?.updateCaptureSnapshot(snapshot)
        let isActive = snapshot.state == .starting
            || snapshot.state == .recording
            || snapshot.state == .stopping
            || snapshot.state == .finalizing
        let apply = { [weak self] in
            guard let self, !self.isShuttingDown else { return }
            self.settingsStore.workspaceChangeHeld = isActive || snapshot.state == .failed || snapshot.state == .recovered
            self.meetingOrRecordingActivityDidChange(isActive: isActive)
            if snapshot.state == .failed {
                self.settingsStore.reportPendingWorkspaceFailure(snapshot.failureMessage ?? "Capture or recovery failed")
                self.attention.offer(AttentionRequest(
                    target: .captureFailure(snapshot.meetingRelativePath ?? "failure"),
                    title: "Recording needs attention", kind: .recordingCritical
                ))
            }
            self.statusItem?.button?.title = snapshot.state == .recording ? "Stillmatter ●" : "Stillmatter"
            self.statusItem?.button?.toolTip = snapshot.state == .recording
                ? "Recording \(snapshot.meetingTitle ?? "Meeting")"
                : "Stillmatter is available. Open the window or quit explicitly."
            if snapshot.state == .idle {
                self.transcriptionScheduler?.start()
                self.retryPendingWorkspace()
            }
            self.stateStore.publish(.recordingStatus)
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    @MainActor
    func configureMeetingReadModel(settings: AppSettings) {
        guard let rootURL = settings.stillmatterRootURL else {
            workbenchWorkspaceChangeMonitor?.stop()
            workbenchWorkspaceChangeMonitor = nil
            meetingWorkspaceChangeMonitor?.stop()
            meetingMutationExecutor = nil
            meetingPlaybackController?.stop()
            meetingPlaybackController = nil
            meetingWorkspaceChangeMonitor = nil
            meetingReadChangeObservation?.cancel()
            meetingReadChangeObservation = nil
            meetingReadModel?.stop()
            meetingReadModel = nil
            if let observer = meetingJobChangeObserver { jobStore?.removeChangeObserver(observer) }
            meetingJobChangeObserver = nil
            meetingReadWorkspaceKey = nil
            return
        }
        let workspaceKey = [rootURL.standardizedFileURL.path,
                            settings.recordingMediaURL?.standardizedFileURL.path ?? "<no-media>"]
            .joined(separator: "\n")
        guard workspaceKey != meetingReadWorkspaceKey else { return }

        workbenchWorkspaceChangeMonitor?.stop()
        workbenchWorkspaceChangeMonitor = nil
        meetingWorkspaceChangeMonitor?.stop()
        meetingWorkspaceChangeMonitor = nil
        meetingMutationExecutor = nil
        meetingPlaybackController?.stop()
        meetingPlaybackController = nil
        meetingReadChangeObservation?.cancel()
        meetingReadChangeObservation = nil
        meetingReadModel?.stop()
        if let observer = meetingJobChangeObserver { jobStore?.removeChangeObserver(observer) }
        meetingJobChangeObserver = nil

        let operationalJobs = jobStore
        let operationalInbox = try? composition.tasksInbox?.scoped(to: rootURL)
        let currentIndex = searchIndex
        let captureSnapshot = captureService?.snapshot
        let mediaURL = settings.recordingMediaURL
        let appSupportURL = Self.applicationSupportURL
        let model = MeetingReadModel(workspaceID: workspaceKey, sourceFactory: {
            // This factory runs only on the model's serial read executor. The vault is owned
            // by that executor; operational stores and SearchIndex expose lock-confined methods.
            let vault = WorkspaceVault(workspaceRootURL: rootURL, appSupportRootURL: appSupportURL)
            return MeetingManagementReadSource(searchIndex: currentIndex, captureSnapshot: captureSnapshot) { index, snapshot in
                MeetingManagementService(vault: vault, jobStore: operationalJobs, inbox: operationalInbox,
                                         searchIndex: index, recordingMediaURL: mediaURL,
                                         captureSnapshot: { snapshot }, enforceWorkspaceOwner: true)
            }
        })
        meetingReadWorkspaceKey = workspaceKey
        meetingReadModel = model
        let mutationExecutor = MeetingMutationExecutor(searchIndex: currentIndex, captureSnapshot: captureSnapshot) { [weak self, weak model] index, snapshot in
            guard let self else { return nil }
            return self.makeMeetingManagementService(rootURL: rootURL, mediaURL: mediaURL,
                searchIndex: index, captureSnapshot: snapshot, readModel: model,
                jobStore: operationalJobs, inbox: operationalInbox)
        }
        meetingMutationExecutor = mutationExecutor
        #if DEBUG
        if ProcessInfo.processInfo.environment["STILLMATTER_TASK05_LIFECYCLE"] == "regression" {
            task05MeetingGate = Task05MeetingMutationGate(underlying: mutationExecutor)
        }
        #endif
        meetingPlaybackController = MeetingAudioPlaybackController()
        meetingReadChangeObservation = model.observeChanges { event in
            if case let .monitoringFailed(message) = event.change {
                NSLog("Meeting workspace monitor failed: %@. Call forceRescan() after recovery.", message)
            }
        }

        if let operationalJobs {
            let ownerPath = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
            meetingJobChangeObserver = operationalJobs.observeChanges { [weak self, weak model] change in
                guard (try? operationalJobs.job(id: change.jobID))?.manifest.workspaceOwner == ownerPath else { return }
                if !change.meetingPaths.isEmpty {
                    model?.invalidate(.jobTransition(meetingPaths: change.meetingPaths))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isShuttingDown, self.meetingReadWorkspaceKey == workspaceKey else { return }
                    self.stateStore.publish(.jobStatus)
                    if self.settingsStore.pendingWorkspace != nil && !self.settingsStore.workspaceChangeHeld {
                        self.retryPendingWorkspace()
                    }
                }
            }
        }
        let monitor = MeetingWorkspaceChangeMonitor(rootURL: rootURL) { [weak model] change in
            model?.invalidate(change)
        }
        meetingWorkspaceChangeMonitor = monitor
        monitor.start()
        let workbenchMonitor = WorkbenchWorkspaceChangeMonitor(root: rootURL) { [weak self] change in
            guard let self, !self.isShuttingDown, self.meetingReadWorkspaceKey == workspaceKey else { return }
            self.stateStore.publish(change)
        }
        workbenchWorkspaceChangeMonitor = workbenchMonitor
        workbenchMonitor.start()
    }

    private func makeMeetingManagementService(rootURL: URL, mediaURL: URL?, searchIndex: SearchIndex?,
                                              captureSnapshot: CaptureSnapshot?, readModel: MeetingReadModel?,
                                              jobStore: JobStore?, inbox: TasksInbox?) -> MeetingManagementService {
        MeetingManagementService(
            vault: WorkspaceVault(workspaceRootURL: rootURL, appSupportRootURL: Self.applicationSupportURL),
            jobStore: jobStore,
            inbox: inbox,
            searchIndex: searchIndex,
            recordingMediaURL: mediaURL,
            captureSnapshot: { captureSnapshot },
            retryUnavailableReason: { [weak self] type in
                guard let self else { return "Processing is unavailable." }
                return DispatchQueue.main.sync {
                    self.schedulerForMeetingRetry(type) == nil
                        ? "The required processing service is not configured." : nil
                }
            },
            retryDispatcher: { [weak self] type, id, meetingPath, session in
                guard let self else { throw MeetingManagementError.retryRejected("Processing is unavailable.") }
                let scheduler = DispatchQueue.main.sync { self.schedulerForMeetingRetry(type) }
                guard let scheduler else {
                    throw MeetingManagementError.retryRejected("The required processing service is not configured.")
                }
                try scheduler.retry(id: id, meetingRelativePath: meetingPath, captureSessionID: session)
            },
            onReprocessQueued: { [weak self] in
                DispatchQueue.main.async { self?.transcriptionScheduler?.start() }
            },
            onMeetingChanged: { [weak readModel] paths in
                readModel?.invalidate(.appMutation(paths: paths))
            },
            enforceWorkspaceOwner: true
        )
    }

    func currentJobRecords() -> [JobRecord]? {
        guard let jobStore = jobStore else { return nil }
        let supportedTypes = MeetingWorkflowJob.supportedTypes
        let owner = settingsStore.settings.stillmatterRootURL?.standardizedFileURL.resolvingSymlinksInPath().path
        guard let owner else { return [] }
        return try? jobStore.jobs().filter { supportedTypes.contains($0.manifest.type) && $0.manifest.workspaceOwner == owner }
    }

    private func currentJobStatus() -> String {
        if let error = processingRuntime.configurationError { return error }
        guard let jobs = currentJobRecords() else { return "Jobs unavailable" }
        if let unowned = try? jobStore?.jobs().filter({ $0.manifest.workspaceOwner == nil &&
            MeetingWorkflowJob.supportedTypes.contains($0.manifest.type) }).count,
           unowned > 0 {
            return "\(unowned) legacy Job(s) need workspace review; processing paused for these Jobs"
        }
        let failed = jobs.filter { $0.status == .failed }.count
        if failed > 0 { return "\(failed) Job\(failed == 1 ? "" : "s") failed" }
        if let running = jobs.first(where: { $0.status == .running }) {
            return running.stages.first(where: { $0.status == .running })?.definition.title ?? "Processing Meeting"
        }
        let queued = jobs.filter { $0.status == .queued }.count
        if queued > 0 { return "\(queued) Job\(queued == 1 ? "" : "s") queued" }
        return "Jobs idle"
    }

    static let applicationSupportURL: URL = {
        if let override = ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stillmatter", isDirectory: true)
    }()

    private static let searchDatabaseURL = applicationSupportURL.appendingPathComponent("search.sqlite")

    private func manualCaptureOverride() { teamsAutomation.manualOverride() }

    @objc private func startManualCapture(_ sender: Any?) {
        showMainWindow(selecting: .recording)
        guard let service = captureService,
              [.idle, .failed, .recovered, .detecting].contains(service.snapshot.state) else { return }
        manualCaptureOverride()
        do { _ = try service.startManual() }
        catch { NSLog("Manual capture start failed: \(error)") }
        stateStore.publish(.recordingStatus)
    }

    @objc private func stopManualCapture(_ sender: Any?) {
        guard let service = captureService, service.snapshot.state == .recording else { return }
        manualCaptureOverride()
        service.stopManualAsync { [weak self] result in
            if case let .failure(error) = result {
                NSLog("Manual capture stop failed: \(error)")
                NSApp.requestUserAttention(.criticalRequest)
            }
            self?.stateStore.publish(.recordingStatus)
        }
        stateStore.publish(.recordingStatus)
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "Stillmatter"
        item.button?.toolTip = "Stillmatter is available. Open the window or quit explicitly."

        let menu = NSMenu()
        menu.addItem(makeMenuItem(title: "Open Stillmatter", action: #selector(showMainWindow(_:))))
        menu.addItem(makeMenuItem(title: "Start Capture", action: #selector(startManualCapture(_:))))
        menu.addItem(makeMenuItem(title: "Stop Capture", action: #selector(stopManualCapture(_:))))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(title: "Show Settings", action: #selector(showSettings(_:)), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeMenuItem(title: "Quit Stillmatter", action: #selector(quit(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func configureApplicationMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        appMenu.addItem(NSMenuItem(title: "About Stillmatter", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(makeMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Stillmatter", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"))
        appMenu.items.last?.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(makeMenuItem(title: "Show Main Window", action: #selector(showMainWindow(_:))))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(makeMenuItem(title: "Quit Stillmatter", action: #selector(quit(_:)), keyEquivalent: "q"))

        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(responderMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = responderMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(responderMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(responderMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(responderMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(responderMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let navigateMenuItem = NSMenuItem()
        let navigateMenu = NSMenu(title: "Navigate")
        ShellTab.allCases.enumerated().forEach { index, tab in
            let item = makeMenuItem(title: tab.rawValue, action: #selector(selectArea(_:)))
            item.tag = index
            navigateMenu.addItem(item)
        }
        navigateMenu.addItem(NSMenuItem.separator())
        navigateMenu.addItem(makeMenuItem(title: "Focus Search", action: #selector(focusAreaSearch(_:)), keyEquivalent: "f"))
        navigateMenuItem.submenu = navigateMenu
        mainMenu.addItem(navigateMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let sidebarItem = makeMenuItem(title: "Show or Hide Sidebar", action: #selector(toggleSidebar(_:)), keyEquivalent: "s")
        sidebarItem.keyEquivalentModifierMask = [.command, .option]
        viewMenu.addItem(sidebarItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func responderMenuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = nil
        return item
    }

    private func makeMenuItem(title: String, action: Selector, keyEquivalent: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }
}
