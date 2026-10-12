import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

final class ShellViewController: NSViewController, NSSplitViewDelegate, NSToolbarDelegate, NSSearchFieldDelegate, NSPopoverDelegate {
    private let stateStore: ShellStateStore
    private let settingsStore: SettingsStore
    private let tasksInbox: TasksInbox?
    private var searchIndexProvider: () -> SearchIndex?
    private let captureServiceProvider: () -> MeetingCaptureService?
    private let meetingServiceProvider: () -> MeetingManagementService?
    private let onReviewTitle: (InboxItem) -> Void
    private let teamsDetectionProvider: () -> TeamsDetectionSnapshot?
    private let teamsRecordingDiagnosticProvider: () -> String
    private let onManualCapture: () -> Void
    private let contextualAskServiceProvider: () -> ContextualAskService?
    private let jobRecordsProvider: () -> [JobRecord]
    private let jobStatusProvider: () -> String
    private let upcomingMeetingsProvider: () -> [TodayMeeting]
    private let settingsFormView: SettingsFormView
    private let splitView = NSSplitView()
    private let workspaceSplitView = NSSplitView()
    private var workspaceContainer = NSView()
    private let sidebarContainer = NSView()
    private let contentListContainer = NSView()
    private var fixedListWidth: NSLayoutConstraint?
    private let inspectorContainer = NSView()
    private var detailContainer = NSView()
    private var contentScrollView: NSScrollView?
    private var meetingViewportHeight: NSLayoutConstraint?
    private var contentBottomConstraints: [(view: NSView, constraint: NSLayoutConstraint)] = []
    private let aboutButton = DoubleClickAboutButton(image: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage,
        target: NSApp, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
    private var navigationButtons: [ShellTab: NSButton] = [:]
    private let sidebarTabs: [ShellTab] = [.today, .recording, .meetings, .tasks, .projectsActivities, .reports, .askAI, .settings]
    private let contentTitle = NSTextField(labelWithString: "")
    private let recordingBadge = GraphiteFocusStatusLabel()
    private let jobBadge = GraphiteFocusStatusLabel()
    private lazy var captureRecordingView = CaptureRecordingView(
        serviceProvider: captureServiceProvider,
        rootURLProvider: { [weak self] in self?.settingsStore.settings.stillmatterRootURL },
        teamsDetectionProvider: teamsDetectionProvider,
        teamsRecordingDiagnosticProvider: teamsRecordingDiagnosticProvider,
        onManualCapture: onManualCapture,
        jobRecordsProvider: jobRecordsProvider,
        onOpenSettings: { [weak self] in self?.stateStore.state.select(.settings) }
    )
    private lazy var meetingManagementView: MeetingManagementView = {
        let workspace = MeetingManagementView(
            serviceProvider: meetingServiceProvider,
            openRecording: { [weak self] in self?.stateStore.state.select(.recording) },
            openWorkspaceFile: { [weak self] path in self?.openWorkspaceFile(path) }
        )
        workspace.setOnOpenSelection { [weak self] in
            guard let self, self.stateStore.state.selectedTab == .meetings else { return }
            self.showingNarrowDetail = true
            self.applyAdaptiveLayout()
        }
        return workspace
    }()
    private lazy var todayWorkbenchView = TodayWorkbenchView(
        stateProvider: { [weak self] in self?.todayWorkbenchState() ?? .unavailable("Today is unavailable.") },
        onSelectArea: { [weak self] tab in self?.stateStore.state.select(tab) },
        onOpenDailyBrief: { [weak self] relativePath in self?.openWorkspaceFile(relativePath) },
        onReviewProposals: { [weak self] in self?.proposalReviewView.focusFirstProposal() },
        onReviewTitle: { [weak self] item in self?.onReviewTitle(item) }
    )
    private lazy var proposalReviewView = ProposalReviewView(
        settingsStore: settingsStore,
        inbox: tasksInbox,
        onChange: { [weak self] in self?.stateStore.refresh() }
    )
    private lazy var todoLedgerView = TodoLedgerView(
        stateProvider: { [weak self] in self?.todoLedgerState() ?? .unavailable("Tasks are unavailable.") },
        onOpenItem: { [weak self] item in self?.openTodoItem(item) },
        onOpenSettings: { [weak self] in self?.stateStore.state.select(.settings) }
    )
    private lazy var activityManagementView: ActivityManagementView = {
        let workspace = ActivityManagementView(
            settingsStore: settingsStore,
            onChange: { [weak self] in self?.stateStore.refresh() },
            onOpenSettings: { [weak self] in self?.stateStore.state.select(.settings) }
        )
        workspace.setOnOpenSelection { [weak self] in
            guard let self = self else { return }
            self.showingNarrowDetail = true
            self.applyAdaptiveLayout()
        }
        return workspace
    }()
    private lazy var contextualAskView = ContextualAskView(
        serviceProvider: contextualAskServiceProvider
    )
    private lazy var reportsView = ReportsView(
        stateProvider: { [weak self] in
            guard let self = self else { return .unavailable("Reports could not load.") }
            guard self.settingsStore.settings.stillmatterRootURL != nil else {
                return .unavailable("Choose an Stillmatter root to generate Daily Briefs and Weekly Reports.")
            }
            guard self.tasksInbox != nil else {
                return .unavailable("The operational Inbox required for report generation could not be opened.")
            }
            return .available
        },
        onOpenToday: { [weak self] in self?.stateStore.state.select(.today) },
        onOpenSettings: { [weak self] in self?.stateStore.state.select(.settings) }
    )
    private lazy var searchResultsView = SearchResultsView(
        onOpenResult: { [weak self] result in self?.openWorkspaceFile(result.sourcePath) },
        onOpenSettings: { [weak self] in self?.stateStore.state.select(.settings) },
        onRetry: { [weak self] in self?.stateStore.refresh() },
        onDismiss: { [weak self] in self?.dismissSearch() }
    )
    private let searchField = NSSearchField()
    private let compactSearchField = NSSearchField()
    private let compactSearchPopover = NSPopover()
    private var transferFocusToResultsOnPopoverClose = false
    private let searchKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let toolbarAreaLabel = NSTextField(labelWithString: "Today")
    private let narrowBackButton = NSButton(title: "Back", target: nil, action: nil)
    private let toolbar = NSToolbar(identifier: "Stillmatter.MainToolbar.v3")
    private var hasContentListRegion = false
    private var hasInspectorRegion = false
    private var usesAdaptiveFixtureRegions = false
    private var showingNarrowDetail = false
    private var lastRenderedTab: ShellTab?
    private var isSearchPresented = false
    private var pendingSearch: Task<Void, Never>?
    private var searchRevision = 0
    private var lastSearchRequest: String?
    private var requestedWindowWidth: CGFloat?
    private var isApplyingAdaptiveLayout = false
    private var toolbarItemsCompactedForWidth: [(identifier: NSToolbarItem.Identifier, index: Int)] = []
    private var lastAdaptiveLayout: AdaptiveShellLayout?
    private var sidebarPreferredVisible = UserDefaults.standard.object(forKey: "Stillmatter.SidebarVisible") as? Bool ?? true
    private var inspectorPreferredVisible = UserDefaults.standard.object(forKey: "Stillmatter.InspectorVisible") as? Bool ?? false
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
        contextualAskServiceProvider: @escaping () -> ContextualAskService?,
        jobRecordsProvider: @escaping () -> [JobRecord],
        jobStatusProvider: @escaping () -> String,
        upcomingMeetingsProvider: @escaping () -> [TodayMeeting],
        meetingServiceProvider: @escaping () -> MeetingManagementService? = { nil },
        transcriptionComponentInstaller: TranscriptionComponentInstaller,
        onRebuildIndex: @escaping (@escaping (Result<Void, Error>) -> Void) -> Void
    ) {
        self.stateStore = stateStore
        self.settingsStore = settingsStore
        self.tasksInbox = tasksInbox
        self.searchIndexProvider = searchIndexProvider
        self.captureServiceProvider = captureServiceProvider
        self.meetingServiceProvider = meetingServiceProvider
        self.onReviewTitle = onReviewTitle
        self.teamsDetectionProvider = teamsDetectionProvider
        self.teamsRecordingDiagnosticProvider = teamsRecordingDiagnosticProvider
        self.onManualCapture = onManualCapture
        self.contextualAskServiceProvider = contextualAskServiceProvider
        self.jobRecordsProvider = jobRecordsProvider
        self.jobStatusProvider = jobStatusProvider
        self.upcomingMeetingsProvider = upcomingMeetingsProvider
        self.settingsFormView = SettingsFormView(
            settingsStore: settingsStore,
            transcriptionComponentInstaller: transcriptionComponentInstaller,
            onRebuildIndex: onRebuildIndex
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
        stateStore.observe { [weak self] in self?.render() }
        settingsStore.observe { [weak self] _ in self?.render() }
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
            stack.addArrangedSubview(button)
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
        container.addSubview(scrollView)
        container.addSubview(aboutButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: aboutButton.topAnchor, constant: -GraphiteFocusPresentation.Space.compact),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
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
        let browsers = [activityManagementView.browserView, meetingManagementView.browserView]
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

    private func installToolbarIfNeeded() {
        guard let window = view.window, window.toolbar !== toolbar else { return }
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbarStyle = .unified
        window.titleVisibility = .hidden
        window.toolbar = toolbar
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
        case .projectsActivities: "point.3.connected.trianglepath.dotted"
        case .reports: "chart.bar.doc.horizontal"
        case .askAI: "sparkles"
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
            jobBadge.frame.size = NSSize(width: 80, height: 22)
            item.label = "Job Status"
            item.view = jobBadge
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
            item.label = "Area Search"
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
        searchField.placeholderString = "Search in Today…"
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.delegate = self
        searchField.setAccessibilityLabel("Area Search")
        searchKindPopup.addItem(withTitle: "All types")
        SearchChunkKind.allCases.forEach { kind in
            searchKindPopup.addItem(withTitle: kind.displayName)
            searchKindPopup.lastItem?.representedObject = kind.rawValue
        }
        searchKindPopup.target = self
        searchKindPopup.action = #selector(searchKindChanged(_:))
        searchKindPopup.setAccessibilityLabel("Search result type")
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
        container.addSubview(activityManagementView)
        container.addSubview(settingsFormView)
        container.addSubview(contextualAskView)
        container.addSubview(reportsView)
        container.addSubview(searchResultsView)

        let bottomConstraints: [(NSView, NSLayoutConstraint)] = [
            (todayWorkbenchView, todayWorkbenchView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (captureRecordingView, captureRecordingView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (meetingManagementView, meetingManagementView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (proposalReviewView, proposalReviewView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.page)),
            (todoLedgerView, todoLedgerView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (activityManagementView, activityManagementView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (settingsFormView, settingsFormView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (contextualAskView, contextualAskView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
            (reportsView, reportsView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -GraphiteFocusPresentation.Space.large)),
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
            activityManagementView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            activityManagementView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            activityManagementView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            settingsFormView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            settingsFormView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            settingsFormView.widthAnchor.constraint(lessThanOrEqualToConstant: 680),
            settingsFormView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            contextualAskView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            contextualAskView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            contextualAskView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            reportsView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            reportsView.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            reportsView.widthAnchor.constraint(lessThanOrEqualToConstant: 760),
            reportsView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.page),
            searchResultsView.leadingAnchor.constraint(equalTo: contentTitle.leadingAnchor),
            searchResultsView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -GraphiteFocusPresentation.Space.large),
            searchResultsView.topAnchor.constraint(equalTo: contentTitle.bottomAnchor, constant: GraphiteFocusPresentation.Space.panel),
            container.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            container.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])

        return scrollView
    }

    private var currentPresentationEnvironment: GraphiteFocusEnvironment {
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
        activityManagementView.applyPresentation()
        contextualAskView.applyPresentation()
        reportsView.applyPresentation()
        if stateStore.state.selectedTab == .today {
            todayWorkbenchView.refresh(isVisible: true)
        }
    }

    private func render() {
        let state = stateStore.state
        if lastRenderedTab != state.selectedTab {
            showingNarrowDetail = false
            lastRenderedTab = state.selectedTab
            contentScrollView?.contentView.scroll(to: .zero)
            if let scroll = contentScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
        }
        contentTitle.stringValue = state.selectedTab == .meetings ? "" : state.selectedTab.rawValue
        let isSearching = state.selectedTab != .settings && isSearchPresented
            && !state.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        todayWorkbenchView.refresh(isVisible: state.selectedTab == .today && !isSearching)
        settingsFormView.isHidden = state.selectedTab != .settings || isSearching
        let showsActivityWorkspace = state.selectedTab == .projectsActivities && !isSearching
        let showsMeetingWorkspace = state.selectedTab == .meetings && !isSearching
        // Search occupies the detail canvas; browsers activate the adaptive content/list region.
        hasContentListRegion = usesAdaptiveFixtureRegions || showsActivityWorkspace || showsMeetingWorkspace
        hasInspectorRegion = usesAdaptiveFixtureRegions
        activityManagementView.refresh(isVisible: showsActivityWorkspace)
        meetingManagementView.refresh(isVisible: showsMeetingWorkspace)
        meetingViewportHeight?.isActive = showsMeetingWorkspace
        contentScrollView?.hasVerticalScroller = !showsMeetingWorkspace
        if showsMeetingWorkspace, let scroll = contentScrollView {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        proposalReviewView.refresh(isVisible: state.selectedTab == .today && !isSearching)
        todoLedgerView.refresh(isVisible: state.selectedTab == .tasks && !isSearching)
        captureRecordingView.refresh(isVisible: state.selectedTab == .recording && !isSearching)
        contextualAskView.isHidden = state.selectedTab != .askAI || isSearching
        reportsView.refresh(isVisible: state.selectedTab == .reports && !isSearching)
        searchResultsView.isHidden = !isSearching
        // Hidden views keep their Auto Layout constraints; only the visible page may size the document.
        for (page, constraint) in contentBottomConstraints {
            let shouldBeActive = !page.isHidden
            if constraint.isActive != shouldBeActive {
                constraint.isActive = shouldBeActive
            }
        }
        if isSearching {
            renderSearch(query: state.searchText, area: state.selectedTab)
        } else {
            pendingSearch?.cancel()
            pendingSearch = nil
            searchRevision += 1
            lastSearchRequest = nil
        }
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
        searchField.stringValue = state.searchText
        searchField.placeholderString = "Search in \(state.selectedTab.rawValue)…"
        compactSearchField.stringValue = state.searchText
        compactSearchField.placeholderString = searchField.placeholderString
        toolbarAreaLabel.stringValue = state.selectedTab.rawValue
        toolbarAreaLabel.setAccessibilityValue(state.selectedTab.rawValue)
        applyAdaptiveLayout()

        updateNavigationSelection()
    }

    @discardableResult
    func focusInboxItem(id: String) -> Bool {
        isSearchPresented = false
        stateStore.state.select(.today)
        contentScrollView?.documentView?.layoutSubtreeIfNeeded()
        if todayWorkbenchView.focusInboxItem(id: id) { return true }
        stateStore.refresh()
        contentScrollView?.documentView?.layoutSubtreeIfNeeded()
        if todayWorkbenchView.focusInboxItem(id: id) { return true }
        todayWorkbenchView.showUnavailableInboxItem(id: id)
        return false
    }

    private func renderSearch(query rawQuery: String, area: ShellTab) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedKind = (searchKindPopup.selectedItem?.representedObject as? String)
            .flatMap(SearchChunkKind.init(rawValue:))
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
        pendingSearch = Task.detached(priority: .userInitiated) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            let result = Result { try index.search(query, filter: SearchFilter(kinds: kinds), limit: 100) }
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

    private func searchKinds(for area: ShellTab) -> Set<SearchChunkKind>? {
        switch area {
        case .today: return [.todo, .meeting, .activity, .brief]
        case .recording: return []
        case .askAI: return nil
        case .meetings: return [.meeting, .summary, .transcript, .metadata]
        case .tasks: return [.todo]
        case .projectsActivities: return [.project, .activity]
        case .reports: return [.report, .brief]
        case .settings: return []
        }
    }

    private func todayWorkbenchState() -> TodayWorkbenchView.State {
        guard let tasksInbox = tasksInbox else {
            return .unavailable("The operational Inbox could not be opened.")
        }
        guard let rootURL = settingsStore.settings.stillmatterRootURL else {
            return .unavailable("Choose an Stillmatter root to load Inbox, Daily Brief, Queue, Meeting, and Activity context.")
        }

        do {
            return .loaded(try TodayDashboard(
                workspaceRootURL: rootURL,
                inbox: tasksInbox,
                searchIndex: searchIndexProvider(),
                recordingStatus: { [weak self] in
                    guard let snapshot = self?.captureServiceProvider()?.snapshot else { return "Not recording" }
                    return snapshot.state == .recording
                        ? "Recording \(snapshot.meetingTitle ?? "Meeting")"
                        : "Not recording"
                },
                jobStatus: jobStatusProvider,
                upcomingMeetings: upcomingMeetingsProvider
            ).load())
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func openWorkspaceFile(_ relativePath: String) {
        guard let rootURL = settingsStore.settings.stillmatterRootURL else {
            stateStore.state.select(.settings)
            return
        }
        WorkspaceSourceOpener.present(rootURL.appendingPathComponent(relativePath))
    }

    private func updateJobBadge(colors: GraphiteFocusPresentation.Colors) {
        let status = jobStatusProvider()
        let normalized = status.lowercased()
        let meaning: GraphiteFocusStatusMeaning = normalized.contains("fail")
            ? .destructive
            : (normalized.contains("running") || normalized.contains("queued") ? .attention : .informational)
        jobBadge.setStatus(status, meaning: meaning, colors: colors)
    }

    private func todoLedgerState() -> TodoLedgerView.State {
        guard let rootURL = settingsStore.settings.stillmatterRootURL else {
            return .unavailable("Choose an Stillmatter root in Settings to read canonical Todo Items.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unavailable("The configured Stillmatter root is not available. Choose an accessible workspace in Settings.")
        }
        do {
            let today = Self.todoDateFormatter.string(from: Date())
            return .loaded(try TodoItemIndex(workspaceRootURL: rootURL).loadTaskViews(today: today))
        } catch {
            return .failed(String(describing: error))
        }
    }

    private func openTodoItem(_ item: TodoItem) {
        guard let rootURL = settingsStore.settings.stillmatterRootURL else {
            stateStore.state.select(.settings)
            return
        }
        WorkspaceSourceOpener.present(rootURL.appendingPathComponent(item.location.relativePath))
    }

    private func applyAdaptiveLayout(availableWidth proposedWidth: CGFloat? = nil) {
        // Use the actual settled width after layout; a remembered resize proposal can be
        // stale after programmatic window sizing and hide the Meetings browser indefinitely.
        let width = proposedWidth ?? view.bounds.width
        guard width > 0 else { return }
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
            if stateStore.state.selectedTab == .meetings && workspaceSplitView.bounds.width >= 800 && contentListContainer.frame.width < 260 {
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
        current.forEach {
            split.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        desired.enumerated().forEach { index, region in
            region.isHidden = false
            split.insertArrangedSubview(region, at: index)
        }
    }

    private func configureAdaptiveFixtureRegions(_ enabled: Bool) {
        usesAdaptiveFixtureRegions = enabled
        hasContentListRegion = enabled || stateStore.state.selectedTab == .projectsActivities || stateStore.state.selectedTab == .meetings
        hasInspectorRegion = enabled
        inspectorPreferredVisible = enabled
        showingNarrowDetail = false
        lastAdaptiveLayout = nil
        applyAdaptiveLayout()
    }

    func prepareForWindowResize(to width: CGFloat) {
        requestedWindowWidth = width
        installToolbarIfNeeded()
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
        } else if width >= 900 && !toolbarItemsCompactedForWidth.isEmpty {
            toolbar.autosavesConfiguration = false
            for entry in toolbarItemsCompactedForWidth.sorted(by: { $0.index < $1.index }) {
                toolbar.insertItem(withItemIdentifier: entry.identifier, at: min(entry.index, toolbar.items.count))
            }
            toolbar.autosavesConfiguration = true
            toolbarItemsCompactedForWidth = []
        }
        // Collapse target regions before AppKit evaluates their fitting widths.
        applyAdaptiveLayout(availableWidth: width)
    }

    func validateReferenceShellLayout() {
        view.layoutSubtreeIfNeeded()
        installToolbarIfNeeded()
        view.window?.layoutIfNeeded()
        prepareForWindowResize(to: 1200)
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()

        precondition(
            abs(sidebarContainer.frame.width - AdaptiveShellLayout.sidebarWidth) < 1,
            "Icon rail must start at its fixed width"
        )
        let fixedSidebarWidth = sidebarContainer.frame.width
        splitView.setPosition(AdaptiveShellLayout.sidebarWidth * 2, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        precondition(abs(sidebarContainer.frame.width - fixedSidebarWidth) < 1, "Sidebar divider must stay fixed")
        sidebarPreferredVisible = false
        applyAdaptiveLayout()
        sidebarPreferredVisible = true
        applyAdaptiveLayout()
        view.layoutSubtreeIfNeeded()
        precondition(
            abs(sidebarContainer.frame.width - fixedSidebarWidth) < 1,
            "Sidebar width must remain fixed across visibility changes"
        )
        precondition(sidebarContainer.frame.height > 0, "Sidebar must have a visible non-zero frame")
        precondition(splitView.arrangedSubviews.count == 2 && splitView.arrangedSubviews[1].frame.width > 0, "Detail region must have a visible non-zero frame")
        precondition(sidebarTabs.count == 8 && navigationButtons.count == 8, "Navigation rail must show all eight areas")
        precondition(aboutButton.frame.minY >= 0 && aboutButton.frame.minY <= GraphiteFocusPresentation.Space.panel,
                     "About icon must remain at the bottom of the rail")
        if let todayButton = navigationButtons[.today] {
            let topInset = sidebarContainer.bounds.maxY - todayButton.convert(todayButton.bounds, to: sidebarContainer).maxY
            precondition((0..<140).contains(topInset), "Navigation icons must start at the top of the rail")
        }
        precondition(navigationButtons[stateStore.state.selectedTab]?.accessibilityValue() as? String == "Selected", "Navigation selection must follow shell state")
        precondition(contentTitle.stringValue == stateStore.state.selectedTab.rawValue, "Page Header must follow shell state")
        precondition(toolbarAreaLabel.stringValue == stateStore.state.selectedTab.rawValue, "Toolbar location must follow shell state")

        let identifiers = Set(toolbar.items.map(\.itemIdentifier.rawValue))
        [
            "Stillmatter.ToggleSidebar", "Stillmatter.CurrentArea", "Stillmatter.RecordingStatus",
            "Stillmatter.JobStatus", "Stillmatter.AreaSearch"
        ].forEach { precondition(identifiers.contains($0), "Toolbar is missing \($0)") }

        let removableToolbarItems = toolbar.items.enumerated().compactMap { index, item in
            item.itemIdentifier == .areaSearch || item.itemIdentifier == .currentArea ? index : nil
        }
        removableToolbarItems.sorted(by: >).forEach(toolbar.removeItem)
        focusAreaSearch(nil)
        precondition(compactSearchPopover.isShown, "Area Search menu command must work after toolbar customization")
        compactSearchPopover.close()
        toolbar.insertItem(withItemIdentifier: .currentArea, at: min(1, toolbar.items.count))
        toolbar.insertItem(withItemIdentifier: .areaSearch, at: toolbar.items.count)

        stateStore.state.select(.askAI)
        view.layoutSubtreeIfNeeded()
        precondition(contentTitle.stringValue == ShellTab.askAI.rawValue, "Navigation did not synchronize the Page Header")
        precondition(toolbarAreaLabel.stringValue == ShellTab.askAI.rawValue, "Navigation did not synchronize the toolbar")
        stateStore.state.select(.today)
    }

    func validateAdaptiveShellLayout(in window: NSWindow) {
        let originalSidebarPreference = sidebarPreferredVisible
        let originalInspectorPreference = inspectorPreferredVisible
        let originalMinimumContentSize = window.contentMinSize
        window.contentMinSize = NSSize(width: 720, height: 520)
        defer { window.contentMinSize = originalMinimumContentSize }
        sidebarPreferredVisible = true
        inspectorPreferredVisible = true
        configureAdaptiveFixtureRegions(true)
        stateStore.state.select(.today)
        todayWorkbenchView.validateFixtures()
        searchResultsView.validateFixtures()
        captureRecordingView.validateFixtures()
        todoLedgerView.validateFixtures()
        proposalReviewView.validateFixtures()
        activityManagementView.validateFixtures()
        settingsFormView.validateFixtures()
        reportsView.validateFixtures()
        searchResultsView.isHidden = false
        precondition(
            control(searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))),
            "Down Arrow in Area Search must move keyboard focus into available results"
        )
        precondition(searchResultsView.resultsHaveKeyboardFocus, "Area Search must hand keyboard focus to the results table")
        isSearchPresented = false
        render()
        precondition(!todayWorkbenchView.isHidden, "Today must use the Structured Workbench")
        stateStore.state.select(.meetings)
        view.layoutSubtreeIfNeeded()
        meetingManagementView.validateCaptionLayoutFixture()
        meetingManagementView.validateTimelineSelectionFixture()
        meetingManagementView.validateAudioTransportFixture()
        let meetingTop = meetingManagementView.convert(NSPoint(x: 0, y: meetingManagementView.bounds.height), to: view).y
        let detailTop = detailContainer.convert(.zero, to: view).y
        precondition(abs(meetingTop - detailTop) < 65, "Meeting caption must not sit below a blank shell header")
        captureRecordingView.validateVisibleLayout()
        stateStore.state.select(.projectsActivities)
        view.layoutSubtreeIfNeeded()
        precondition(
            !activityManagementView.isHidden && !activityManagementView.browserView.isHidden,
            "Activities must use the Precision Ledger browser and detail canvas"
        )
        precondition(hasContentListRegion, "Activities must activate the shell content/list region")
        stateStore.state.select(.tasks)
        precondition(!todoLedgerView.isHidden, "Tasks must use the Precision Ledger")
        stateStore.state.select(.projectsActivities)
        stateStore.state.searchText = "preserved draft"
        activityManagementView.setDraftsForValidation(output: "preserved output", log: "preserved log")
        let detailIdentity = ObjectIdentifier(detailContainer)
        let detailScrollOrigin = contentScrollView?.contentView.bounds.origin

        prepareForWindowResize(to: 1440)
        window.setContentSize(NSSize(width: 1440, height: 760))
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        applyAdaptiveLayout()
        precondition(lastAdaptiveLayout?.showsInspector == true, "Spacious layout must show the inspector")
        precondition(lastAdaptiveLayout?.showsSidebar == true, "Spacious layout must show the preferred sidebar")
        precondition(lastAdaptiveLayout?.detailMode == .listAndDetail, "Spacious layout must show list and detail")
        precondition(!contentListContainer.isHidden && !detailContainer.isHidden && !inspectorContainer.isHidden, "Spacious regions must have visible frames")

        prepareForWindowResize(to: 1200)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        applyAdaptiveLayout()
        precondition(lastAdaptiveLayout?.showsInspector == true, "Narrow rail must leave room for inspector at reference width")
        precondition(lastAdaptiveLayout?.showsSidebar == true, "Sidebar must remain after inspector collapse")
        precondition(lastAdaptiveLayout?.detailMode == .listAndDetail, "Reference layout must retain list/detail continuity")

        prepareForWindowResize(to: 720)
        window.setContentSize(NSSize(width: 720, height: 520))
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        applyAdaptiveLayout()
        precondition(abs(view.bounds.width - 720) < 2 && abs(view.bounds.height - 520) < 2, "The shell must reach the 720×520 Minimum Operable Window")
        precondition(lastAdaptiveLayout?.showsSidebar == true, "Navigation rail must remain available at minimum width")
        precondition(lastAdaptiveLayout?.detailMode == .listOnly, "Narrow layout must replace detail with the content list")
        focusAreaSearch(nil)
        precondition(compactSearchPopover.isShown, "Area Search must remain reachable in the compact toolbar")
        compactSearchPopover.close()
        precondition(abs(view.bounds.width - 720) < 2, "Compact Area Search must not force the window wider")
        precondition(workspaceSplitView.arrangedSubviews.count == 1 && workspaceSplitView.arrangedSubviews[0] === contentListContainer, "Narrow layout must initially present the list")

        activityManagementView.openSelectionForValidation()
        applyAdaptiveLayout()
        precondition(!narrowBackButton.isHidden, "Narrow detail must expose a native back affordance")
        precondition(workspaceSplitView.arrangedSubviews.count == 1 && workspaceSplitView.arrangedSubviews[0] === detailContainer, "Narrow navigation must be able to present detail")
        showNarrowList(nil)
        precondition(workspaceSplitView.arrangedSubviews.count == 1 && workspaceSplitView.arrangedSubviews[0] === contentListContainer, "Back must return to the narrow content list")
        configureAdaptiveFixtureRegions(false)
        isSearchPresented = true
        render()
        precondition(!searchResultsView.isHidden && workspaceSplitView.arrangedSubviews.contains { $0 === detailContainer },
                     "Area Search must remain visible in narrow Projects & Activities")
        isSearchPresented = false
        render()
        precondition(workspaceSplitView.arrangedSubviews.first === contentListContainer,
                     "Dismissing Search must restore the narrow Activity list")

        precondition(stateStore.state.selectedTab == .projectsActivities, "Resize must preserve the selected area")
        precondition(stateStore.state.searchText == "preserved draft", "Resize must preserve in-progress input")
        precondition(
            activityManagementView.hasDraftsForValidation(output: "preserved output", log: "preserved log"),
            "Resize must preserve in-progress Activity Item additions"
        )
        precondition(ObjectIdentifier(detailContainer) == detailIdentity, "Resize must preserve the detail canvas")
        precondition(contentScrollView?.contentView.bounds.origin == detailScrollOrigin, "Resize must preserve detail scroll position")

        configureAdaptiveFixtureRegions(false)
        sidebarPreferredVisible = originalSidebarPreference
        inspectorPreferredVisible = originalInspectorPreference
        stateStore.state.searchText = ""
        stateStore.state.select(.today)
        prepareForWindowResize(to: 1200)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        applyAdaptiveLayout()
    }

    func validateTabScrolling(in window: NSWindow) {
        prepareForWindowResize(to: 1200)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.layoutIfNeeded()
        stateStore.state.select(.tasks)
        let tallTask = todoLedgerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1100)
        tallTask.isActive = true
        defer { tallTask.isActive = false }
        view.layoutSubtreeIfNeeded()
        guard let scroll = contentScrollView, let document = scroll.documentView else {
            preconditionFailure("Missing detail scroller")
        }
        precondition(document.frame.height > scroll.contentView.bounds.height + 100, "Fixture must overflow on Tasks")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(scroll.contentView.bounds.minY > 100, "Fixture must scroll Tasks")
        stateStore.state.select(.today)
        view.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.minY == 0, "Today must start at the top after scrolling Tasks")
        stateStore.state.select(.reports)
        view.layoutSubtreeIfNeeded()
        precondition(document.frame.height <= scroll.contentView.bounds.height + 1, "Short Reports must not expose empty scrolling space")
        precondition(scroll.contentView.bounds.minY == 0, "Short Reports must start at the top")
        stateStore.state.select(.today)
        view.layoutSubtreeIfNeeded()
    }

    func validateSearchKeyboardFocus(in window: NSWindow, width: CGFloat = 720, completion: @escaping () -> Void) {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterSearchFocus-\(UUID().uuidString)")
        let vault = fixtureRoot.appendingPathComponent("Vault")
        do {
            try FileManager.default.createDirectory(at: vault.appendingPathComponent("Todos"), withIntermediateDirectories: true)
            try Data("# Todos\n\n## Queue\n\n- [ ] First planning item\n- [ ] Second planning item\n".utf8)
                .write(to: vault.appendingPathComponent("Todos/todo.md"))
            let index = try SearchIndex(databaseURL: fixtureRoot.appendingPathComponent("search.sqlite"), workspaceRootURL: vault)
            try index.startupScan()
            let previousProvider = searchIndexProvider
            searchIndexProvider = { index }
            stateStore.state.select(.today)
            stateStore.state.searchText = "planning"
            prepareForWindowResize(to: width)
            window.setContentSize(NSSize(width: width, height: 520))
            window.layoutIfNeeded()
            focusAreaSearch(nil)
            // Search is debounced; wait for the indexed fixture before exercising result focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                precondition(searchResultsView.resultCountForValidation == 2, "Fixture must produce two real search results")
                validateSearchKeyboardFocusWithFixture(in: window, width: width) {
                    self.searchIndexProvider = previousProvider
                    try? FileManager.default.removeItem(at: fixtureRoot)
                    completion()
                }
            }
        } catch {
            fatalError("Could not set up search focus fixture: \(error)")
        }
    }

    private func validateSearchKeyboardFocusWithFixture(in window: NSWindow, width: CGFloat, completion: @escaping () -> Void) {
        if width < 900 {
            precondition(compactSearchPopover.isShown, "Compact Area Search must be open for keyboard handoff")
        }
        let activeSearchField = width < 900 ? compactSearchField : searchField
        precondition(control(activeSearchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))),
                     "Down Arrow must hand keyboard focus to search results")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            precondition(searchResultsView.resultsHaveKeyboardFocus,
                         "Search results must retain keyboard focus after compact search closes")
            searchResultsView.validateArrowNavigationKeepsFocus()
            stateStore.refresh() // Model the periodic Teams/Job refresh while results own focus.
            precondition(searchResultsView.resultsHaveKeyboardFocus,
                         "A background status refresh must not return focus to Area Search")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                precondition(searchResultsView.resultsHaveKeyboardFocus,
                             "After two arrows and a pause, focus must not return to Area Search")
                if width < 900 {
                    focusAreaSearch(nil)
                    precondition(compactSearchPopover.isShown, "Compact search must open for dismissal test")
                    compactSearchPopover.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                        precondition(searchResultsView.resultsHaveKeyboardFocus,
                                     "Ordinary dismissal must return focus to the invoking results control")
                        validateSearchDismissalWithFixture(width: width)
                        completion()
                    }
                } else {
                    validateSearchDismissalWithFixture(width: width)
                    completion()
                }
            }
        }
    }

