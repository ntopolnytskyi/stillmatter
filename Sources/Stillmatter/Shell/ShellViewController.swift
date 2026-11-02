import AppKit
import EventKit
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

final class ShellViewController: NSViewController, NSSplitViewDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSPopoverDelegate {
    // Module-internal native controls/state support the owner-approved validation extensions.
    let stateStore: ShellStateStore
    let settingsStore: SettingsStore
    private let tasksInbox: TasksInbox?
    var searchIndexProvider: () -> SearchIndex?
    private let captureServiceProvider: () -> MeetingCaptureService?
    private let meetingServiceProvider: () -> MeetingManagementService?
    let meetingReadModelProvider: () -> MeetingReadModel?
    private let meetingMutationExecutorProvider: () -> MeetingMutationExecuting?
    private let meetingPlaybackTransportProvider: () -> MeetingPlaybackTransport?
    private let meetingPresentationMetrics: MeetingPresentationMetrics?
    private let onReviewTitle: (InboxItem) -> Void
    private let teamsDetectionProvider: () -> TeamsDetectionSnapshot?
    private let teamsRecordingDiagnosticProvider: () -> String
    private let onManualCapture: () -> Void
    private let jobRecordsProvider: () -> [JobRecord]
    private let jobStatusProvider: () -> String
    let settingsFormView: SettingsFormView
    let splitView = NSSplitView()
    let workspaceSplitView = NSSplitView()
    private var workspaceContainer = NSView()
    let sidebarContainer = NSView()
    let contentListContainer = NSView()
    private var fixedListWidth: NSLayoutConstraint?
    let inspectorContainer = NSView()
    var detailContainer = NSView()
    var contentScrollView: NSScrollView?
    private var meetingViewportHeight: NSLayoutConstraint?
    private var contentBottomConstraints: [(view: NSView, constraint: NSLayoutConstraint)] = []
    let aboutButton = DoubleClickAboutButton(image: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage,
        target: NSApp, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    var navigationButtons: [ShellTab: NSButton] = [:]
    let sidebarTabs: [ShellTab] = [.today, .recording, .meetings, .tasks, .settings]
    let contentTitle = NSTextField(labelWithString: "")
    private let recordingBadge = GraphiteFocusStatusLabel()
    let jobBadge = GraphiteFocusStatusLabel()
    let jobProgress = GraphiteFocusProgressStatusView()
    let jobPresentationContainer = NSView()
    lazy var captureRecordingView = CaptureRecordingView(
        serviceProvider: captureServiceProvider,
        rootURLProvider: { [weak self] in self?.settingsStore.settings.stillmatterRootURL },
        teamsDetectionProvider: teamsDetectionProvider,
        teamsRecordingDiagnosticProvider: teamsRecordingDiagnosticProvider,
        onManualCapture: onManualCapture,
        jobRecordsProvider: jobRecordsProvider,
        onOpenSettings: { [weak self] in self?.stateStore.state.select(.settings) }
    )
    lazy var meetingManagementView: MeetingManagementView = {
        let workspace = MeetingManagementView(
            readModelProvider: meetingReadModelProvider,
            mutationExecutorProvider: meetingMutationExecutorProvider,
            playbackTransportProvider: meetingPlaybackTransportProvider,
            openRecording: { [weak self] in self?.stateStore.state.select(.recording) },
            openWorkspaceFile: { [weak self] path in self?.openWorkspaceFile(path) },
            presentationMetrics: meetingPresentationMetrics
        )
        workspace.setOnOpenSelection { [weak self] in
            guard let self, self.stateStore.state.selectedTab == .meetings else { return }
            self.showingNarrowDetail = true
            self.applyAdaptiveLayout()
        }
        return workspace
    }()
    #if DEBUG
    var task05MeetingView: MeetingManagementView { meetingManagementView }
    #endif
    var hasDirtyMeetingDraftForWorkspaceChange: Bool {
        meetingManagementView.hasDirtyWorkspaceDraftForPreparation
    }

    func prepareMeetingWorkspaceChange(completion: @escaping (Bool) -> Void) {
        meetingManagementView.prepareWorkspaceChange(completion: completion)
    }

    lazy var todayWorkbenchView: TodayWorkbenchView = TodayWorkbenchView(
        stateProvider: { [weak self] in self?.todayLoader.state ?? .unavailable("Today is unavailable.") },
        onRetry: { [weak self] in self?.reloadToday() },
        onSelectArea: { [weak self] tab in self?.stateStore.state.select(tab) },
        onReviewProposals: { [weak self] item in self?.openTodayProposal(item) },
        onOpenDecision: { [weak self] item in self?.openTodayDecision(item) },
        onOpenMeeting: { [weak self] meeting, owner in self?.openTodayMeeting(meeting, owner: owner) },
        onOpenTodo: { [weak self] item, owner in self?.openTodayTodo(item, owner: owner) },
        onReviewTitle: { [weak self] item in self?.openTodayTitle(item) }
    )
    lazy var proposalReviewView = ProposalReviewView(
        settingsStore: settingsStore,
        inbox: tasksInbox,
        onChange: { [weak self] in
            self?.stateStore.publish(.tasks)
            self?.meetingReadModelProvider()?.forceRescan()
        }
    )
    lazy var todoLedgerView: TodoLedgerView = TodoLedgerView(
        completion: TodoCompletion(appSupportRoot: AppDelegate.applicationSupportURL, workspaceRoot: { [weak self] in self?.settingsStore.settings.stillmatterRootURL }),
        onChange: { [weak self] in self?.stateStore.publish(.tasks) },
        stateProvider: { [weak self] in self?.todoLoader.state ?? .unavailable("Tasks are unavailable.") },
        onRetry: { [weak self] in self?.reloadTodos() },
        onOpenItem: { [weak self] item in self?.openTodoItem(item) },
        onOpenSettings: { [weak self] in self?.stateStore.state.select(.settings) }
    )
    lazy var searchResultsView = SearchResultsView(
        onOpenResult: { [weak self] result in self?.openWorkspaceFile(result.sourcePath) },
        onOpenSettings: { [weak self] in self?.stateStore.state.select(.settings) },
        onRetry: { [weak self] in self?.lastSearchRequest = nil; self?.updateSearchPresentation() },
        onDismiss: { [weak self] in self?.dismissSearch() }
    )
    let searchField = NSSearchField()
    let compactSearchField = NSSearchField()
    let compactSearchKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let compactSearchScopeLabel = NSTextField(labelWithString: "")
    let compactSearchPopover = NSPopover()
    private var transferFocusToResultsOnPopoverClose = false
    let searchKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let toolbarAreaLabel = NSTextField(labelWithString: "Today")
    let narrowBackButton = NSButton(title: "Back", target: nil, action: nil)
    let toolbar = NSToolbar(identifier: "Stillmatter.MainToolbar.v3")
    var hasContentListRegion = false
    var hasInspectorRegion = false
    #if DEBUG || STILLMATTER_NATIVE_PROBES
    var usesAdaptiveFixtureRegions = false
    #endif
    var showingNarrowDetail = false
    private var lastRenderedTab: ShellTab?
    private var lastVisibility: (tab: ShellTab, searching: Bool)?
    private var pendingInboxFocusID: String?
    private var pendingTodayTodo: (item: TodoItem, owner: String)?
    private var shellObservation: ShellObservation?
    private var statusObservation: ShellObservation?
    private var settingsObservation: UUID?
    private lazy var todayLoader = TodayWorkbenchLoader { [weak self] in
        guard let self, self.stateStore.state.selectedTab == .today, !self.todayWorkbenchView.isHidden else { return }
        self.todayWorkbenchView.refresh(isVisible: true)
        if let id = self.pendingInboxFocusID {
            self.pendingInboxFocusID = nil
            if !self.todayWorkbenchView.focusInboxItem(id: id) {
                self.todayWorkbenchView.showUnavailableInboxItem(id: id)
            }
        }
    }
    private lazy var todoLoader = TodoLedgerLoader { [weak self] in
        guard let self, self.stateStore.state.selectedTab == .tasks, !self.todoLedgerView.isHidden else { return }
        self.didLoadTodos()
    }

    private func didLoadTodos() {
        todoLedgerView.refresh(isVisible: true)
        if let pending = pendingTodayTodo, case .loaded = todoLoader.state {
            pendingTodayTodo = nil
            guard currentTodayOwner(pending.owner),
                  todoLedgerView.focusCanonicalItem(pending.item, selectedOwner: pending.owner,
                      owner: pending.owner) else {
                stateStore.state.select(.today)
                todayWorkbenchView.showUnavailableInboxItem(id: pending.item.id)
                return
            }
        }
    }
    var isSearchPresented = false
    private var pendingSearch: Task<Void, Never>?
    private var searchRevision = 0
    var searchRunner: (SearchIndex, String, SearchFilter) throws -> [SearchResult] = {
        try $0.search($1, filter: $2, limit: 100)
    }
    private var lastSearchRequest: String?
    private var requestedWindowWidth: CGFloat?
    private var isApplyingAdaptiveLayout = false
    private var toolbarItemsCompactedForWidth: [(identifier: NSToolbarItem.Identifier, index: Int)] = []
    var lastAdaptiveLayout: AdaptiveShellLayout?
    var sidebarPreferredVisible = UserDefaults.standard.object(forKey: "Stillmatter.SidebarVisible") as? Bool ?? true
    var inspectorPreferredVisible = UserDefaults.standard.object(forKey: "Stillmatter.InspectorVisible") as? Bool ?? false
    private var presentationObservers: [NSObjectProtocol] = []

    init(
        stateStore: ShellStateStore,
        settingsStore: SettingsStore,
        tasksInbox: TasksInbox?,
        searchIndexProvider: @escaping () -> SearchIndex?,
        captureServiceProvider: @escaping () -> MeetingCaptureService?,
        onReviewTitle: @escaping (InboxItem) -> Void = { _ in },
        teamsDetectionProvider: @escaping () -> TeamsDetectionSnapshot?,
        teamsRecordingDiagnosticProvider: @escaping () -> String,
        onManualCapture: @escaping () -> Void,
        jobRecordsProvider: @escaping () -> [JobRecord],
        jobStatusProvider: @escaping () -> String,
        meetingServiceProvider: @escaping () -> MeetingManagementService? = { nil },
        meetingReadModelProvider: @escaping () -> MeetingReadModel? = { nil },
        meetingMutationExecutorProvider: @escaping () -> MeetingMutationExecuting? = { nil },
        meetingPlaybackTransportProvider: @escaping () -> MeetingPlaybackTransport? = { nil },
        transcriptionComponentInstaller: TranscriptionComponentInstaller,
        onRebuildIndex: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void,
        onRetryPendingWorkspace: @escaping () -> Void = {},
        meetingPresentationMetrics: MeetingPresentationMetrics? = nil
    ) {
        self.stateStore = stateStore
        self.settingsStore = settingsStore
        self.tasksInbox = tasksInbox
        self.searchIndexProvider = searchIndexProvider
        self.captureServiceProvider = captureServiceProvider
        self.meetingServiceProvider = meetingServiceProvider
        self.meetingReadModelProvider = meetingReadModelProvider
        self.meetingMutationExecutorProvider = meetingMutationExecutorProvider
        self.meetingPlaybackTransportProvider = meetingPlaybackTransportProvider
        self.meetingPresentationMetrics = meetingPresentationMetrics
        self.onReviewTitle = onReviewTitle
        self.teamsDetectionProvider = teamsDetectionProvider
        self.teamsRecordingDiagnosticProvider = teamsRecordingDiagnosticProvider
        self.onManualCapture = onManualCapture
        self.jobRecordsProvider = jobRecordsProvider
        self.jobStatusProvider = jobStatusProvider
        self.settingsFormView = SettingsFormView(
            settingsStore: settingsStore,
            transcriptionComponentInstaller: transcriptionComponentInstaller,
            onRebuildIndex: onRebuildIndex,
            onRetryPendingWorkspace: onRetryPendingWorkspace
        )
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        GraphiteFocusPresentation.applyDarkAppearance(to: view)
        buildLayout()
        observePresentationChanges()
        applyPresentation()
        shellObservation = stateStore.observe([.navigation, .search, .tasks, .meetings,
                                               .workspace, .searchIndex], initial: .navigation) { [weak self] change in
            self?.receive(change)
        }
        statusObservation = stateStore.observe([.recordingStatus, .jobStatus, .teamsStatus]) { [weak self] change in
            self?.receive(change)
        }
        var lastSettings: AppSettings?
        settingsObservation = settingsStore.observeScoped { [weak self] settings in
            guard lastSettings != settings else { return }
            lastSettings = settings
            self?.receive(.workspace)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installToolbarIfNeeded()
        prepareForWindowResize(to: view.bounds.width)
        // The first layout can precede the window's restored size. Reconcile once it is attached.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyAdaptiveLayout(availableWidth: self.view.bounds.width)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        applyAdaptiveLayout()
    }

    private func buildLayout() {
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = makeSidebar()
        let workspace = makeHorizontalWorkspace()
        workspaceContainer = workspace
        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(workspace)
        sidebar.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        sidebar.widthAnchor.constraint(equalToConstant: AdaptiveShellLayout.sidebarWidth).isActive = true
        let workspaceMinimum = workspace.widthAnchor.constraint(greaterThanOrEqualToConstant: 480)
        workspaceMinimum.priority = .defaultLow
        workspaceMinimum.isActive = true

        view.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func makeSidebar() -> NSView {
        let container = sidebarContainer
        container.wantsLayer = true
        container.setAccessibilityIdentifier("global-sidebar")

        let stack = FlippedNavigationStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = GraphiteFocusPresentation.Space.compact
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for (index, tab) in sidebarTabs.enumerated() {
            let button = NSButton(image: NSImage(systemSymbolName: symbol(for: tab), accessibilityDescription: tab.rawValue) ?? NSImage(size: NSSize(width: 20, height: 20)), target: self, action: #selector(selectNavigationArea(_:)))
            button.tag = index
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = tab.rawValue
            button.setAccessibilityLabel(tab.rawValue)
            button.setAccessibilityIdentifier("sidebar-\(tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-"))")
            button.wantsLayer = true
            button.layer?.cornerRadius = GraphiteFocusPresentation.Radius.control
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 44),
                button.heightAnchor.constraint(equalToConstant: 44)
            ])
            if tab != .settings {
                stack.addArrangedSubview(button)
            }
            navigationButtons[tab] = button
        }

        aboutButton.isBordered = false
        aboutButton.imagePosition = .imageOnly
        aboutButton.imageScaling = .scaleProportionallyDown
        aboutButton.toolTip = "About Stillmatter (double-click)"
        aboutButton.setAccessibilityLabel("About Stillmatter")
        aboutButton.setAccessibilityHelp("Double-click to open About Stillmatter. Use Space or Return with the keyboard.")
        aboutButton.setAccessibilityIdentifier("sidebar-about")
        aboutButton.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        guard let settingsButton = navigationButtons[.settings] else {
            preconditionFailure("The navigation rail requires Settings")
        }
        container.addSubview(scrollView)
        container.addSubview(settingsButton)
        container.addSubview(aboutButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: settingsButton.topAnchor, constant: -GraphiteFocusPresentation.Space.compact),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            settingsButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            settingsButton.bottomAnchor.constraint(equalTo: aboutButton.topAnchor, constant: -GraphiteFocusPresentation.Space.compact),
            aboutButton.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            aboutButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.dense),
            aboutButton.widthAnchor.constraint(equalToConstant: 44),
            aboutButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        return container
    }

    private func makeHorizontalWorkspace() -> NSView {
        workspaceSplitView.isVertical = true
        workspaceSplitView.dividerStyle = .thin
        workspaceSplitView.delegate = self

        configureWorkspaceBrowserRegion()
        configureOptionalRegion(inspectorContainer, title: "Inspector", identifier: "contextual-inspector-region")
        detailContainer = makeMainContent()
        detailContainer.setAccessibilityIdentifier("detail-region")

        workspaceSplitView.addArrangedSubview(contentListContainer)
        workspaceSplitView.addArrangedSubview(detailContainer)
        workspaceSplitView.addArrangedSubview(inspectorContainer)

        fixedListWidth = contentListContainer.widthAnchor.constraint(equalToConstant: 320)
        let listMinimum = contentListContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        let listMaximum = contentListContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 380)
        let detailMinimum = detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 480)
        let inspectorMinimum = inspectorContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        let inspectorMaximum = inspectorContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        // The policy hides regions before these useful-width targets become hard window minima.
        [listMinimum, detailMinimum, inspectorMinimum, listMaximum, inspectorMaximum]
            .forEach { $0.priority = .defaultLow }
        NSLayoutConstraint.activate([listMinimum, listMaximum, detailMinimum, inspectorMinimum, inspectorMaximum])
        return workspaceSplitView
    }

    private func configureWorkspaceBrowserRegion() {
        contentListContainer.wantsLayer = true
        contentListContainer.translatesAutoresizingMaskIntoConstraints = false
        contentListContainer.setAccessibilityIdentifier("content-list-region")
        let browsers = [meetingManagementView.browserView]
        for browser in browsers {
            contentListContainer.addSubview(browser)
            NSLayoutConstraint.activate([
                browser.leadingAnchor.constraint(equalTo: contentListContainer.leadingAnchor),
                browser.trailingAnchor.constraint(equalTo: contentListContainer.trailingAnchor),
                browser.topAnchor.constraint(equalTo: contentListContainer.topAnchor),
                browser.bottomAnchor.constraint(equalTo: contentListContainer.bottomAnchor)
            ])
        }
    }

    private func configureOptionalRegion(_ region: NSView, title: String, identifier: String) {
        region.wantsLayer = true
        region.setAccessibilityIdentifier(identifier)
        let label = NSTextField(labelWithString: title)
        label.font = GraphiteFocusPresentation.Typography.sectionHeading
        label.translatesAutoresizingMaskIntoConstraints = false
        region.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: region.leadingAnchor, constant: GraphiteFocusPresentation.Space.page),
            label.topAnchor.constraint(equalTo: region.topAnchor, constant: GraphiteFocusPresentation.Space.page),
            label.trailingAnchor.constraint(lessThanOrEqualTo: region.trailingAnchor, constant: -GraphiteFocusPresentation.Space.page)
        ])
    }

    func installToolbarIfNeeded() {
        guard let window = view.window, window.toolbar !== toolbar else { return }
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.toolbar = toolbar
        // A unified toolbar changes the frame-to-content conversion. Recalculate
        // after attachment so the supported 720×520 is the actual outer minimum.
        let minimumFrame = NSRect(origin: .zero, size: AppDelegate.minimumWindowFrameSize)
        window.contentMinSize = window.contentRect(forFrameRect: minimumFrame).size
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === self.splitView && dividerIndex == 0 { return AdaptiveShellLayout.sidebarWidth }
        if splitView === workspaceSplitView && dividerIndex == 0 && stateStore.state.selectedTab == .meetings { return 320 }
        return proposedMinimumPosition
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === self.splitView && dividerIndex == 0 { return AdaptiveShellLayout.sidebarWidth }
        if splitView === workspaceSplitView && dividerIndex == 0 && stateStore.state.selectedTab == .meetings { return 320 }
        return proposedMaximumPosition
    }

    private func symbol(for tab: ShellTab) -> String {
        switch tab {
        case .today: "clock"
        case .recording: "record.circle"
        case .meetings: "bubble.left.and.bubble.right"
        case .tasks: "checkmark.square"
        case .settings: "slider.horizontal.3"
        }
    }

    private func updateNavigationSelection() {
        let colors = GraphiteFocusPresentation.Colors(environment: currentPresentationEnvironment)
        for (tab, button) in navigationButtons {
            let selected = tab == stateStore.state.selectedTab
            button.contentTintColor = selected ? colors.accent : colors.textSecondary
            button.layer?.backgroundColor = selected ? colors.surfaceSelectionNeutral.cgColor : colors.surfaceChrome.withAlphaComponent(0).cgColor
            button.setAccessibilityValue(selected ? "Selected" : "")
        }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleStillmatterSidebar, .sidebarDivider, .currentArea, .recordingStatus, .flexibleSpace, .jobStatus, .areaSearch]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleStillmatterSidebar, .sidebarDivider, .currentArea, .recordingStatus, .flexibleSpace, .jobStatus, .areaSearch]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if identifier == .sidebarDivider {
            let item = NSToolbarItem(itemIdentifier: identifier)
            let separator = NSBox(frame: NSRect(x: 0, y: 0, width: 1, height: 22))
            separator.boxType = .separator
            item.view = separator
            return item
        }
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier {
        case .toggleStillmatterSidebar:
            item.label = "Show or Hide Sidebar"
            item.paletteLabel = item.label
            item.toolTip = item.label
            item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: item.label)
            item.target = self
            item.action = #selector(toggleSidebar(_:))
        case .currentArea:
            toolbarAreaLabel.font = GraphiteFocusPresentation.Typography.control
            toolbarAreaLabel.setAccessibilityLabel("Current area")
            narrowBackButton.bezelStyle = .texturedRounded
            narrowBackButton.image = NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back to list")
            narrowBackButton.imagePosition = .imageLeading
            narrowBackButton.target = self
            narrowBackButton.action = #selector(showNarrowList(_:))
            narrowBackButton.setAccessibilityLabel("Back to list")
            narrowBackButton.isHidden = true
            let location = NSStackView(views: [narrowBackButton, toolbarAreaLabel])
            location.orientation = .horizontal
            location.spacing = GraphiteFocusPresentation.Space.compact
            item.label = "Current Area"
            item.view = location
        case .recordingStatus:
            recordingBadge.frame.size = NSSize(width: 145, height: 22)
            item.label = "Recording Status"
            item.view = recordingBadge
        case .jobStatus:
            jobPresentationContainer.frame.size = NSSize(width: 145, height: 22)
            configureJobPresentationIfNeeded()
            item.label = "Job Status"
            item.view = jobPresentationContainer
        case .areaSearch:
            configureAreaSearchIfNeeded()
            let stack = NSStackView(views: [searchField, searchKindPopup])
            stack.orientation = .horizontal
            stack.spacing = GraphiteFocusPresentation.Space.compact
            let searchWidth = searchField.widthAnchor.constraint(equalToConstant: 220)
            let kindWidth = searchKindPopup.widthAnchor.constraint(equalToConstant: 110)
            searchWidth.priority = .defaultHigh
            kindWidth.priority = .defaultHigh
            NSLayoutConstraint.activate([
                searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
                searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
                searchKindPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
                searchKindPopup.widthAnchor.constraint(lessThanOrEqualToConstant: 110),
                searchWidth,
                kindWidth
            ])
            item.label = "Search"
            item.paletteLabel = item.label
            item.view = stack
        default:
            return nil
        }
        switch identifier {
        case .toggleStillmatterSidebar, .areaSearch:
            item.visibilityPriority = .high
        case .currentArea:
            item.visibilityPriority = .user
        case .recordingStatus, .jobStatus:
            item.visibilityPriority = .low
        default:
            break
        }
        return item
    }

    private func configureAreaSearchIfNeeded() {
        guard searchField.target == nil else { return }
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search")
        searchField.setAccessibilityHelp("Search indexed results in the current area. Use the result type menu to narrow by type.")
        configureSearchKindPopup(searchKindPopup, action: #selector(searchKindChanged(_:)))
        configureSearchKindPopup(compactSearchKindPopup, action: #selector(compactSearchKindChanged(_:)))
        updateSearchAccessibilityContext(area: stateStore.state.selectedTab)
    }

    private func configureSearchKindPopup(_ popup: NSPopUpButton, action: Selector) {
        popup.addItem(withTitle: "All types")
        SearchChunkKind.allCases.forEach { kind in
            popup.addItem(withTitle: kind.displayName)
            popup.lastItem?.representedObject = kind.rawValue
        }
        popup.target = self
        popup.action = action
        popup.setAccessibilityLabel("Search result type")
        popup.setAccessibilityHelp("Narrows indexed Search results by result type; it does not change the searched area.")
    }

    private func configureJobPresentationIfNeeded() {
        guard jobPresentationContainer.subviews.isEmpty else { return }
        jobBadge.frame = jobPresentationContainer.bounds
        jobBadge.autoresizingMask = [.width, .height]
        jobProgress.orientation = .horizontal
        jobProgress.alignment = .centerY
        jobProgress.statusLabel.usesSingleLineMode = true
        jobProgress.statusLabel.lineBreakMode = .byTruncatingTail
        jobProgress.progressIndicator.style = .spinning
        jobProgress.valueLabel.isHidden = true
        jobProgress.frame = jobPresentationContainer.bounds
        jobProgress.autoresizingMask = [.width, .height]
        jobPresentationContainer.addSubview(jobBadge)
        jobPresentationContainer.addSubview(jobProgress)
    }

    private func makeMainContent() -> NSView {
        let scrollView = NSScrollView()
        contentScrollView = scrollView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.verticalScrollElasticity = .none
        scrollView.drawsBackground = false

        let container = ShellDocumentView()
        container.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = container

        contentTitle.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(contentTitle)
        container.addSubview(todayWorkbenchView)
        container.addSubview(captureRecordingView)
        container.addSubview(meetingManagementView)
        container.addSubview(proposalReviewView)
        container.addSubview(todoLedgerView)
        container.addSubview(settingsFormView)
        container.addSubview(searchResultsView)

        let bottomConstraints: [(NSView, NSLayoutConstraint)] = [
            (todayWorkbenchView, todayWorkbenchView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (captureRecordingView, captureRecordingView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (meetingManagementView, meetingManagementView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (proposalReviewView, proposalReviewView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.page)),
            (todoLedgerView, todoLedgerView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (settingsFormView, settingsFormView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (searchResultsView, searchResultsView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large))
        ]
        contentBottomConstraints = bottomConstraints
        meetingViewportHeight = meetingManagementView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor)

        NSLayoutConstraint.activate([
            contentTitle.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: GraphiteFocusPresentation.Space.large),
            contentTitle.topAnchor.constraint(equalTo: container.topAnchor, constant: GraphiteFocusPresentation.Space.large),
            todayWorkbenchView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            todayWorkbenchView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            todayWorkbenchView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.dense),
            captureRecordingView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            captureRecordingView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            captureRecordingView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            meetingManagementView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            meetingManagementView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            meetingManagementView.topAnchor.constraint(equalTo: container.topAnchor),
            proposalReviewView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            proposalReviewView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            proposalReviewView.topAnchor.constraint(equalTo: todayWorkbenchView.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            todoLedgerView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            todoLedgerView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            todoLedgerView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.panel),
            settingsFormView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            settingsFormView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            settingsFormView.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            settingsFormView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            searchResultsView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            searchResultsView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            searchResultsView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.panel),
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])

        return scrollView
    }

    var currentPresentationEnvironment: GraphiteFocusEnvironment {
        GraphiteFocusEnvironment.system(window: view.window)
    }

    private func observePresentationChanges() {
        let center = NotificationCenter.default
        [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].forEach { name in
            presentationObservers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in self?.applyPresentation() })
        }
        presentationObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.applyPresentation() })
    }

    private func applyPresentation() {
        guard isViewLoaded else { return }
        let colors = GraphiteFocusPresentation.Colors(environment: currentPresentationEnvironment)
        view.layer?.backgroundColor = colors.surfaceBase.cgColor
        sidebarContainer.layer?.backgroundColor = colors.surfaceChrome.cgColor
        contentListContainer.layer?.backgroundColor = colors.surfaceChrome.cgColor
        inspectorContainer.layer?.backgroundColor = colors.surfacePanel.cgColor
        [sidebarContainer, contentListContainer, inspectorContainer].forEach { region in
            region.layer?.borderWidth = GraphiteFocusPresentation.Stroke.width
            region.layer?.borderColor = colors.structuralStroke.cgColor
        }

        updateNavigationSelection()
        contentTitle.font = GraphiteFocusPresentation.Typography.pageTitle
        contentTitle.textColor = colors.textPrimary
        let captureSnapshot = captureServiceProvider()?.snapshot
        recordingBadge.setStatus(
            captureSnapshot?.state == .recording
                ? "Recording \(captureSnapshot?.meetingTitle ?? "Meeting")"
                : "Not Recording",
            meaning: captureSnapshot?.state == .recording ? .attention : .informational,
            colors: colors
        )
        updateJobBadge(colors: colors)
        // Accessibility/window appearance changes must not trigger workspace reads.
        if stateStore.state.selectedTab == .today && !todayWorkbenchView.isHidden {
            todayWorkbenchView.refresh(isVisible: true)
        }
    }

    func render() {
        updateFeatureVisibility()
        updateSearchPresentation()
        updateToolbarStatus()
    }

    func receive(_ change: ShellChange) {
        switch change {
        case .navigation, .search:
            updateFeatureVisibility()
            updateSearchPresentation()
        case .recordingStatus:
            updateToolbarStatus()
            if stateStore.state.selectedTab == .recording { captureRecordingView.refresh(isVisible: true) }
        case .jobStatus, .teamsStatus:
            updateToolbarStatus()
            if stateStore.state.selectedTab == .recording { captureRecordingView.refresh(isVisible: true) }
        case .tasks:
            reloadToday()
            reloadTodos()
            if stateStore.state.selectedTab == .today { proposalReviewView.refresh(isVisible: true) }
        case .meetings:
            if stateStore.state.selectedTab == .meetings && !isSearchPresented { meetingManagementView.refresh(isVisible: true) }
        case .searchIndex:
            lastSearchRequest = nil
            pendingSearch?.cancel()
            searchRevision += 1
            updateSearchPresentation()
        case .workspace:
            todayLoader.reset()
            todoLoader.reset()
            lastSearchRequest = nil
            pendingSearch?.cancel()
            searchRevision += 1
            updateFeatureVisibility(force: true)
            updateSearchPresentation()
        }
    }

    private func updateFeatureVisibility(force: Bool = false) {
        let state = stateStore.state
        let searching = state.selectedTab != .settings && isSearchPresented
            && !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard force || lastVisibility?.tab != state.selectedTab || lastVisibility?.searching != searching else { return }
        lastVisibility = (state.selectedTab, searching)
        let changedTab = lastRenderedTab != state.selectedTab
        if changedTab {
            if state.selectedTab != .today { pendingInboxFocusID = nil }
            showingNarrowDetail = false
            lastRenderedTab = state.selectedTab
            contentScrollView?.contentView.scroll(to: .zero)
            if let scroll = contentScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
        }
        contentTitle.stringValue = state.selectedTab == .meetings ? "" : state.selectedTab.rawValue
        let isSearching = searching
        let showsToday = state.selectedTab == .today && !isSearching
        todayWorkbenchView.refresh(isVisible: showsToday)
        let showsTasks = state.selectedTab == .tasks && !isSearching
        settingsFormView.isHidden = state.selectedTab != .settings || isSearching
        let showsMeetingWorkspace = state.selectedTab == .meetings && !isSearching
        // Search occupies the detail canvas; browsers activate the adaptive content/list region.
        hasContentListRegion = showsMeetingWorkspace
        hasInspectorRegion = false
        #if DEBUG || STILLMATTER_NATIVE_PROBES
        hasContentListRegion = usesAdaptiveFixtureRegions || hasContentListRegion
        hasInspectorRegion = usesAdaptiveFixtureRegions
        #endif
        meetingManagementView.refresh(isVisible: showsMeetingWorkspace)
        meetingViewportHeight?.isActive = showsMeetingWorkspace
        contentScrollView?.hasVerticalScroller = !showsMeetingWorkspace
        if showsMeetingWorkspace && changedTab, let scroll = contentScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        proposalReviewView.refresh(isVisible: state.selectedTab == .today && !isSearching)
        todoLedgerView.refresh(isVisible: showsTasks)
        if showsToday { reloadToday() }
        if showsTasks { reloadTodos() }
        captureRecordingView.refresh(isVisible: state.selectedTab == .recording && !isSearching)
        searchResultsView.isHidden = !isSearching
        // Hidden views keep their Auto Layout constraints; only the visible page may size the document.
        for (page, constraint) in contentBottomConstraints {
            let shouldBeActive = !page.isHidden
            if constraint.isActive != shouldBeActive {
                constraint.isActive = shouldBeActive
            }
        }
        toolbarAreaLabel.stringValue = state.selectedTab.rawValue
        toolbarAreaLabel.setAccessibilityValue(state.selectedTab.rawValue)
        applyAdaptiveLayout()
        updateNavigationSelection()
    }

    private func updateSearchPresentation() {
        let state = stateStore.state
        let isSearching = state.selectedTab != .settings && isSearchPresented
            && !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if isSearching {
            renderSearch(query: state.searchText, area: state.selectedTab)
        } else if lastSearchRequest != nil {
            pendingSearch?.cancel()
            pendingSearch = nil
            searchRevision += 1
            lastSearchRequest = nil
        }
        if searchField.stringValue != state.searchText { searchField.stringValue = state.searchText }
        searchField.placeholderString = "Search"
        updateSearchAccessibilityContext(area: state.selectedTab)
        if compactSearchField.stringValue != state.searchText { compactSearchField.stringValue = state.searchText }
        compactSearchField.placeholderString = searchField.placeholderString
    }

    private func updateToolbarStatus() {
        let captureSnapshot = captureServiceProvider()?.snapshot
        let colors = GraphiteFocusPresentation.Colors(environment: currentPresentationEnvironment)
        recordingBadge.setStatus(
            captureSnapshot?.state == .recording
                ? "Recording \(captureSnapshot?.meetingTitle ?? "Meeting")"
                : "Not Recording",
            meaning: captureSnapshot?.state == .recording ? .attention : .informational,
            colors: colors
        )
        updateJobBadge(colors: colors)
    }

    @discardableResult
    func focusInboxItem(id: String) -> Bool {
        isSearchPresented = false
        stateStore.state.select(.today)
        contentScrollView?.documentView?.layoutSubtreeIfNeeded()
        if todayWorkbenchView.focusInboxItem(id: id) { return true }
        pendingInboxFocusID = id
        reloadToday()
        return false // The exact row is focused when the off-main refresh completes.
    }

    private func renderSearch(query rawQuery: String, area: ShellTab) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedKind = currentSearchKind()
        let typeName = selectedKind?.displayName ?? "All types"
        let index = searchIndexProvider()
        let request = "\(area.rawValue)|\(typeName)|\(query)|\(index.map { ObjectIdentifier($0).hashValue } ?? 0)"
        guard request != lastSearchRequest else { return }
        lastSearchRequest = request
        pendingSearch?.cancel()
        searchRevision += 1
        let revision = searchRevision
        guard !query.isEmpty else {
            searchResultsView.render(query: "", scope: area.rawValue, type: typeName, state: .emptyQuery)
            return
        }
        guard let index else {
            searchResultsView.render(query: query, scope: area.rawValue, type: typeName, state: .unavailable)
            return
        }
        let areaKinds = searchKinds(for: area)
        if let selectedKind, let areaKinds, !areaKinds.contains(selectedKind) {
            searchResultsView.render(query: query, scope: area.rawValue, type: typeName, state: .noResults)
            return
        }
        let kinds = selectedKind.map { Set([$0]) } ?? areaKinds ?? []
        searchResultsView.render(query: query, scope: area.rawValue, type: typeName, state: .loading)
        let runner = searchRunner
        pendingSearch = Task.detached(priority: .userInitiated) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            let result = Result { try runner(index, query, SearchFilter(kinds: kinds)) }
            guard !Task.isCancelled, let controller = self else { return }
            await MainActor.run {
                guard controller.searchRevision == revision else { return }
                switch result {
                case let .success(results):
                    controller.searchResultsView.render(query: query, scope: area.rawValue, type: typeName, state: results.isEmpty ? .noResults : .results(results))
                case let .failure(error):
                    controller.searchResultsView.render(query: query, scope: area.rawValue, type: typeName, state: .failed(String(describing: error)))
                }
            }
        }
    }

    private func currentSearchKind() -> SearchChunkKind? {
        (searchKindPopup.selectedItem?.representedObject as? String)
            .flatMap(SearchChunkKind.init(rawValue:))
    }

    func updateSearchAccessibilityContext(area: ShellTab) {
        synchronizeSearchKindPopups(from: searchKindPopup)
        let typeName = currentSearchKind()?.displayName ?? "All types"
        let help = "Search indexed results in \(area.rawValue). Current result type: \(typeName)."
        searchField.setAccessibilityHelp(help)
        compactSearchField.setAccessibilityHelp(help)
        searchKindPopup.setAccessibilityValue(typeName)
        compactSearchKindPopup.setAccessibilityValue(typeName)
        compactSearchScopeLabel.stringValue = "Scope: \(area.rawValue)"
        compactSearchScopeLabel.setAccessibilityLabel("Search scope")
        compactSearchScopeLabel.setAccessibilityValue(area.rawValue)
    }

    func synchronizeSearchKindPopups(from source: NSPopUpButton) {
        let representedValue = source.selectedItem?.representedObject as? String
        let target = source === searchKindPopup ? compactSearchKindPopup : searchKindPopup
        let index = target.itemArray.firstIndex {
            ($0.representedObject as? String) == representedValue
        } ?? 0
        target.selectItem(at: index)
    }

    private func searchKinds(for area: ShellTab) -> Set<SearchChunkKind>? {
        switch area {
        case .today: return [.todo, .meeting]
        case .recording: return []
        case .meetings: return [.meeting, .summary, .transcript, .metadata]
        case .tasks: return [.todo]
        case .settings: return []
        }
    }

    private func reloadToday() {
        guard stateStore.state.selectedTab == .today && !todayWorkbenchView.isHidden else { return }
        let root = settingsStore.settings.stillmatterRootURL
        let inbox = root.flatMap { try? tasksInbox?.scoped(to: $0) }
        let snapshot = captureServiceProvider()?.snapshot
        let recording = snapshot?.state == .recording
            ? "Recording \(snapshot?.meetingTitle ?? "Meeting")" : "Not recording"
        let jobs = jobStatusProvider()
        let selection = settingsStore.settings.calendarSourceSelection
        todayLoader.reload(rootURL: root, inbox: inbox,
                           recording: recording, jobs: jobs, calendarSelection: selection)
    }

    private func reloadTodos() {
        guard stateStore.state.selectedTab == .tasks && !todoLedgerView.isHidden else { return }
        let root = settingsStore.settings.stillmatterRootURL
        todoLoader.reload(rootURL: root)
    }

    private func openWorkspaceFile(_ relativePath: String) {
        guard let rootURL = settingsStore.settings.stillmatterRootURL else {
            stateStore.state.select(.settings)
            return
        }
        WorkspaceSourceOpener.present(rootURL.appendingPathComponent(relativePath))
    }

    func updateJobBadge(colors: GraphiteFocusPresentation.Colors) {
        updateJobPresentation(status: jobStatusProvider(), colors: colors)
    }

    func updateJobPresentation(status: String, colors: GraphiteFocusPresentation.Colors) {
        configureJobPresentationIfNeeded()
        let normalized = status.lowercased()
        let isProcessing = normalized.contains("running") || normalized.contains("queued")
        jobProgress.isHidden = !isProcessing
        jobBadge.isHidden = isProcessing
        if isProcessing {
            jobProgress.configure(
                title: status,
                value: nil,
                valueDescription: normalized.contains("queued") ? "Queued" : "Running",
                colors: colors
            )
            if currentPresentationEnvironment.reducedMotion {
                jobProgress.progressIndicator.stopAnimation(nil)
            } else {
                jobProgress.progressIndicator.startAnimation(nil)
            }
        } else {
            jobProgress.progressIndicator.stopAnimation(nil)
            let meaning: GraphiteFocusStatusMeaning = normalized.contains("fail") ? .destructive : .informational
            jobBadge.setStatus(status, meaning: meaning, colors: colors)
        }
    }

    private func currentTodayOwner(_ owner: String?) -> Bool {
        guard let owner, let root = settingsStore.settings.stillmatterRootURL else { return false }
        return owner == root.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func currentTodayInboxItem(_ item: InboxItem) -> Bool {
        guard currentTodayOwner(item.workspaceOwner),
              let root = settingsStore.settings.stillmatterRootURL,
              let scoped = try? tasksInbox?.scoped(to: root),
              let current = try? scoped.items(category: item.category).first(where: { $0.id == item.id }) else { return false }
        return TodayTargetResolution.inbox(item, owner: root.standardizedFileURL.resolvingSymlinksInPath().path,
                                           current: [current]) != nil
    }

    private func openTodayTitle(_ item: InboxItem) {
        guard currentTodayInboxItem(item) else { todayWorkbenchView.showUnavailableInboxItem(id: item.id); return }
        onReviewTitle(item)
    }

    private func openTodayProposal(_ item: InboxItem) {
        guard item.kind == .proposal, currentTodayInboxItem(item) else {
            todayWorkbenchView.showUnavailableInboxItem(id: item.id); return
        }
        proposalReviewView.refresh(isVisible: true)
        guard proposalReviewView.focusProposal(id: item.id) else {
            todayWorkbenchView.showUnavailableInboxItem(id: item.id); return
        }
    }

    private func openTodayDecision(_ item: InboxItem) {
        guard currentTodayInboxItem(item) else { todayWorkbenchView.showUnavailableInboxItem(id: item.id); return }
        // Recovery requires a second explicit action. Never retry a Job merely
        // because Today rendered or the user inspected its failure record.
        if item.kind == .failedJob, retryableMeeting(for: item) != nil {
            todayWorkbenchView.showDecisionDetail(item, actionTitle: "Retry this Job",
                onAction: { [weak self] in self?.retryTodayJob(item) })
        } else {
            todayWorkbenchView.showDecisionDetail(item)
        }
    }

    private func retryableMeeting(for item: InboxItem) -> (service: MeetingManagementService, meetingID: String)? {
        guard item.kind == .failedJob, item.id.hasPrefix("job:"),
              currentTodayInboxItem(item), let owner = item.workspaceOwner,
              let job = jobRecordsProvider().first(where: { $0.id == String(item.id.dropFirst(4)) }),
              let service = meetingServiceProvider(),
              let rows = try? service.list(),
              let meetingID = TodayTargetResolution.retryableMeetingID(
                  for: item, owner: owner, jobID: job.id, jobOwner: job.manifest.workspaceOwner,
                  jobStatus: job.status, meetings: rows.compactMap { row in
                      row.job.map { (meetingID: row.id, jobID: $0.jobID, status: $0.status) }
                  }) else { return nil }
        return (service, meetingID)
    }

    private func retryTodayJob(_ item: InboxItem) {
        guard let target = retryableMeeting(for: item) else {
            todayWorkbenchView.showUnavailableInboxItem(id: item.id)
            return
        }
        do {
            try target.service.retryFailedJob(meetingID: target.meetingID,
                                               jobID: String(item.id.dropFirst(4)))
            todayWorkbenchView.showDecisionDetail(item, feedback: "Retry queued for this Job.")
        } catch {
            todayWorkbenchView.showDecisionDetail(item, actionTitle: "Retry this Job",
                onAction: { [weak self] in self?.retryTodayJob(item) },
                feedback: "Could not retry: \(error.localizedDescription)")
        }
    }

    private func openTodayTodo(_ item: TodoItem, owner: String?) {
        guard currentTodayOwner(owner) else { todayWorkbenchView.showUnavailableInboxItem(id: item.id); return }
        openTodoItem(item)
    }

    private func openTodayMeeting(_ meeting: TodayMeeting, owner: String?) {
        guard currentTodayOwner(owner), meeting.eventIdentifier != nil,
              meeting.calendarIdentifier != nil else {
            todayWorkbenchView.showUnavailableInboxItem(id: meeting.eventIdentifier ?? meeting.title)
            return
        }
        // Calendar rows are EventKit events, not Meeting workspace folders. Never
        // select a recorded Meeting by a matching title or position.
        openCalendarEvent(meeting, owner: owner)
    }

    private func openCalendarEvent(_ meeting: TodayMeeting, owner: String?) {
        guard let id = meeting.eventIdentifier, let calendarID = meeting.calendarIdentifier else { return }
        // This is an explicit user action, not a workspace scan during rendering.
        // Re-resolve the EventKit ID after every activation: deleted/moved events
        // must never fall through to another event with the same title/time.
        let store = EKEventStore()
        guard let event = store.event(withIdentifier: id), let owner,
              TodayTargetResolution.calendar(meeting, selectedOwner: owner, owner: owner,
                  eventIdentifier: event.eventIdentifier, calendarIdentifier: event.calendar.calendarIdentifier,
                  eventStart: event.startDate),
              currentTodayOwner(owner) else {
            todayWorkbenchView.showUnavailableInboxItem(id: id)
            return
        }
        let title = event.title ?? "Untitled meeting"
        let date = DateFormatter.localizedString(from: event.startDate, dateStyle: .medium, timeStyle: .short)
        todayWorkbenchView.showMeetingDetail(meeting, currentTitle: title, currentTime: date)
    }

    private func openTodoItem(_ item: TodoItem) {
        guard let rootURL = settingsStore.settings.stillmatterRootURL else {
            stateStore.state.select(.settings)
            return
        }
        // A line number can now name another Todo after a reorder. Never open a stale
        // location as if it still identified this item.
        guard let owner = settingsStore.settings.stillmatterRootURL?.standardizedFileURL.resolvingSymlinksInPath().path else { return }
        pendingTodayTodo = (item, owner)
        stateStore.state.select(.tasks)
        reloadTodos()
    }

    func applyAdaptiveLayout(availableWidth proposedWidth: CGFloat? = nil) {
        // Use the actual settled width after layout; a remembered resize proposal can be
        // stale after programmatic window sizing and hide the Meetings browser indefinitely.
        let width = proposedWidth ?? view.bounds.width
        guard width > 0, !isApplyingAdaptiveLayout else { return }
        isApplyingAdaptiveLayout = true
        defer { isApplyingAdaptiveLayout = false }
        let layout = AdaptiveShellLayout(
            availableWidth: width,
            hasContentList: hasContentListRegion,
            hasInspector: hasInspectorRegion,
            prefersSidebar: sidebarPreferredVisible,
            prefersInspector: inspectorPreferredVisible
        )

        let sidebarWasVisible = splitView.arrangedSubviews.first === sidebarContainer
        synchronizeArrangedSubviews(
            of: splitView,
            desired: layout.showsSidebar ? [sidebarContainer, workspaceContainer] : [workspaceContainer]
        )
        if layout.showsSidebar
            && (!sidebarWasVisible || abs(sidebarContainer.frame.width - AdaptiveShellLayout.sidebarWidth) >= 1) {
            splitView.setPosition(AdaptiveShellLayout.sidebarWidth, ofDividerAt: 0)
        }

        var workspaceRegions: [NSView] = []
        switch layout.detailMode {
        case .detailOnly:
            showingNarrowDetail = false
            workspaceRegions = [detailContainer]
        case .listAndDetail:
            workspaceRegions = [contentListContainer, detailContainer]
        case .listOnly:
            workspaceRegions = showingNarrowDetail ? [detailContainer] : [contentListContainer]
        }
        if layout.showsInspector { workspaceRegions.append(inspectorContainer) }
        if layout.detailMode != .listAndDetail { fixedListWidth?.isActive = false }
        synchronizeArrangedSubviews(of: workspaceSplitView, desired: workspaceRegions)
        if layout.detailMode == .listAndDetail {
            // NSSplitView owns the browser width; a competing width constraint loses to
            // its zero-width autoresizing mask after the detail-only transition.
            fixedListWidth?.isActive = false
            if stateStore.state.selectedTab == .meetings && workspaceSplitView.bounds.width >= 800 &&
                (contentListContainer.frame.width < 260 || contentListContainer.frame.width > 380) {
                // Returning from narrow list-only can leave the browser at full width.
                // Restore the split before it compresses essential detail controls.
                workspaceSplitView.setPosition(320, ofDividerAt: 0)
            }
        }

        narrowBackButton.isHidden = !(layout.isNarrowNavigation && showingNarrowDetail)
        toolbarAreaLabel.stringValue = stateStore.state.selectedTab.rawValue
        toolbarAreaLabel.setAccessibilityValue(stateStore.state.selectedTab.rawValue)
        lastAdaptiveLayout = layout
    }

    private func synchronizeArrangedSubviews(of split: NSSplitView, desired: [NSView]) {
        let current = split.arrangedSubviews
        guard current.count != desired.count || zip(current, desired).contains(where: { $0 !== $1 }) else { return }
        // Retain split regions while collapsing to list/detail; removing and
        // reinserting them during resize triggers an AppKit layout loop.
        guard current.contains(where: { region in
            region.isHidden == desired.contains(where: { $0 === region })
        }) else { return }
        current.forEach { region in
            region.isHidden = !desired.contains(where: { $0 === region })
        }
        split.adjustSubviews()
    }

    func prepareForWindowResize(to width: CGFloat) {
        requestedWindowWidth = width
        installToolbarIfNeeded()
        let toolbarSearchHadFocus = searchControlHasFocus(searchField)
        let toolbarTypeHadFocus = view.window?.firstResponder === searchKindPopup
        let compactFieldHadFocus = searchControlHasFocus(compactSearchField)
        let compactTypeHadFocus = view.window?.firstResponder === compactSearchKindPopup
        if toolbarSearchHadFocus && stateStore.state.searchText != searchField.stringValue {
            stateStore.state.searchText = searchField.stringValue
        } else if compactFieldHadFocus && stateStore.state.searchText != compactSearchField.stringValue {
            stateStore.state.searchText = compactSearchField.stringValue
        }
        let compactedIdentifiers: Set<NSToolbarItem.Identifier> = [
            .toggleStillmatterSidebar, .recordingStatus, .jobStatus, .areaSearch
        ]
        if width < 900 && toolbarItemsCompactedForWidth.isEmpty {
            toolbarItemsCompactedForWidth = toolbar.items.enumerated().compactMap { index, item in
                compactedIdentifiers.contains(item.itemIdentifier) ? (item.itemIdentifier, index) : nil
            }
            toolbar.autosavesConfiguration = false
            for entry in toolbarItemsCompactedForWidth.sorted(by: { $0.index > $1.index }) {
                toolbar.removeItem(at: entry.index)
            }
            toolbar.autosavesConfiguration = true
            if toolbarSearchHadFocus || toolbarTypeHadFocus {
                focusAreaSearch(nil)
                if toolbarTypeHadFocus { compactSearchField.window?.makeFirstResponder(compactSearchKindPopup) }
            }
        } else if width >= 900 && !toolbarItemsCompactedForWidth.isEmpty {
            toolbar.autosavesConfiguration = false
            for entry in toolbarItemsCompactedForWidth.sorted(by: { $0.index < $1.index }) {
                toolbar.insertItem(withItemIdentifier: entry.identifier, at: min(entry.index, toolbar.items.count))
            }
            toolbar.autosavesConfiguration = true
            toolbarItemsCompactedForWidth = []
            if (compactFieldHadFocus || compactTypeHadFocus),
               toolbar.items.contains(where: { $0.itemIdentifier == .areaSearch }) {
                compactSearchPopover.close()
                view.window?.toolbar?.validateVisibleItems()
                view.window?.layoutIfNeeded()
                let target = compactTypeHadFocus ? searchKindPopup : searchField
                view.window?.makeFirstResponder(target)
                DispatchQueue.main.async { [weak self, weak target] in
                    guard let self, let target else { return }
                    self.view.window?.makeFirstResponder(target)
                }
            }
        }
        // Collapse target regions before AppKit evaluates their fitting widths.
        applyAdaptiveLayout(availableWidth: width)
    }

    func searchControlHasFocus(_ control: NSSearchField) -> Bool {
        guard let firstResponder = view.window?.firstResponder else { return false }
        return firstResponder === control || control.currentEditor() === firstResponder
    }

    deinit {
        shellObservation?.cancel()
        statusObservation?.cancel()
        if let settingsObservation { settingsStore.removeObserver(settingsObservation) }
        if isViewLoaded { todayLoader.stop(); todoLoader.stop() }
        pendingSearch?.cancel()
        presentationObservers.forEach(NotificationCenter.default.removeObserver)
        presentationObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    @objc private func selectNavigationArea(_ sender: NSButton) {
        stateStore.state.select(sidebarTabs[sender.tag])
    }

    @objc func focusAreaSearch(_ sender: Any?) {
        isSearchPresented = stateStore.state.selectedTab != .settings
        render()
        installToolbarIfNeeded()
        if toolbar.items.contains(where: { $0.itemIdentifier == .areaSearch }) {
            view.window?.makeFirstResponder(searchField)
            return
        }
        if compactSearchPopover.contentViewController == nil {
            compactSearchPopover.delegate = self
            compactSearchField.target = self
            compactSearchField.action = #selector(compactSearchChanged(_:))
            compactSearchField.delegate = self
            compactSearchField.placeholderString = "Search"
            compactSearchField.setAccessibilityLabel("Search")
            compactSearchField.setAccessibilityHelp("Search indexed results in the current area. Choose a result type to narrow results without changing this scope.")
            compactSearchScopeLabel.font = GraphiteFocusPresentation.Typography.metadata
            compactSearchScopeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            updateSearchAccessibilityContext(area: stateStore.state.selectedTab)

            let controls = NSStackView(views: [compactSearchField, compactSearchKindPopup])
            controls.orientation = .horizontal
            controls.alignment = .centerY
            controls.spacing = GraphiteFocusPresentation.Space.compact
            compactSearchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true // graphite-focus-native-exception: compact native search field minimum
            compactSearchKindPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true // graphite-focus-native-exception: native picker must show selected result type
            let content = NSStackView(views: [compactSearchScopeLabel, controls])
            content.orientation = .vertical
            content.alignment = .leading
            content.spacing = GraphiteFocusPresentation.Space.compact
            content.edgeInsets = NSEdgeInsets(
                top: GraphiteFocusPresentation.Space.dense,
                left: GraphiteFocusPresentation.Space.dense,
                bottom: GraphiteFocusPresentation.Space.dense,
                right: GraphiteFocusPresentation.Space.dense
            )
            content.frame = NSRect(x: 0, y: 0, width: 320, height: 76) // graphite-focus-native-exception: compact popover fitting size for native controls
            controls.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * GraphiteFocusPresentation.Space.dense).isActive = true
            let controller = NSViewController()
            controller.view = content
            compactSearchPopover.contentViewController = controller
            compactSearchPopover.behavior = .transient
        }
        let anchor = toolbarAreaLabel.window == view.window ? toolbarAreaLabel : view
        compactSearchPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        compactSearchField.window?.makeFirstResponder(compactSearchField)
    }

    func popoverDidClose(_ notification: Notification) {
        guard transferFocusToResultsOnPopoverClose else { return }
        transferFocusToResultsOnPopoverClose = false
        // AppKit restores the popover's field editor after didClose. Restore the
        // results on the next main-queue turn, but not if search was dismissed.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isSearchPresented, !self.searchResultsView.isHidden else { return }
            self.searchResultsView.focusResults()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField || control === compactSearchField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismissSearch()
            return true
        }
        guard commandSelector == #selector(NSResponder.moveDown(_:)),
              !searchResultsView.isHidden,
              searchResultsView.focusResults() else { return false }
        if control === compactSearchField {
            transferFocusToResultsOnPopoverClose = true
            compactSearchPopover.close()
        }
        return true
    }

    private func dismissSearch() {
        guard isSearchPresented else { return }
        isSearchPresented = false
        transferFocusToResultsOnPopoverClose = false
        if compactSearchPopover.isShown { compactSearchPopover.close() }
        render()
        view.window?.makeFirstResponder(navigationButtons[stateStore.state.selectedTab])
    }

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarPreferredVisible.toggle()
        UserDefaults.standard.set(sidebarPreferredVisible, forKey: "Stillmatter.SidebarVisible")
        applyAdaptiveLayout()
    }

    @objc func showNarrowList(_ sender: Any?) {
        showingNarrowDetail = false
        applyAdaptiveLayout()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        isSearchPresented = true
        stateStore.state.searchText = sender.stringValue
    }

    @objc private func compactSearchChanged(_ sender: NSSearchField) {
        isSearchPresented = true
        stateStore.state.searchText = sender.stringValue
    }

    @objc private func searchKindChanged(_ sender: NSPopUpButton) {
        synchronizeSearchKindPopups(from: sender)
        updateSearchAccessibilityContext(area: stateStore.state.selectedTab)
        lastSearchRequest = nil
        updateSearchPresentation()
    }

    @objc func compactSearchKindChanged(_ sender: NSPopUpButton) {
        synchronizeSearchKindPopups(from: sender)
        updateSearchAccessibilityContext(area: stateStore.state.selectedTab)
        lastSearchRequest = nil
        updateSearchPresentation()
        compactSearchField.window?.makeFirstResponder(compactSearchKindPopup)
    }

}

private final class ShellDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private final class FlippedNavigationStackView: NSStackView {
    override var isFlipped: Bool { true }
}

/// A pointer click does not navigate; a double-click opens the native About panel.
/// Native keyboard and accessibility activation still call performClick(_:) once.
final class DoubleClickAboutButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else { return }
        super.mouseDown(with: event)
    }
}

extension NSToolbarItem.Identifier {
    static let toggleStillmatterSidebar = NSToolbarItem.Identifier("Stillmatter.ToggleSidebar")
    static let currentArea = NSToolbarItem.Identifier("Stillmatter.CurrentArea")
    static let sidebarDivider = NSToolbarItem.Identifier("Stillmatter.SidebarDivider")
    static let recordingStatus = NSToolbarItem.Identifier("Stillmatter.RecordingStatus")
    static let jobStatus = NSToolbarItem.Identifier("Stillmatter.JobStatus")
    static let areaSearch = NSToolbarItem.Identifier("Stillmatter.AreaSearch")
}
