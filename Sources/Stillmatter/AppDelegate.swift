import AppKit
import Darwin
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterTranscriptionRuntime
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let stateStore = ShellStateStore()
    private let settingsStore: SettingsStore = {
        guard let fixtureRoot = ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] else {
            return SettingsStore()
        }
        let suiteName = "works.stillmatter.validation"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let store = SettingsStore(userDefaults: defaults)
        var settings = store.settings
        settings.stillmatterRootURL = URL(fileURLWithPath: fixtureRoot, isDirectory: true)
        store.settings = settings
        return store
    }()
    private let lifecyclePolicy = AppLifecyclePolicy()
    private lazy var tasksInbox: TasksInbox? = {
        do {
            return try TasksInbox(databaseURL: Self.operationalDatabaseURL)
        } catch {
            NSLog("Could not open Stillmatter operational store: \(error)")
            return nil
        }
    }()
    private lazy var jobStore: JobStore? = {
        do {
            return try JobStore(databaseURL: Self.operationalDatabaseURL, inbox: tasksInbox)
        } catch {
            NSLog("Could not open Stillmatter job store: \(error)")
            return nil
        }
    }()
    private var searchIndex: SearchIndex?
    private var searchIndexMonitor: SearchIndexFileMonitor?
    private var searchConfigurationKey: String?
    private let indexBuilder = SearchIndexBuilder()
    private var indexGeneration = 0
    private let heavyExecutionGate = JobHeavyExecutionGate()
    private var transcriptionScheduler: JobScheduler?
    private var transcriptionConfigurationKey: String?
    private var meetingSummaryScheduler: JobScheduler?
    private var meetingSummaryConfigurationKey: String?

    private func schedulerForMeetingRetry(_ type: String) -> JobScheduler? {
        switch type {
        case TranscriptionJob.type: return transcriptionScheduler
        case MeetingSummaryJob.type: return meetingSummaryScheduler
        default: return nil
        }
    }
    private lazy var transcriptionComponentInstaller = TranscriptionComponentInstaller(
        paths: TranscriptionComponentPaths(applicationSupportURL: Self.applicationSupportURL),
        acquirer: FasterWhisperModelAcquirer()
    )
    private var transcriptionComponentObserver: UUID?
    private lazy var captureRuntime = CaptureSessionRuntime(
        build: { [settingsStore, weak self] settings in
            CaptureSessionAssembly.makeService(
                settings: settings, settingsStore: settingsStore,
                jobStore: self?.jobStore, inbox: self?.tasksInbox,
                applicationSupportURL: Self.applicationSupportURL
            )
        },
        onSnapshot: { [weak self] snapshot in self?.handleCaptureSnapshot(snapshot) }
    )
    private var captureService: MeetingCaptureService? { captureRuntime.service }
    private lazy var teamsDetectionMonitor = MacTeamsDetectionMonitor()
    private let teamsRecordingPolicy = TeamsRecordingPolicy()
    private var lastTeamsObservation: String?
    private var teamsRecordingDiagnostic = "No capture decision yet"
    private var lastTeamsMode: TeamsRecordingMode?
    private var teamsAskAlert: NSAlert?
    private var mainWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var overdueRefreshTimer: Timer?
    private var weeklyReportTimer: Timer?
    private var titleReviewTimer: Timer?
    private var titleReviewLastPrompt: [String: Date] = [:]
    private var titleReviewIsPresenting = false
    private weak var titleReviewAlert: NSAlert?
    private let dailyBriefQueue = DispatchQueue(label: "Stillmatter.DailyBrief")
    private let weeklyReportQueue = DispatchQueue(label: "Stillmatter.WeeklyReport")
    private var isMeetingOrRecordingActive = false {
        didSet { updateAttentionEnvironment() }
    }
    private var weeklyAttentionID: AttentionTarget?
    private lazy var attention = AppAttentionController(
        inbox: { [weak self] in self?.tasksInbox },
        onPopup: { [weak self] target in self?.presentAttention(target) },
        onOpen: { [weak self] target in self?.openAttention(target) }
    )
    private lazy var weeklyReportPromptWindowController: WeeklyReportPromptWindowController = {
        let controller = WeeklyReportPromptWindowController()
        controller.onAccept = { [weak self] text in
            try self?.weeklyReportPromptCoordinator.accept(editedText: text)
        }
        controller.onRemind = { [weak self] in
            self?.weeklyReportPromptCoordinator.remindNextTime()
        }
        return controller
    }()
    private lazy var weeklyReportPromptCoordinator = WeeklyReportPromptCoordinator(
        onAccept: { [weak self] request in
            guard let self = self else { return }
            try self.acceptWeeklyReport(request)
        },
        onStateChange: { [weak self] state in
            if Thread.isMainThread { self?.handleWeeklyPromptState(state) }
            else { DispatchQueue.main.async { [weak self] in self?.handleWeeklyPromptState(state) } }
        }
    )
    private var quitRequested = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        configureApplicationMenu()
        if ProcessInfo.processInfo.environment["STILLMATTER_SHELL_LAYOUT_HARNESS"] == "1" {
            runShellLayoutHarness()
            return
        }
        configureStatusItem()
        attention.start()
        updateAttentionEnvironment()
        settingsStore.observe { [weak self] settings in
            self?.refreshOverdueInbox(settings: settings)
            self?.configureSearchIndex(settings: settings)
            self?.configureMeetingSummaryScheduler(settings: settings)
            self?.configureTranscriptionScheduler(settings: settings)
            self?.configureCaptureService(settings: settings)
            self?.reconcileTeamsCapture(self?.teamsDetectionMonitor.snapshot)
        }
        transcriptionComponentObserver = transcriptionComponentInstaller.observe { [weak self] state in
            guard case .ready = state else { return }
            self?.configureTranscriptionScheduler(settings: self?.settingsStore.settings ?? AppSettings())
        }
        teamsDetectionMonitor.observe { [weak self] snapshot in
            // The monitor notifies on main. Flush as part of this transition,
            // not one run-loop turn after a confirmed call end.
            self?.reconcileTeamsCapture(snapshot)
            self?.updateAttentionEnvironment()
            if snapshot.isMeetingDetected { self?.dismissTitleReviewForMeeting() }
            else { self?.refreshInboxAttention() }
            self?.stateStore.refresh()
        }
        teamsDetectionMonitor.start()
        scheduleNextOverdueRefresh()
        scheduleWeeklyReportChecks()
        titleReviewTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refreshInboxAttention()
        }
        seedProposalReviewValidationFixtureIfRequested()
        showMainWindow(selecting: .meetings)
        DispatchQueue.main.async { [weak self] in self?.refreshInboxAttention() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        updateAttentionEnvironment()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        let settings = settingsStore.settings
        refreshOverdueInbox(settings: settings)
        generateDailyBriefIfMissing(settings: settings)
        weeklyReportPromptCoordinator.nextPromptOpportunity(
            isMeetingOrRecordingActive: isMeetingOrRecordingActive || teamsDetectionMonitor.snapshot.isMeetingDetected
        )
        checkForWeeklyReport(settings: settings)
        updateAttentionEnvironment()
        DispatchQueue.main.async { [weak self] in self?.refreshInboxAttention() }
    }

    /// Capture/meeting integrations report activity here so required prompts stay deferred.
    func meetingOrRecordingActivityDidChange(isActive: Bool) {
        isMeetingOrRecordingActive = isActive
        if isActive { dismissTitleReviewForMeeting() }
        else { refreshInboxAttention() }
    }

    private func presentAttention(_ target: AttentionTarget) {
        switch target {
        case let .weeklyReport(id):
            if case let .presented(draft) = weeklyReportPromptCoordinator.state, draft.id == id {
                weeklyReportPromptWindowController.present(draft)
            }
        case let .titleReview(id):
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
        case let .weeklyReport(id):
            showMainWindow(selecting: .reports)
            if case let .presented(draft) = weeklyReportPromptCoordinator.state, draft.id == id {
                weeklyReportPromptWindowController.present(draft)
            }
        case let .titleReview(id):
            showMainWindow(selecting: .today)
            (mainWindow?.contentViewController as? ShellViewController)?.focusInboxItem(id: id)
            // The exact row stays visible while the review prompt is suppressed
            // by a Meeting; the required review still flushes after it ends.
            guard let item = try? tasksInbox?.items(category: .required).first(where: { $0.id == id }) else { return }
            offerTitleReview(item: item, explicit: true)
        case let .inboxItem(id):
            showMainWindow(selecting: .today)
            (mainWindow?.contentViewController as? ShellViewController)?.focusInboxItem(id: id)
        case .captureFailure:
            showMainWindow(selecting: .recording)
        }
    }

    private func handleWeeklyPromptState(_ state: WeeklyReportPromptState) {
        switch state {
        case let .presented(draft):
            weeklyAttentionID = .weeklyReport(draft.id)
            attention.offer(AttentionRequest(
                target: .weeklyReport(draft.id), title: "Weekly Report ready for review", kind: .required
            ))
        case .idle:
            clearWeeklyAttention()
            weeklyReportPromptWindowController.dismiss()
            refreshInboxAttention()
        case .deferred:
            weeklyReportPromptWindowController.dismiss()
        }
    }

    private func updateAttentionEnvironment() {
        let meetingActive = isMeetingOrRecordingActive || teamsDetectionMonitor.snapshot.isMeetingDetected
        weeklyReportPromptCoordinator.meetingOrRecordingActivityDidChange(isActive: meetingActive)
        let focusedWindow = NSApp.isActive
            ? (mainWindow?.isVisible == true ? mainWindow : NSApp.keyWindow)
            : nil
        attention.setEnvironment(meetingActive: meetingActive, focusedWindow: focusedWindow)
    }

    private func clearWeeklyAttention() {
        if let target = weeklyAttentionID { attention.clear(target) }
        weeklyAttentionID = nil
    }

    private func refreshInboxAttention() {
        attention.refreshInbox { [weak self] item in
            guard let self = self else { return false }
            return self.weeklyReportPromptCoordinator.state == .idle
                && item.kind == .titleReview
                && Date().timeIntervalSince(self.titleReviewLastPrompt[item.id] ?? .distantPast) >= 3600
        }
    }

    /// Required Inbox reviews are offered from the app, not from a particular tab.
    private func offerTitleReview(item requested: InboxItem? = nil, explicit: Bool = false) {
        guard !titleReviewIsPresenting, NSApp.isActive, mainWindow?.isVisible == true,
              (explicit || weeklyReportPromptCoordinator.state == .idle),
              !isMeetingOrRecordingActive, !teamsDetectionMonitor.snapshot.isMeetingDetected,
              let inbox = tasksInbox, let root = settingsStore.settings.stillmatterRootURL else { return }
        do {
            let pending = try inbox.items(category: .required).filter { $0.kind == .titleReview }
            guard let item = requested == nil ? pending.first : pending.first(where: { $0.id == requested?.id }) else { return }
            guard explicit || Date().timeIntervalSince(titleReviewLastPrompt[item.id] ?? .distantPast) >= 3600 else { return }
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
                guard !isMeetingOrRecordingActive, !teamsDetectionMonitor.snapshot.isMeetingDetected else { return }
                let response = alert.runModal()
                guard !isMeetingOrRecordingActive, !teamsDetectionMonitor.snapshot.isMeetingDetected else { return }
                guard response == .alertFirstButtonReturn else {
                    titleReviewLastPrompt[item.id] = Date()
                    attention.clear(.titleReview(item.id))
                    return
                }
                let title = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else {
                    alert.informativeText = "Enter a title, or choose Later."
                    continue
                }
                do {
                    let vault = WorkspaceVault(workspaceRootURL: root, appSupportRootURL: Self.applicationSupportURL)
                    let newPath = try MeetingTitleReviewService(vault: vault, inbox: inbox, jobStore: jobStore, searchIndex: searchIndex)
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
                    attention.clear(.titleReview(item.id))
                    stateStore.refresh()
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

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        (sender.contentViewController as? ShellViewController)?.prepareForWindowResize(to: frameSize.width)
        return frameSize
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

    private func makeMainWindow() -> NSWindow {
        let shellViewController = ShellViewController(
            stateStore: stateStore,
            settingsStore: settingsStore,
            tasksInbox: tasksInbox,
            searchIndexProvider: { [weak self] in self?.searchIndex },
            captureServiceProvider: { [weak self] in self?.captureService },
            onReviewTitle: { [weak self] item in self?.offerTitleReview(item: item, explicit: true) },
            teamsDetectionProvider: { [weak self] in self?.teamsDetectionMonitor.snapshot },
            teamsRecordingDiagnosticProvider: { [weak self] in self?.teamsRecordingDiagnostic ?? "Capture policy unavailable" },
            onManualCapture: { [weak self] in self?.manualCaptureOverride() },
            contextualAskServiceProvider: { [weak self] in self?.makeContextualAskService() },
            jobRecordsProvider: { [weak self] in self?.currentJobRecords() ?? [] },
            jobStatusProvider: { [weak self] in self?.currentJobStatus() ?? "Jobs unavailable" },
            upcomingMeetingsProvider: { [weak self] in self?.todayMeetings() ?? [] },
            meetingServiceProvider: { [weak self] in
                guard let root = self?.settingsStore.settings.stillmatterRootURL else { return nil }
                return MeetingManagementService(
                    vault: WorkspaceVault(workspaceRootURL: root, appSupportRootURL: Self.applicationSupportURL),
                    jobStore: self?.jobStore,
                    inbox: self?.tasksInbox,
                    searchIndex: self?.searchIndex,
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
                    onReprocessQueued: { [weak self] in self?.transcriptionScheduler?.start() }
                )
            },
            transcriptionComponentInstaller: transcriptionComponentInstaller,
            onRebuildIndex: { [weak self] completion in
                guard let self else { completion(.failure(NSError(domain: "Stillmatter.SearchIndex", code: 1))); return }
                self.recoverAndRebuildSearchIndex(completion: completion)
            }
        )
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1_200, height: 760)
        let initialContentSize = NSSize(
            width: floor(visibleFrame.width * 0.8),
            height: floor(visibleFrame.height * 0.8)
        )
        let minimumContentSize = NSSize(
            width: min(1_000, initialContentSize.width),
            height: min(650, initialContentSize.height)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stillmatter"
        window.contentViewController = shellViewController
        window.contentMinSize = minimumContentSize
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

    private func configureCaptureService(settings: AppSettings) {
        if captureRuntime.configure(settings) { stateStore.refresh() }
    }

    private func handleCaptureSnapshot(_ snapshot: CaptureSnapshot) {
        let isActive = snapshot.state == .starting
            || snapshot.state == .recording
            || snapshot.state == .stopping
            || snapshot.state == .finalizing
        let apply = { [weak self] in
            guard let self else { return }
            self.meetingOrRecordingActivityDidChange(isActive: isActive)
            if snapshot.state == .failed {
                self.attention.offer(AttentionRequest(
                    target: .captureFailure(snapshot.meetingRelativePath ?? "failure"),
                    title: "Recording needs attention", kind: .recordingCritical
                ))
            }
            self.statusItem?.button?.title = snapshot.state == .recording ? "Stillmatter ●" : "Stillmatter"
            self.statusItem?.button?.toolTip = snapshot.state == .recording
                ? "Recording \(snapshot.meetingTitle ?? "Meeting")"
                : "Stillmatter is available. Open the window or quit explicitly."
            if snapshot.state == .idle { self.transcriptionScheduler?.start() }
            self.stateStore.refresh()
        }
        if Thread.isMainThread { apply() }
        else { DispatchQueue.main.async(execute: apply) }
    }

    private func reconcileTeamsCapture(_ detection: TeamsDetectionSnapshot?) {
        guard let detection = detection else { return }
        if detection.diagnosticSummary != lastTeamsObservation {
            lastTeamsObservation = detection.diagnosticSummary
            NSLog("Teams detection: \(detection.diagnosticSummary)")
        }
        let mode = settingsStore.settings.teamsRecordingMode
        if !detection.isMeetingDetected || (lastTeamsMode != nil && lastTeamsMode != mode) {
            if let alert = teamsAskAlert {
                teamsAskAlert = nil
                alert.window.sheetParent?.endSheet(alert.window)
            }
        }
        if lastTeamsMode != nil && lastTeamsMode != mode {
            // Do not let an outstanding Ask response consent under a different setting.
            _ = teamsRecordingPolicy.answerAsk(accepted: false, captureState: captureService?.snapshot.state ?? .idle)
        }
        lastTeamsMode = mode
        let action = teamsRecordingPolicy.observe(
            detection, mode: mode, captureState: captureService?.snapshot.state ?? .idle
        )
        performTeamsCapture(action, detection: detection)
    }

    private func performTeamsCapture(_ action: TeamsRecordingAction, detection: TeamsDetectionSnapshot) {
        guard action != .none else { return }
        teamsRecordingDiagnostic = "\(action) — \(detection.diagnosticSummary)"
        NSLog("Teams capture decision: \(teamsRecordingDiagnostic)")
        stateStore.refresh()
        switch action {
        case .none: break
        case .ask:
            showMainWindow(selecting: .recording)
            guard let window = mainWindow else { return }
            let alert = NSAlert()
            alert.messageText = "Record this Teams meeting?"
            alert.informativeText = "A native Teams call was detected. Capture preflight will run before creating a Meeting."
            alert.addButton(withTitle: "Start Recording")
            alert.addButton(withTitle: "Not Now")
            teamsAskAlert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self = self else { return }
                self.teamsAskAlert = nil
                let current = self.teamsDetectionMonitor.snapshot
                // Reconcile the latest observation before applying a potentially stale response.
                if !current.isMeetingDetected || self.settingsStore.settings.teamsRecordingMode != .ask {
                    _ = self.teamsRecordingPolicy.answerAsk(accepted: false, captureState: self.captureService?.snapshot.state ?? .idle)
                    return
                }
                let consent = self.teamsRecordingPolicy.answerAsk(
                    accepted: response == .alertFirstButtonReturn,
                    captureState: self.captureService?.snapshot.state ?? .idle
                )
                self.performTeamsCapture(consent, detection: current)
            }
        case .start:
            guard let service = captureService else {
                teamsRecordingPolicy.recordStartFailed()
                teamsRecordingDiagnostic = "Cannot start: configure the Stillmatter root and recording media in Settings"
                NSLog("Teams capture: \(teamsRecordingDiagnostic)")
                return
            }
            do {
                _ = try service.startManual()
                teamsRecordingPolicy.recordStartSucceeded()
                teamsRecordingDiagnostic = "Started automatic/approved Teams recording"
                NSLog("Teams capture: \(teamsRecordingDiagnostic)")
            } catch {
                teamsRecordingPolicy.recordStartFailed()
                teamsRecordingDiagnostic = "Start failed: \(error) — check recording Settings and preflight"
                NSLog("Teams capture: \(teamsRecordingDiagnostic)")
                NSApp.requestUserAttention(.criticalRequest)
            }
        case .stop:
            guard let service = captureService, service.snapshot.state == .recording else { return }
            service.stopManualAsync { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    self.teamsRecordingDiagnostic = "Stopped policy-owned Teams recording after confirmed call end"
                case let .failure(error):
                    self.teamsRecordingDiagnostic = "Stop failed: \(error) — inspect recording artifacts and retry manually"
                    NSApp.requestUserAttention(.criticalRequest)
                }
                NSLog("Teams capture: \(self.teamsRecordingDiagnostic)")
                self.stateStore.refresh()
            }
        }
        stateStore.refresh()
    }

    private func configureTranscriptionScheduler(settings: AppSettings) {
        guard let rootURL = settings.stillmatterRootURL, let jobStore = jobStore else {
            transcriptionScheduler?.pause()
            transcriptionScheduler = nil
            transcriptionConfigurationKey = nil
            return
        }
        let environment = ProcessInfo.processInfo.environment
        let engine: TranscriptionEngine
        let engineKey: String
        if let cli = TranscriptionComponentPaths.developerCLIConfiguration(
            environment: environment,
            applicationSupportURL: Self.applicationSupportURL
        ) {
            engine = WhisperCLITranscriptionEngine(executableURL: cli.executableURL, modelURL: cli.modelURL)
            engineKey = "cli\n\(cli.executableURL.path)\n\(cli.modelURL.path)"
        } else if let modelURL = transcriptionComponentInstaller.installedModelURL(),
                  let modelChoice = transcriptionComponentInstaller.installedModelChoice(),
                  TranscriptionModelCompatibility.isSupported(
                    modelChoice,
                    hardwareModel: FasterWhisperRuntimeSupport.deviceName()
                  ) {
            engine = FasterWhisperTranscriptionEngine(componentURL: modelURL, modelIdentifier: modelChoice.variant)
            engineKey = "faster-whisper\n\(modelURL.path)"
        } else {
            transcriptionScheduler?.pause()
            transcriptionScheduler = nil
            transcriptionConfigurationKey = nil
            return
        }
        let key = [
            rootURL.standardizedFileURL.path,
            engineKey,
            searchIndex == nil ? "<no-index>" : "index-generation:\(indexGeneration)"
        ].joined(separator: "\n")
        guard key != transcriptionConfigurationKey else { return }

        let pipeline = TranscriptionPipeline(
            workspaceRootURL: rootURL,
            bundleValidator: RecordingBundleFinalizer(),
            engine: engine,
            searchIndex: searchIndex
        )
        let scheduler = JobScheduler(
            store: jobStore,
            executor: TranscriptionJobExecutor(
                pipeline: pipeline,
                onTranscriptGenerated: { [weak self] transcriptionJob, artifacts in
                    try self?.enqueueMeetingSummary(after: transcriptionJob, artifacts: artifacts)
                }
            ),
            eligibleJobTypes: [TranscriptionJob.type],
            heavyExecutionGate: heavyExecutionGate,
            onWorkQueuedWhilePaused: { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    self?.transcriptionScheduler?.start()
                }
            }
        )
        transcriptionScheduler?.pause()
        transcriptionScheduler = scheduler
        transcriptionConfigurationKey = key
        scheduler.start()
    }

    private func configureMeetingSummaryScheduler(settings: AppSettings) {
        guard let rootURL = settings.stillmatterRootURL,
              let jobStore = jobStore,
              let tasksInbox = tasksInbox,
              let executableURL = PiIntegration().detectedExecutableURL() else {
            meetingSummaryScheduler?.pause()
            meetingSummaryScheduler = nil
            meetingSummaryConfigurationKey = nil
            return
        }
        let key = rootURL.standardizedFileURL.path + "\n" + executableURL.standardizedFileURL.path
        guard key != meetingSummaryConfigurationKey else { return }

        let worker = PiCodexWorker(executableURL: executableURL, vaultRootURL: rootURL)
        let executor = MeetingSummaryJobExecutor(
            worker: worker,
            workspaceRootURL: rootURL,
            vault: WorkspaceVault(
                workspaceRootURL: rootURL,
                appSupportRootURL: Self.applicationSupportURL
            ),
            inbox: tasksInbox,
            onApplied: { [weak self] in
                DispatchQueue.main.async { [weak self] in self?.stateStore.refresh() }
            }
        )
        let scheduler = JobScheduler(
            store: jobStore,
            executor: executor,
            eligibleJobTypes: [MeetingSummaryJob.type],
            heavyExecutionGate: heavyExecutionGate
        )
        meetingSummaryScheduler?.pause()
        meetingSummaryScheduler = scheduler
        meetingSummaryConfigurationKey = key
        scheduler.start()
    }

    private func enqueueMeetingSummary(after transcriptionJob: JobRecord, artifacts: TranscriptionArtifacts) throws {
        guard let jobStore = jobStore else { return }
        let summaryJobID = "meeting-summary:\(transcriptionJob.id)"
        guard try jobStore.job(id: summaryJobID) == nil else { return }
        let manifest = try MeetingSummaryJob.manifest(
            transcript: artifacts.document,
            transcriptJSONRelativePath: artifacts.jsonRelativePath
        )
        _ = try jobStore.enqueue(id: summaryJobID, manifest: manifest)
        meetingSummaryScheduler?.start()
    }

    private func makeContextualAskService() -> ContextualAskService? {
        guard let searchIndex = searchIndex,
              let executableURL = PiIntegration().detectedExecutableURL() else { return nil }
        return ContextualAskService(
            searchIndex: searchIndex,
            runner: PiContextualAskRunner(executableURL: executableURL)
        )
    }

    private func configureSearchIndex(settings: AppSettings) {
        guard let rootURL = settings.stillmatterRootURL else {
            indexGeneration += 1
            searchIndexMonitor?.stop()
            searchIndexMonitor = nil
            searchIndex = nil
            searchConfigurationKey = nil
            return
        }
        let excludedPatterns = searchExcludedPatterns(settings: settings, rootURL: rootURL)
        let configurationKey = ([rootURL.standardizedFileURL.path] + excludedPatterns.sorted()).joined(separator: "\n")
        guard configurationKey != searchConfigurationKey else { return }
        startIndexBuild(rootURL: rootURL, excludedPatterns: excludedPatterns, configurationKey: configurationKey, recovering: false)
    }

    private func recoverAndRebuildSearchIndex(completion: @escaping (Result<Void, Error>) -> Void) {
        let settings = settingsStore.settings
        guard let rootURL = settings.stillmatterRootURL else {
            completion(.failure(NSError(domain: "Stillmatter.SearchIndex", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an Stillmatter root first."])))
            return
        }
        let excludedPatterns = searchExcludedPatterns(settings: settings, rootURL: rootURL)
        let key = ([rootURL.standardizedFileURL.path] + excludedPatterns.sorted()).joined(separator: "\n")
        startIndexBuild(rootURL: rootURL, excludedPatterns: excludedPatterns, configurationKey: key, recovering: true, completion: completion)
    }

    private func startIndexBuild(rootURL: URL, excludedPatterns: [String], configurationKey: String, recovering: Bool, completion: ((Result<Void, Error>) -> Void)? = nil) {
        indexGeneration += 1
        let generation = indexGeneration
        searchIndexMonitor?.stop()
        searchIndexMonitor = nil
        searchIndex = nil
        searchConfigurationKey = configurationKey
        stateStore.refresh()
        Task.detached(priority: .utility) { [weak self, indexBuilder] in
            let result: Result<SearchIndex, Error>
            do {
                result = .success(try await indexBuilder.build(
                    databaseURL: Self.searchDatabaseURL,
                    rootURL: rootURL,
                    excludedPatterns: excludedPatterns,
                    recovering: recovering
                ))
            } catch {
                result = .failure(error)
            }
            guard let delegate = self else {
                await MainActor.run {
                    completion?(.failure(NSError(domain: "Stillmatter.SearchIndex", code: 2, userInfo: [NSLocalizedDescriptionKey: "Index build interrupted."])))
                }
                return
            }
            await MainActor.run {
                guard delegate.indexGeneration == generation else {
                    completion?(.failure(NSError(domain: "Stillmatter.SearchIndex", code: 2, userInfo: [NSLocalizedDescriptionKey: "Index build superseded by newer settings."])))
                    return
                }
                switch result {
                case let .success(index):
                    let monitor = SearchIndexFileMonitor(rootURL: rootURL, index: index)
                    monitor.start()
                    delegate.searchIndex = index
                    delegate.searchIndexMonitor = monitor
                    delegate.configureTranscriptionScheduler(settings: delegate.settingsStore.settings)
                    completion?(.success(()))
                case let .failure(error):
                    delegate.searchConfigurationKey = nil
                    NSLog("Could not build Stillmatter search index: \(error)")
                    completion?(.failure(error))
                }
                delegate.stateStore.refresh()
            }
        }
    }

    private func searchExcludedPatterns(settings: AppSettings, rootURL: URL) -> [String] {
        var patterns = settings.searchExcludedPatterns
        if let mediaURL = settings.recordingMediaURL,
           let relativeMediaPath = Self.relativePath(of: mediaURL, inside: rootURL) {
            patterns.append(relativeMediaPath + "/**")
        }
        return patterns
    }

    private func refreshOverdueInbox(settings: AppSettings) {
        guard let tasksInbox = tasksInbox, let rootURL = settings.stillmatterRootURL else { return }
        do {
            let todos = try TodoItemIndex(workspaceRootURL: rootURL).loadAllItems()
            try tasksInbox.syncOverdueTodos(todos, today: Self.todoDateFormatter.string(from: Date()))
            stateStore.refresh()
            DispatchQueue.main.async { [weak self] in self?.refreshInboxAttention() }
        } catch {
            NSLog("Could not refresh overdue Inbox items: \(error)")
        }
    }

    private func currentJobRecords() -> [JobRecord]? {
        guard let jobStore = jobStore else { return nil }
        let supportedTypes = Set([TranscriptionJob.type, MeetingSummaryJob.type])
        return try? jobStore.jobs().filter { supportedTypes.contains($0.manifest.type) }
    }

    private func currentJobStatus() -> String {
        guard let jobs = currentJobRecords() else { return "Jobs unavailable" }
        let failed = jobs.filter { $0.status == .failed }.count
        if failed > 0 { return "\(failed) Job\(failed == 1 ? "" : "s") failed" }
        let running = jobs.filter { $0.status == .running }.count
        if running > 0 { return "\(running) Job\(running == 1 ? "" : "s") running" }
        let queued = jobs.filter { $0.status == .queued }.count
        if queued > 0 { return "\(queued) Job\(queued == 1 ? "" : "s") queued" }
        return "Jobs idle"
    }

    private func todayMeetings() -> [TodayMeeting] {
        CalendarMeetingProvider(
            calendarSelection: settingsStore.settings.calendarSourceSelection
        ).meetingsToday().map { TodayMeeting(title: $0.title, time: $0.time) }
    }

    private func generateDailyBriefIfMissing(settings: AppSettings) {
        guard let tasksInbox = tasksInbox, let rootURL = settings.stillmatterRootURL else { return }
        dailyBriefQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let vault = WorkspaceVault(
                    workspaceRootURL: rootURL,
                    appSupportRootURL: Self.applicationSupportURL
                )
                let service = DailyBriefService(
                    workspaceRootURL: rootURL,
                    vault: vault,
                    inbox: tasksInbox,
                    meetings: {
                        CalendarMeetingProvider(
                            calendarSelection: settings.calendarSourceSelection
                        ).meetingsToday()
                    }
                )
                if case .generated = try service.handleAppFocus() {
                    DispatchQueue.main.async { [weak self] in self?.stateStore.refresh() }
                }
            } catch {
                NSLog("Could not generate today's Daily Brief: \(error)")
            }
        }
    }

    private func checkForWeeklyReport(settings: AppSettings) {
        guard let tasksInbox = tasksInbox, let rootURL = settings.stillmatterRootURL else { return }
        weeklyReportQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let service = WeeklyReportService(
                    workspaceRootURL: rootURL,
                    vault: WorkspaceVault(
                        workspaceRootURL: rootURL,
                        appSupportRootURL: Self.applicationSupportURL
                    ),
                    inbox: tasksInbox
                )
                if case let .ready(draft) = try service.check(
                    at: Date(),
                    workingHours: settings.workingHours
                ) {
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self else { return }
                        self.weeklyReportPromptCoordinator.offer(
                            draft,
                            isMeetingOrRecordingActive: self.isMeetingOrRecordingActive
                        )
                        self.stateStore.refresh()
                    }
                }
            } catch {
                NSLog("Could not generate Weekly Report draft: \(error)")
            }
        }
    }

    private func acceptWeeklyReport(_ request: WeeklyReportAcceptanceRequest) throws {
        guard let rootURL = settingsStore.settings.stillmatterRootURL else {
            throw NSError(
                domain: "Stillmatter.WeeklyReport",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Choose an Stillmatter root before saving the report."]
            )
        }
        guard let tasksInbox = tasksInbox else {
            throw NSError(
                domain: "Stillmatter.WeeklyReport",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "The Stillmatter Inbox is unavailable."]
            )
        }
        let service = WeeklyReportService(
            workspaceRootURL: rootURL,
            vault: WorkspaceVault(
                workspaceRootURL: rootURL,
                appSupportRootURL: Self.applicationSupportURL
            ),
            inbox: tasksInbox
        )
        try service.accept(request)
        stateStore.refresh()
    }

    private func scheduleWeeklyReportChecks() {
        weeklyReportTimer?.invalidate()
        checkForWeeklyReport(settings: settingsStore.settings)
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.checkForWeeklyReport(settings: self.settingsStore.settings)
        }
        RunLoop.main.add(timer, forMode: .common)
        weeklyReportTimer = timer
    }

    private func scheduleNextOverdueRefresh() {
        overdueRefreshTimer?.invalidate()
        let calendar = Calendar.current
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())) else { return }
        let timer = Timer(fire: nextDay, interval: 0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.refreshOverdueInbox(settings: self.settingsStore.settings)
            self.scheduleNextOverdueRefresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        overdueRefreshTimer = timer
    }

    private func seedProposalReviewValidationFixtureIfRequested() {
        guard ProcessInfo.processInfo.environment["STILLMATTER_PROPOSAL_REVIEW_FIXTURE"] == "1",
              let inbox = tasksInbox else { return }
        let proposals = [
            ("validation:accept", "Send the launch recap #ai-proposed", "[[Meetings/validation-launch/summary#My action items|source]]"),
            ("validation:reference", "Alex owns the deployment checklist #ai-proposed", "[[Meetings/validation-launch/summary#Other action items|source]]"),
            ("validation:dismiss", "Duplicate reminder that should be dismissed #ai-proposed", "[[Meetings/validation-launch/summary#My action items|source]]"),
            ("validation:merge-a", "Ask the vendor for revised pricing #ai-proposed", "[[Meetings/validation-vendor/summary#Pricing|source]]"),
            ("validation:merge-b", "Confirm the vendor security review #ai-proposed", "[[Meetings/validation-vendor/summary#Security review|source]]"),
            ("validation:retry", "Exercise the failed review retry path #ai-proposed", "[[Meetings/2026/Quarterly Planning/Extremely Long Durable Source Path/summary#My action items|source]]")
        ]
        do {
            for proposal in proposals {
                _ = try inbox.queueProposal(id: proposal.0, title: proposal.1, sourceRef: proposal.2)
            }
        } catch {
            NSLog("Could not seed proposal review validation fixture: \(error)")
        }
    }

    private static let applicationSupportURL: URL = {
        if let override = ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stillmatter", isDirectory: true)
    }()

    private static let operationalDatabaseURL = applicationSupportURL.appendingPathComponent("operational.sqlite")
    private static let searchDatabaseURL = applicationSupportURL.appendingPathComponent("search.sqlite")

    private static func relativePath(of childURL: URL, inside rootURL: URL) -> String? {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let child = childURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard child.hasPrefix(prefix) else { return nil }
        return String(child.dropFirst(prefix.count))
    }

    private static let todoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func runShellLayoutHarness() {
        let window = makeMainWindow()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self = self,
                  let window = window,
                  let shell = window.contentViewController as? ShellViewController else {
                fatalError("Could not create the whole-window shell fixture")
            }
            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            precondition(
                visibleFrame.width == 0 || window.contentLayoutRect.width >= visibleFrame.width * 0.78,
                "Initial main window must occupy about 80% of the screen width"
            )
            precondition(
                window.contentMinSize.width >= min(1_000, window.contentLayoutRect.width)
                    && window.contentMinSize.height >= min(650, window.contentLayoutRect.height),
                "Main window minimum must retain a substantial working canvas"
            )
            shell.validateReferenceShellLayout()
            shell.validateAdaptiveShellLayout(in: window)
            shell.validateTabScrolling(in: window)
            if ProcessInfo.processInfo.environment["STILLMATTER_TAB_SCROLL_HARNESS"] == "1" {
                print("Tab scroll range and switch position passed.")
                fflush(stdout)
                Darwin.exit(EXIT_SUCCESS)
            }
            let actions = self.menuActions(in: NSApp.mainMenu)
            [
                #selector(self.focusAreaSearch(_:)),
                #selector(self.toggleSidebar(_:)),
                #selector(self.showSettings(_:))
            ].forEach { action in
                precondition(actions.contains(NSStringFromSelector(action)), "Menu parity is missing \(NSStringFromSelector(action))")
            }
            shell.validateSearchKeyboardFocus(in: window) {
                shell.validateSearchKeyboardFocus(in: window, width: 1200) {
                    print("Adaptive shell layout and search keyboard focus passed at 720×520, 1200×760, and 1440×760.")
                    fflush(stdout)
                    Darwin.exit(EXIT_SUCCESS)
                }
            }
        }
    }

    private func menuActions(in menu: NSMenu?) -> Set<String> {
        guard let menu = menu else { return [] }
        return menu.items.reduce(into: Set<String>()) { result, item in
            if let action = item.action {
                result.insert(NSStringFromSelector(action))
            }
            result.formUnion(menuActions(in: item.submenu))
        }
    }

    private func manualCaptureOverride() {
        teamsRecordingPolicy.manualOverride()
        if let alert = teamsAskAlert {
            teamsAskAlert = nil
            alert.window.sheetParent?.endSheet(alert.window)
        }
        teamsRecordingDiagnostic = "Manual capture override; detection will not control this call"
        NSLog("Teams capture: \(teamsRecordingDiagnostic)")
    }

    @objc private func startManualCapture(_ sender: Any?) {
        showMainWindow(selecting: .recording)
        guard let service = captureService,
              [.idle, .failed, .recovered, .detecting].contains(service.snapshot.state) else { return }
        manualCaptureOverride()
        do { _ = try service.startManual() }
        catch { NSLog("Manual capture start failed: \(error)") }
        stateStore.refresh()
    }

    @objc private func stopManualCapture(_ sender: Any?) {
        guard let service = captureService, service.snapshot.state == .recording else { return }
        manualCaptureOverride()
        service.stopManualAsync { [weak self] result in
            if case let .failure(error) = result {
                NSLog("Manual capture stop failed: \(error)")
                NSApp.requestUserAttention(.criticalRequest)
            }
            self?.stateStore.refresh()
        }
        stateStore.refresh()
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
        navigateMenu.addItem(makeMenuItem(title: "Focus Area Search", action: #selector(focusAreaSearch(_:)), keyEquivalent: "f"))
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