    private func validateSearchDismissalWithFixture(width: CGFloat) {
        searchResultsView.validateEscapeDismissesResults()
        precondition(!isSearchPresented && searchResultsView.isHidden, "Escape in results must close search")
        stateStore.state.searchText = ""
        focusAreaSearch(nil)
        precondition(isSearchPresented && searchResultsView.isHidden,
                     "Focus Area Search must not replace the page before a query is entered")
        let field = width < 900 ? compactSearchField : searchField
        precondition(control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))),
                     "Escape in Area Search must be handled")
        precondition(!isSearchPresented && searchResultsView.isHidden, "Escape in the search field must close search")
    }

    deinit {
        presentationObservers.forEach(NotificationCenter.default.removeObserver)
        presentationObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    private static let todoDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

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
            compactSearchField.setAccessibilityLabel("Area Search")
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 52))
            compactSearchField.frame = NSRect(x: 12, y: 12, width: 296, height: 28)
            controller.view.addSubview(compactSearchField)
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

    @objc private func showNarrowList(_ sender: Any?) {
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
        stateStore.refresh()
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
private final class DoubleClickAboutButton: NSButton {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount >= 2 else { return }
        super.mouseDown(with: event)
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleStillmatterSidebar = NSToolbarItem.Identifier("Stillmatter.ToggleSidebar")
    static let currentArea = NSToolbarItem.Identifier("Stillmatter.CurrentArea")
    static let sidebarDivider = NSToolbarItem.Identifier("Stillmatter.SidebarDivider")
    static let recordingStatus = NSToolbarItem.Identifier("Stillmatter.RecordingStatus")
    static let jobStatus = NSToolbarItem.Identifier("Stillmatter.JobStatus")
    static let areaSearch = NSToolbarItem.Identifier("Stillmatter.AreaSearch")
}
