import AppKit
import Combine
import SwiftUI
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

/// Meeting detail canvas. `browserView` is hosted independently in the shell's content-list region.
final class MeetingManagementView: NSView {
    let browserView = NSView()

    private let readModelProvider: () -> MeetingReadModel?
    private let mutationExecutorProvider: () -> MeetingMutationExecuting?
    private let playbackTransportProvider: () -> MeetingPlaybackTransport?
    // Owner-approved module-internal native-probe access; never exported as public API.
    // Assertion walkthroughs live in App/Validation rather than in this view.
    private(set) var meetingsModel: MeetingsModel!
    private var cancellables = Set<AnyCancellable>()
    private var isApplyingFeatureState = false
    private var hasPresentedSelectionDecision = false
    private var hasPresentedWorkspaceDecision = false
    private var renderedMeetingID: String?
    var renderedRows: [MeetingBrowserRow] = []
    private var lastRenderedDetail: MeetingBrowserDetail?
    private let openRecording: () -> Void
    private let openWorkspaceFile: (String) -> Void
    private let presentConfirmationAlert: (NSAlert) -> NSApplication.ModalResponse
    #if DEBUG
    var task05AlertResponse: ((NSAlert) -> NSApplication.ModalResponse)?
    private var task05DeferredRenders: [() -> Void] = []
    var task05HoldRenders = false
    var task05PendingRenders: Int { task05DeferredRenders.count }
    func task05DeliverRenders() {
        let work = task05DeferredRenders
        task05DeferredRenders.removeAll()
        work.forEach { $0() }
    }
    #endif
    private(set) var onOpenSelection: () -> Void = {}

    let table = NSTableView()
    let queryField = NSSearchField()
    let startDatePicker = NSDatePicker()
    let endDatePicker = NSDatePicker()
    let startDateEnabled = NSButton(checkboxWithTitle: "From", target: nil, action: nil)
    let endDateEnabled = NSButton(checkboxWithTitle: "To", target: nil, action: nil)
    let clearFiltersButton = NSButton(title: "Clear filters", target: nil, action: nil)
    let projectFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    let processingFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    let archiveFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    let filterStatus = NSTextField(labelWithString: "")
    let advancedFiltersButton = NSButton(title: "Filters", target: nil, action: nil)
    let advancedFilters = NSStackView()
    typealias MeetingQueue = MeetingQueueFilter
    var selectedQueue: MeetingQueue {
        get { meetingsModel?.queueFilter ?? .recorded }
        set { meetingsModel?.setQueueFilter(newValue) }
    }
    private(set) var queueButtons: [NSButton] = []

    let titleBar = NSStackView()
    let caption = NSStackView()
    let metadataBar = NSStackView()
    let eyebrow = NSTextField(labelWithString: "MEETING DETAIL")
    let meetingTitle = NSTextField(labelWithString: "")
    let overview = NSTextField(wrappingLabelWithString: "")
    let processingStatus = GraphiteFocusStatusLabel()
    let processingProgress = GraphiteFocusProgressStatusView()
    let statusBadge = NSView()
    private var summaryOverviewSection: MeetingOverviewHostingView?
    private var notesOverviewSection: MeetingOverviewHostingView?
    let textEditPanel = MeetingTextEditPanel()
    private var selectionSyncScheduled = false
    private var modalBaseVersion: WorkspaceFileVersion?
    private var modalField: EditableTextField?
    private var modalOriginalText = ""
    private enum EditableTextField { case notes, summary }
    let overviewPage = NSStackView()
    let timelinePage = NSStackView()
    let pinnedAudio = NSStackView()
    let pageSelector = NSSegmentedControl(labels: ["Overview", "Transcript"], trackingMode: .selectOne, target: nil, action: nil)
    let reviewPrompt = NSStackView()
    let reviewCount = NSTextField(labelWithString: "")
    let reviewButton = NSButton(title: "Review", target: nil, action: nil)
    let diagnosticsDisclosure = NSButton(checkboxWithTitle: "Processing & source files", target: nil, action: nil)
    let diagnostics = NSStackView()
    let decisionsContainer = NSStackView()
    let othersContainer = NSStackView()
    let questionsContainer = NSStackView()
    private var overviewScrollTop: NSLayoutConstraint?
    private var timelineScrollTop: NSLayoutConstraint?
    let timelineRows = NSStackView()
    let timelineNavigation = MeetingTimelineNavigation()
    let transcriptionButton = MeetingHeaderButton(title: "", target: nil, action: nil)
    let editSummaryTool = MeetingHeaderButton()
    let editNotesTool = MeetingHeaderButton()
    let moreButton = MeetingHeaderButton()
    let toolbar = NSStackView()
    private var outcomeCopy: [String: String] = [:]
    let files = NSStackView()
    let transcriptRows = NSStackView()
    let evidenceRows = NSStackView()
    let myActionsContainer = NSStackView()
    private weak var notesSection: NSView?
    private var actionRows: [String: MeetingOutcomeRow] = [:]
    private var pendingActionIDs: [String] = []
    private var actionReviewControls: [String: (edit: NSButton, review: NSButton)] = [:]
    private weak var actionReviewEmptyState: FocusableMeetingEmptyState?
    private var actionReviewFeedback: (meetingID: String, message: String)?
    private weak var actionReviewFeedbackLabel: GraphiteFocusStatusLabel?
    private var actionReviewFeedbackDismissal: DispatchWorkItem?
    private(set) var segmentLabels: [(MeetingTranscriptSegment, NSTextField)] = []
    private var evidenceTargets: [String: EvidenceTarget] = [:]
    private var outcomeSourceTargets: [String: OutcomeSourceTarget] = [:]
    let status = NSTextField(wrappingLabelWithString: "")
    let retryRows = NSStackView()
    let reprocessButton = NSButton(title: "Reprocess…", target: nil, action: nil)
    let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    let archiveButton = MeetingHeaderButton(title: "Archive", target: nil, action: nil)
    private(set) var retryFeedback: (meetingID: String, message: String)?
    private var restoredSelectionID: String?
    let openRecordingButton = NSButton(title: "Open Recording", target: nil, action: nil)
    let audioStatus = NSTextField(wrappingLabelWithString: "Recording Bundle unavailable")
    let playButton = MeetingPlaybackButton(frame: .zero)
    let waveform = MeetingWaveformView()
    let audioTime = NSTextField(labelWithString: "0:00 / 0:00")
    private var audioTimeWidth: NSLayoutConstraint?
    private var waveformWidth: NSLayoutConstraint?
    var audioPlayer: MeetingAudioPlayer? { (currentPlaybackTransport() as? MeetingAudioPlaybackController)?.activePlayer }
    private var audioSource: MeetingPlayback? { meetingsModel?.detail.playbackState.source }

    // The table owns one committed projection until reloadData finishes. Never interpret
    // an AppKit index against a newer model snapshot during deferred layout.
    var rows: [MeetingBrowserRow] { renderedRows }
    private var snapshotRenderScheduled = false
    var displayedDetail: MeetingBrowserDetail? { meetingsModel?.detail.detail }
    var selectedID: String? { meetingsModel?.selectedMeetingID }
    private var selectedDoorwayVersion: WorkspaceFileVersion? { displayedDetail?.doorwayVersion }
    private var selectedSummaryVersion: WorkspaceFileVersion? { meetingsModel?.detail.summaryDraft?.baseVersion }
    private let presentationMetrics: MeetingPresentationMetrics?

    init(
        readModelProvider: @escaping () -> MeetingReadModel?,
        mutationExecutorProvider: @escaping () -> MeetingMutationExecuting?,
        playbackTransportProvider: @escaping () -> MeetingPlaybackTransport?,
        openRecording: @escaping () -> Void,
        openWorkspaceFile: @escaping (String) -> Void,
        presentConfirmationAlert: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() },
        presentationMetrics: MeetingPresentationMetrics? = nil
    ) {
        self.readModelProvider = readModelProvider
        self.mutationExecutorProvider = mutationExecutorProvider
        self.playbackTransportProvider = playbackTransportProvider
        self.openRecording = openRecording
        self.openWorkspaceFile = openWorkspaceFile
        self.presentConfirmationAlert = presentConfirmationAlert
        self.presentationMetrics = presentationMetrics
        super.init(frame: .zero)
        meetingsModel = MeetingsModel(
            readModelProvider: { [weak self] in self?.currentReadModel() },
            mutationExecutorProvider: { [weak self] in self?.currentMutationExecutor() },
            playbackTransportProvider: { [weak self] in self?.currentPlaybackTransport() }
        )
        translatesAutoresizingMaskIntoConstraints = false
        buildBrowser()
        buildDetail()
        observeFeatureState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setOnOpenSelection(_ handler: @escaping () -> Void) {
        onOpenSelection = handler
    }

    private var featureIsVisible = false

    private func currentReadModel() -> MeetingReadModel? { readModelProvider() }

    private func currentMutationExecutor() -> MeetingMutationExecuting? { mutationExecutorProvider() }

    private func currentPlaybackTransport() -> MeetingPlaybackTransport? { playbackTransportProvider() }

    private(set) var refreshCountForValidation = 0

    func refresh(isVisible: Bool) {
        refreshCountForValidation += 1
        isHidden = !isVisible
        browserView.isHidden = !isVisible
        guard isVisible else {
            if featureIsVisible { meetingsModel.deactivate() }
            featureIsVisible = false
            restoredSelectionID = nil
            clearAudio()
            clearEvidence()
            return
        }
        if featureIsVisible { meetingsModel.refresh() }
        else {
            featureIsVisible = true
            meetingsModel.activate()
        }
    }

    private func buildBrowser() {
        browserView.translatesAutoresizingMaskIntoConstraints = false
        browserView.setAccessibilityIdentifier("meetings-browser")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("meeting"))
        column.title = "Meetings"
        table.addTableColumn(column)
        table.headerView = nil
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(openClickedMeeting(_:))
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = true
        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.setAccessibilityLabel("Meetings")

        queryField.placeholderString = "Filter meetings"
        queryField.setAccessibilityLabel("Filter meetings")
        queryField.setAccessibilityHelp("Filters the visible Meeting browser rows; it does not run indexed toolbar Search.")
        queryField.sendsSearchStringImmediately = true
        queryField.target = self
        queryField.action = #selector(filtersChanged(_:))

        [startDatePicker, endDatePicker].forEach {
            $0.datePickerStyle = .textField
            $0.datePickerElements = .yearMonthDay
            $0.target = self
            $0.action = #selector(filtersChanged(_:))
            $0.isEnabled = false
        }
        startDatePicker.setAccessibilityLabel("Meeting start date filter")
        endDatePicker.setAccessibilityLabel("Meeting end date filter")
        [startDateEnabled, endDateEnabled].forEach {
            $0.target = self
            $0.action = #selector(dateFilterChanged(_:))
        }
        clearFiltersButton.target = self
        clearFiltersButton.action = #selector(clearFilters(_:))

        projectFilter.setAccessibilityLabel("Meeting Project filter")
        processingFilter.setAccessibilityLabel("Meeting processing-state filter")
        [projectFilter, processingFilter].forEach {
            $0.target = self
            $0.action = #selector(filtersChanged(_:))
        }
        configureProcessingFilter()
        archiveFilter.setAccessibilityLabel("Meeting archive filter")
        archiveFilter.addItems(withTitles: ["Current Meetings", "Archived Meetings"])
        archiveFilter.target = self
        archiveFilter.action = #selector(filtersChanged(_:))

        let fromRow = NSStackView(views: [startDateEnabled, startDatePicker])
        let toRow = NSStackView(views: [endDateEnabled, endDatePicker])
        for row in [fromRow, toRow] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = GraphiteFocusPresentation.Space.compact
        }
        advancedFilters.orientation = .vertical
        advancedFilters.alignment = .leading
        advancedFilters.spacing = GraphiteFocusPresentation.Space.compact
        [projectFilter, processingFilter, archiveFilter, fromRow, toRow, clearFiltersButton].forEach {
            advancedFilters.addArrangedSubview($0)
        }
        advancedFilters.isHidden = true
        advancedFiltersButton.target = self
        advancedFiltersButton.action = #selector(toggleAdvancedFilters)
        advancedFiltersButton.setAccessibilityLabel("Show Meeting filters")
        filterStatus.font = GraphiteFocusPresentation.Typography.metadata
        GraphiteFocusOverflow.configureSecondaryMetadata(filterStatus, fullText: "")
        let heading = NSTextField(labelWithString: "Meetings")
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        let header = NSStackView(views: [heading, filterStatus])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .gravityAreas
        let searchRow = NSStackView(views: [queryField, advancedFiltersButton])
        searchRow.orientation = .horizontal
        searchRow.spacing = GraphiteFocusPresentation.Space.compact
        queueButtons = [("Recorded", MeetingQueue.recorded), ("Needs attention", .attention), ("Ready", .ready)].map { title, queue in
            let button = NSButton(title: title, target: self, action: #selector(selectQueue(_:)))
            button.tag = queue.rawValue
            button.bezelStyle = .recessed
            button.setAccessibilityIdentifier("meetings-queue-\(queue.rawValue)")
            return button
        }
        let queue = NSStackView(views: queueButtons)
        updateQueueButtons()
        queue.orientation = .horizontal
        queue.spacing = GraphiteFocusPresentation.Space.primitive
        let filters = NSStackView(views: [header, searchRow, queue, advancedFilters])
        filters.orientation = .vertical
        filters.alignment = .leading
        filters.spacing = GraphiteFocusPresentation.Space.compact
        filters.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = table
        scroll.translatesAutoresizingMaskIntoConstraints = false

        browserView.addSubview(filters)
        browserView.addSubview(scroll)
        NSLayoutConstraint.activate([
            filters.leadingAnchor.constraint(equalTo: browserView.leadingAnchor, constant: GraphiteFocusPresentation.Space.panel),
            filters.trailingAnchor.constraint(equalTo: browserView.trailingAnchor, constant: -GraphiteFocusPresentation.Space.panel),
            filters.topAnchor.constraint(equalTo: browserView.topAnchor, constant: GraphiteFocusPresentation.Space.panel),
            header.widthAnchor.constraint(equalTo: filters.widthAnchor),
            searchRow.widthAnchor.constraint(equalTo: filters.widthAnchor),
            queue.widthAnchor.constraint(lessThanOrEqualTo: filters.widthAnchor),
            queryField.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            scroll.leadingAnchor.constraint(equalTo: browserView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: browserView.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filters.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            scroll.bottomAnchor.constraint(equalTo: browserView.bottomAnchor)
        ])
    }

    private func buildDetail() {
        eyebrow.font = GraphiteFocusPresentation.Typography.caption
        eyebrow.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).accent
        eyebrow.setAccessibilityLabel("Meeting detail")
        meetingTitle.setAccessibilityIdentifier("meeting-detail")
        GraphiteFocusPageHeader.configureTitleLabel(meetingTitle)
        meetingTitle.alignment = .left
        overview.alignment = .left
        overview.font = GraphiteFocusPresentation.Typography.metadata
        overview.textColor = .secondaryLabelColor
        overview.maximumNumberOfLines = 0
        for group in [transcriptRows, evidenceRows] {
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = GraphiteFocusPresentation.Space.compact
        }
        files.orientation = .vertical
        files.alignment = .leading
        files.spacing = GraphiteFocusPresentation.Space.primitive
        status.maximumNumberOfLines = 0
        status.alignment = .left
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        retryRows.orientation = .vertical
        retryRows.alignment = .leading
        retryRows.spacing = GraphiteFocusPresentation.Space.compact
        reprocessButton.target = self
        reprocessButton.action = #selector(confirmReprocess)
        reprocessButton.setAccessibilityLabel("Reprocess selected Meeting")
        renameButton.target = self
        renameButton.action = #selector(confirmRename)
        renameButton.setAccessibilityLabel("Rename selected Meeting")
        archiveButton.target = self
        archiveButton.action = #selector(toggleArchive)
        archiveButton.setAccessibilityLabel("Archive selected Meeting")
        openRecordingButton.target = self
        openRecordingButton.action = #selector(openRecordingAction)
        openRecordingButton.isHidden = true

        playButton.target = self
        playButton.action = #selector(toggleAudio)
        playButton.widthAnchor.constraint(equalToConstant: 52).isActive = true
        playButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        playButton.toolTip = "Play Meeting audio"
        playButton.setAccessibilityLabel("Play Meeting audio")
        waveform.target = self
        waveform.action = #selector(seekAudio(_:))
        waveform.setAccessibilityLabel("Meeting audio position")
        waveform.toolTip = "Click or drag to seek Meeting audio"
        playButton.isEnabled = false
        waveform.isEnabled = false
        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.heightAnchor.constraint(equalToConstant: 52).isActive = true
        let transport = NSStackView(views: [playButton, waveform, audioTime])
        transport.orientation = .horizontal
        transport.alignment = .centerY
        transport.spacing = GraphiteFocusPresentation.Space.compact
        // NSSlider has no useful intrinsic horizontal width inside a leading-aligned stack.
        // Reserve the time label's width and let the seek surface fill the rest of the player.
        audioTimeWidth = audioTime.widthAnchor.constraint(equalToConstant: 116)
        waveformWidth = waveform.widthAnchor.constraint(equalTo: transport.widthAnchor,
            constant: -(52 + 116 + 2 * GraphiteFocusPresentation.Space.compact)) // graphite-focus-native-exception: playback face and time label reserve native transport geometry
        audioTimeWidth?.isActive = true
        waveformWidth?.isActive = true
        waveform.widthAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        audioStatus.font = GraphiteFocusPresentation.Typography.metadata
        audioStatus.alignment = .left
        audioTime.alignment = .left
        audioStatus.textColor = .secondaryLabelColor
        audioTime.font = GraphiteFocusPresentation.Typography.numeric
        let audioSection = NSStackView(views: [audioStatus, transport])
        audioSection.orientation = .vertical
        audioSection.alignment = .leading
        audioSection.spacing = GraphiteFocusPresentation.Space.compact
        transport.widthAnchor.constraint(equalTo: audioSection.widthAnchor).isActive = true
        waveform.setContentHuggingPriority(.defaultLow, for: .horizontal)
        waveform.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (button, symbol, label, selector, identifier) in [
            (transcriptionButton, "text.book.closed", "Transcript & recording", #selector(openTimeline), "meeting-open-transcription"),
            (editSummaryTool, "square.and.pencil", "Edit summary", #selector(editSummaryFromToolbar), "meeting-edit-summary"),
            (editNotesTool, "note.text", "Edit my notes", #selector(editNotesFromToolbar), "meeting-edit-notes"),
            (archiveButton, "archivebox", "Archive meeting", #selector(toggleArchive), "meeting-archive"),
            (moreButton, "ellipsis", "More meeting actions", #selector(showMeetingMenu(_:)), "meeting-more")
        ] {
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .medium))
            button.imagePosition = .imageOnly
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.target = self
            button.action = selector
            button.toolTip = label
            button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier(identifier)
            // Stack views may break an image-only NSButton's size constraint
            // while fitting other symbols. Give each native button a fixed
            // 36-point slot instead of asking the button to size the stack.
            let slot = NSView(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
            slot.translatesAutoresizingMaskIntoConstraints = false
            slot.widthAnchor.constraint(equalToConstant: 36).isActive = true
            slot.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.frame = slot.bounds
            button.autoresizingMask = [.width, .height]
            slot.addSubview(button)
            toolbar.addArrangedSubview(slot)
        }
        for button in [editSummaryTool, editNotesTool, archiveButton, transcriptionButton] {
            button.isHidden = true
            button.superview?.isHidden = true
        }
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = GraphiteFocusPresentation.Space.compact
        toolbar.setContentCompressionResistancePriority(.required, for: .horizontal)
        transcriptionButton.target = self
        transcriptionButton.action = #selector(openTimeline)
        transcriptionButton.setAccessibilityIdentifier("meeting-open-transcription")
        timelineRows.orientation = .vertical
        timelineRows.alignment = .leading
        timelineRows.spacing = GraphiteFocusPresentation.Space.compact
        timelinePage.orientation = .vertical
        timelinePage.alignment = .leading
        timelinePage.spacing = GraphiteFocusPresentation.Space.page
        // Regeneration remains in More; do not interrupt the transport-to-timeline hierarchy.
        pinnedAudio.orientation = .vertical
        pinnedAudio.alignment = .leading
        pinnedAudio.spacing = GraphiteFocusPresentation.Space.compact
        pinnedAudio.addArrangedSubview(section("Meeting audio", body: audioSection))
        pageSelector.target = self
        pageSelector.action = #selector(selectDetailPage(_:))
        pageSelector.selectedSegment = 0
        pageSelector.setAccessibilityLabel("Meeting page")
        reviewPrompt.orientation = .horizontal
        reviewPrompt.alignment = .centerY
        reviewPrompt.spacing = GraphiteFocusPresentation.Space.compact
        reviewCount.font = GraphiteFocusPresentation.Typography.sectionHeading
        reviewButton.target = self
        reviewButton.action = #selector(jumpToReview)
        reviewPrompt.addArrangedSubview(reviewCount)
        reviewPrompt.addArrangedSubview(reviewButton)
        reviewPrompt.isHidden = true
        diagnosticsDisclosure.target = self
        diagnosticsDisclosure.action = #selector(toggleDiagnostics)
        diagnostics.orientation = .vertical
        diagnostics.alignment = .leading
        diagnostics.spacing = GraphiteFocusPresentation.Space.compact
        diagnostics.isHidden = true
        for container in [decisionsContainer, othersContainer, questionsContainer] {
            container.orientation = .vertical
            container.alignment = .leading
        }
        timelinePage.addArrangedSubview(timelineRows)
        timelinePage.isHidden = true
        overviewPage.orientation = .vertical
        overviewPage.alignment = .leading
        overviewPage.spacing = GraphiteFocusPresentation.Space.page + GraphiteFocusPresentation.Space.compact
        overviewPage.edgeInsets = NSEdgeInsets(
            top: GraphiteFocusPresentation.Space.page + GraphiteFocusPresentation.Space.compact,
            left: GraphiteFocusPresentation.Space.panel,
            bottom: GraphiteFocusPresentation.Space.panel,
            right: GraphiteFocusPresentation.Space.panel
        )
        let titleGroup = NSStackView(views: [eyebrow, meetingTitle])
        titleGroup.orientation = .vertical
        titleGroup.alignment = .leading
        titleGroup.spacing = GraphiteFocusPresentation.Space.primitive
        titleGroup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleGroup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        meetingTitle.widthAnchor.constraint(lessThanOrEqualTo: titleGroup.widthAnchor).isActive = true
        let headerRow = GraphiteFocusPageHeader.makeTitleAndActionsRow(title: titleGroup, actions: toolbar)
        titleBar.addArrangedSubview(headerRow)
        titleBar.orientation = .vertical
        titleBar.alignment = .width
        titleBar.spacing = GraphiteFocusPresentation.Space.flush
        headerRow.widthAnchor.constraint(equalTo: titleBar.widthAnchor).isActive = true
        let notesSection = textSection("My notes")
        self.notesSection = notesSection
        [reviewPrompt, textSection("Summary"),
         decisionsContainer, myActionsContainer, othersContainer, notesSection, questionsContainer,
         retryRows, diagnosticsDisclosure, diagnostics, openRecordingButton].forEach { overviewPage.addArrangedSubview($0) }
        diagnostics.addArrangedSubview(section("Source files", body: files))
        metadataBar.addArrangedSubview(overview)
        metadataBar.orientation = .horizontal
        metadataBar.alignment = .centerY
        overview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = GraphiteFocusPresentation.Radius.compact
        statusBadge.layer?.borderWidth = 1
        processingStatus.translatesAutoresizingMaskIntoConstraints = false
        processingProgress.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.addSubview(processingStatus)
        statusBadge.addSubview(processingProgress)
        for stateView in [processingStatus, processingProgress] {
            NSLayoutConstraint.activate([
                stateView.leadingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: GraphiteFocusPresentation.Space.compact),
                stateView.trailingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: -GraphiteFocusPresentation.Space.compact),
                stateView.topAnchor.constraint(equalTo: statusBadge.topAnchor, constant: GraphiteFocusPresentation.Space.primitive),
                stateView.bottomAnchor.constraint(equalTo: statusBadge.bottomAnchor, constant: -GraphiteFocusPresentation.Space.primitive)
            ])
        }
        processingProgress.isHidden = true
        caption.addArrangedSubview(titleBar)
        caption.addArrangedSubview(metadataBar)
        caption.addArrangedSubview(statusBadge)
        caption.addArrangedSubview(pageSelector)
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = GraphiteFocusPresentation.Space.compact
        titleBar.widthAnchor.constraint(equalTo: caption.widthAnchor).isActive = true
        metadataBar.widthAnchor.constraint(lessThanOrEqualTo: caption.widthAnchor).isActive = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        for container in [myActionsContainer, decisionsContainer, othersContainer, questionsContainer] {
            container.orientation = .vertical
            container.alignment = .leading
            container.widthAnchor.constraint(equalTo: overviewPage.widthAnchor,
                constant: -2 * GraphiteFocusPresentation.Space.panel).isActive = true
        }
        let stack = MeetingDetailDocumentView(views: [overviewPage, timelinePage, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.page
        overviewPage.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        timelinePage.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        for page in [overviewPage, timelinePage] {
            for item in page.arrangedSubviews where item is NSStackView && item !== retryRows {
                let inset = page === overviewPage ? 2 * GraphiteFocusPresentation.Space.panel : 0
                item.widthAnchor.constraint(equalTo: page.widthAnchor, constant: -inset).isActive = true
            }
        }
        status.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.edgeInsets = NSEdgeInsets(top: GraphiteFocusPresentation.Space.primitive, left: 0, bottom: GraphiteFocusPresentation.Space.page, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        scroll.setAccessibilityIdentifier("meeting-detail-scroll")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pinnedAudio)
        addSubview(scroll)
        pinnedAudio.translatesAutoresizingMaskIntoConstraints = false
        overviewScrollTop = scroll.topAnchor.constraint(equalTo: pinnedAudio.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact)
        timelineScrollTop = scroll.topAnchor.constraint(equalTo: pinnedAudio.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphiteFocusPresentation.Space.panel),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GraphiteFocusPresentation.Space.panel),
            caption.topAnchor.constraint(equalTo: topAnchor, constant: GraphiteFocusPresentation.Space.compact),
            pinnedAudio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphiteFocusPresentation.Space.panel),
            pinnedAudio.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GraphiteFocusPresentation.Space.panel),
            pinnedAudio.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            pinnedAudio.arrangedSubviews[0].widthAnchor.constraint(equalTo: pinnedAudio.widthAnchor),
            overviewScrollTop!,
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
    }

    private func textSection(_ title: String) -> NSView {
        let card = MeetingOverviewHostingView(rootView: MeetingOverviewSection(title: title, editIdentifier: title == "Summary" ? "meeting-overview-edit-summary" : "meeting-overview-edit-notes", content: "", unavailable: "Content unavailable.",
            canEdit: false, expand: {}, edit: {}, copy: {}))
        card.translatesAutoresizingMaskIntoConstraints = false
        if title == "Summary" { summaryOverviewSection = card }
        else { notesOverviewSection = card }
        return card
    }

    private func section(_ title: String, body: NSView) -> NSView {
        let stack = NSStackView(views: [sectionHeading(title), body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.compact
        if title == "Meeting audio" {
            stack.edgeInsets = NSEdgeInsets(top: GraphiteFocusPresentation.Space.panel,
                left: GraphiteFocusPresentation.Space.panel,
                bottom: GraphiteFocusPresentation.Space.panel, right: GraphiteFocusPresentation.Space.panel)
            stack.wantsLayer = true
            stack.layer?.cornerRadius = GraphiteFocusPresentation.Radius.panel
            stack.layer?.backgroundColor = presentationColors.surfacePanel.cgColor
            stack.layer?.borderWidth = GraphiteFocusPresentation.Stroke.width
            stack.layer?.borderColor = presentationColors.structuralStroke.cgColor
            body.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * GraphiteFocusPresentation.Space.panel).isActive = true
        }
        return stack
    }

    private func sectionHeading(_ title: String) -> NSTextField {
        let heading = NSTextField(labelWithString: title)
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        heading.alignment = .left
        return heading
    }

    private func localControlRow(_ controls: [NSView]) -> NSStackView {
        let row = NSStackView(views: controls)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = GraphiteFocusPresentation.Space.compact
        controls.forEach(GraphiteFocusOverflow.protectTrailingControl)
        return row
    }

    @objc private func toggleAdvancedFilters() {
        advancedFilters.isHidden.toggle()
        advancedFiltersButton.title = advancedFilters.isHidden ? "Filters" : "Hide filters"
        advancedFiltersButton.setAccessibilityLabel(advancedFilters.isHidden ? "Show Meeting filters" : "Hide Meeting filters")
    }

    @objc private func selectQueue(_ sender: NSButton) {
        guard let queue = MeetingQueue(rawValue: sender.tag) else { return }
        meetingsModel.setQueueFilter(queue, resetProcessingFilter: true)
        processingFilter.selectItem(at: 0)
        updateQueueButtons()
        applyFilters()
    }

    func updateQueueButtons() {
        for button in queueButtons {
            button.state = button.tag == selectedQueue.rawValue ? .on : .off
            button.setAccessibilityValue(button.state == .on ? "Selected" : "Not selected")
        }
    }

    private func configureProcessingFilter() {
        processingFilter.removeAllItems()
        let options: [(String, MeetingProcessingFilter)] = [
            ("All states", .all), ("Live", .live), ("Processing", .processing),
            ("Needs attention", .needsAttention), ("Ready", .ready),
            ("Not finished", .notFinished), ("Unavailable", .unavailable)
        ]
        for (title, value) in options {
            processingFilter.addItem(withTitle: title)
            processingFilter.lastItem?.representedObject = value
        }
    }

    private func applyFilters() {
        updateQueueButtons()
        meetingsModel.updateFilters(currentFilters())
    }

    private func observeFeatureState() {
        meetingsModel.$snapshot.sink { [weak self] _ in self?.scheduleSnapshotRender() }
            .store(in: &cancellables)
        meetingsModel.$selectedMeetingID.sink { [weak self] _ in self?.scheduleSelectedRowsSync() }
            .store(in: &cancellables)
        meetingsModel.$selectedMeetingIDs.sink { [weak self] _ in self?.scheduleSelectedRowsSync() }
            .store(in: &cancellables)
        meetingsModel.$queueFilter.sink { [weak self] _ in
            guard let self else { return }
            self.updateQueueButtons()
            self.scheduleSnapshotRender()
        }.store(in: &cancellables)
        meetingsModel.$pendingSelectionDecision.sink { [weak self] pending in
            guard let self else { return }
            if pending && !self.hasPresentedSelectionDecision {
                self.hasPresentedSelectionDecision = true
                self.presentSelectionDecision()
            } else if !pending { self.hasPresentedSelectionDecision = false }
        }.store(in: &cancellables)
        meetingsModel.$pendingWorkspaceDecision.sink { [weak self] pending in
            guard let self else { return }
            if pending && !self.hasPresentedWorkspaceDecision {
                self.hasPresentedWorkspaceDecision = true
                self.presentWorkspaceDecision()
            } else if !pending { self.hasPresentedWorkspaceDecision = false }
        }.store(in: &cancellables)
        meetingsModel.detail.$detail.sink { [weak self] detail in
            guard let self else { return }
            if let detail { self.renderDetail(detail) }
            else { self.renderEmptyDetail() }
        }.store(in: &cancellables)
        meetingsModel.detail.$loadState.sink { [weak self] state in self?.renderLoadState(state) }
            .store(in: &cancellables)
        meetingsModel.detail.$playbackState.sink { [weak self] state in self?.renderPlaybackState(state) }
            .store(in: &cancellables)
        meetingsModel.detail.$mutationState.sink { [weak self] state in self?.renderMutationState(state) }
            .store(in: &cancellables)
        meetingsModel.detail.$page.sink { [weak self] page in
            // Published delivers the new page before its stored property changes.
            // Rendering must not call openTimeline/closeTimeline (which write page again).
            self?.renderPage(page)
        }.store(in: &cancellables)
        meetingsModel.$loadState.sink { [weak self] state in self?.renderBrowserLoadState(state) }
            .store(in: &cancellables)
    }

    private func scheduleSnapshotRender() {
        guard !snapshotRenderScheduled else { return }
        snapshotRenderScheduled = true
        // @Published emits before storing the new snapshot. The table datasource reads
        // visibleRows from the stored model, so render only after that setter unwinds.
        let render = { [weak self] in
            guard let self else { return }
            self.snapshotRenderScheduled = false
            self.applySnapshot(self.meetingsModel.snapshot)
        }
        #if DEBUG
        if task05HoldRenders { task05DeferredRenders.append(render); return }
        #endif
        DispatchQueue.main.async(execute: render)
    }

    func applySnapshot(_ snapshot: MeetingBrowserSnapshot?) {
        if let id = restoredSelectionID, snapshot?.visibleRows.contains(where: { $0.id == id && !$0.isArchived }) == true {
            restoredSelectionID = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.featureIsVisible, self.archiveFilter.indexOfSelectedItem == 0,
                      let index = self.rows.firstIndex(where: { $0.id == id }) else { return }
                self.table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                self.show(row: index)
            }
        }
        isApplyingFeatureState = true
        defer { isApplyingFeatureState = false }
        let currentRows = meetingsModel.visibleRows
        let shouldReload = renderedRows != currentRows
        configureProjectFilter(rows: snapshot?.availableRows ?? [])
        if shouldReload {
            renderedRows = currentRows
            table.reloadData()
            presentationMetrics?.recordViewUpdate()
        }
        updateFilterStatus(visibleCount: rows.count)
        syncSelectedRows(force: true)
        // A queue/filter can temporarily have no rows while a dirty selection decision
        // is open. Do not erase the visible draft before Save/Discard/Cancel resolves.
        if rows.isEmpty && !meetingsModel.detail.hasDirtyDrafts {
            closeTimeline()
            GraphiteFocusPageHeader.setTitle("No matching Meetings", on: meetingTitle)
            statusBadge.isHidden = true
            pinnedAudio.isHidden = true
            reviewPrompt.isHidden = true
            overview.stringValue = "Adjust the search or filters to see more Meetings."
            clearEvidence()
            showUnavailableOverviewSections()
            clearUnselectedProcessing()
            files.arrangedSubviews.forEach { files.removeArrangedSubview($0); $0.removeFromSuperview() }
            reprocessButton.isEnabled = false
            renameButton.isEnabled = false
            archiveButton.isEnabled = false
            toolbar.isHidden = true
        }
    }

    private func scheduleSelectedRowsSync() {
        guard !selectionSyncScheduled else { return }
        selectionSyncScheduled = true
        // Both @Published values emit before storage. Apply the committed ID set
        // once, after the selection mutation and AppKit's current callback finish.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionSyncScheduled = false
            self.syncSelectedRows(force: true)
        }
    }

    private func syncSelectedRows(force: Bool = false) {
        guard table.dataSource != nil, force || !isApplyingFeatureState else { return }
        let indices = IndexSet(rows.indices.filter { meetingsModel.selectedMeetingIDs.contains(rows[$0].id) })
        guard indices != table.selectedRowIndexes else { return }
        table.selectRowIndexes(indices, byExtendingSelection: false)
    }

    private func renderBrowserLoadState(_ state: MeetingDetailLoadState) {
        guard meetingsModel.snapshot == nil else { return }
        switch state {
        case .loading:
            status.stringValue = "Loading Meetings…"
        case let .unavailable(message):
            GraphiteFocusPageHeader.setTitle("Meetings unavailable", on: meetingTitle)
            overview.stringValue = "Choose a workspace in Settings to see your Meetings."
            status.stringValue = message
        case let .failed(message):
            GraphiteFocusPageHeader.setTitle("Meetings unavailable", on: meetingTitle)
            status.stringValue = message
        case .idle, .loaded: break
        }
    }

    private func renderLoadState(_ state: MeetingDetailLoadState) {
        switch state {
        case .loading where meetingsModel.detail.isShowingStaleDetail:
            status.stringValue = "Refreshing this Meeting; the displayed detail is stale."
        case .loading:
            status.stringValue = "Loading Meeting detail…"
        case let .unavailable(message), let .failed(message):
            if textEditPanel.isOpen { textEditPanel.showError(message + " Your text is still here.", conflict: true) }
            status.stringValue = meetingsModel.detail.isShowingStaleDetail
                ? "\(message) Showing stale detail for this Meeting."
                : message
        case .idle, .loaded:
            break
        }
    }

    private func renderMutationState(_ state: MeetingMutationState) {
        switch state {
        case .idle: break
        case let .running(message): status.stringValue = message
        case let .succeeded(message): status.stringValue = message
        case let .failed(message, conflict):
            status.stringValue = conflict ? "\(message) The Meeting changed elsewhere; your draft is preserved." : message
        }
    }

    private func renderEmptyDetail() {
        renderedMeetingID = nil
        lastRenderedDetail = nil
        displayedDetailPlaceholder()
        if meetingsModel.snapshot != nil && rows.isEmpty {
            GraphiteFocusPageHeader.setTitle("No matching Meetings", on: meetingTitle)
            overview.stringValue = "Adjust the search or filters to see more Meetings."
        } else {
            overview.stringValue = "Select a Meeting to see its details."
        }
        showUnavailableOverviewSections()
        clearUnselectedProcessing()
    }

    private func clearUnselectedProcessing() {
        retryRows.arrangedSubviews.forEach { retryRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        summaryOverviewSection?.isHidden = true
        notesOverviewSection?.isHidden = true
        diagnosticsDisclosure.isHidden = true
        diagnostics.isHidden = true
    }

    private func displayedDetailPlaceholder() {
        GraphiteFocusPageHeader.setTitle("Select a Meeting", on: meetingTitle)
        statusBadge.isHidden = true
        pinnedAudio.isHidden = true
        reviewPrompt.isHidden = true
        toolbar.isHidden = true
        clearEvidence()
    }

    private func presentSelectionDecision() {
        let alert = NSAlert()
        alert.messageText = "Save Meeting edits before changing selection?"
        alert.informativeText = "Your notes or summary have unsaved changes."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        let response = presentConfirmationAlert(alert)
        let decision: MeetingSelectionDecision = response == .alertFirstButtonReturn ? .save
            : response == .alertSecondButtonReturn ? .discard : .cancel
        meetingsModel.resolvePendingSelection(decision) { [weak self] result in
            guard let self, case let .failure(error) = result else { return }
            self.resolveSaveFailure(error, pendingSelection: true)
        }
    }

    var hasDirtyWorkspaceDraftForPreparation: Bool { meetingsModel.detail.hasDirtyDrafts }

    /// Called before Settings commits the new root, including when Meetings is hidden.
    func prepareWorkspaceChange(completion: @escaping (Bool) -> Void) {
        guard meetingsModel.detail.hasDirtyDrafts else { completion(true); return }
        let alert = NSAlert()
        alert.messageText = "Save Meeting edits before changing workspace?"
        alert.informativeText = "The current workspace stays active until edits are resolved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Current Workspace")
        #if DEBUG
        let response = task05AlertResponse?(alert) ?? presentConfirmationAlert(alert)
        #else
        let response = presentConfirmationAlert(alert)
        #endif
        switch response {
        case .alertFirstButtonReturn:
            meetingsModel.detail.saveDirtyDrafts { [weak self] result in
                switch result {
                case .success: completion(true)
                case let .failure(error):
                    self?.resolveSaveFailure(error, pendingSelection: true)
                    completion(false)
                }
            }
        case .alertSecondButtonReturn:
            meetingsModel.detail.discardDrafts()
            completion(true)
        default: completion(false)
        }
    }

    private func presentWorkspaceDecision() {
        let alert = NSAlert()
        alert.messageText = "Save Meeting edits before changing workspace?"
        alert.informativeText = "The workspace changed while this Meeting had unsaved edits."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Current Workspace")
        let response = presentConfirmationAlert(alert)
        let decision: MeetingSelectionDecision = response == .alertFirstButtonReturn ? .save
            : response == .alertSecondButtonReturn ? .discard : .cancel
        meetingsModel.resolvePendingWorkspaceChange(decision) { [weak self] result in
            guard let self, case let .failure(error) = result else { return }
            self.resolveSaveFailure(error, pendingSelection: false)
        }
    }

    private func resolveSaveFailure(_ error: Error, pendingSelection: Bool) {
        let alert = NSAlert()
        alert.messageText = "Could not save Meeting edits"
        alert.informativeText = "\(error.localizedDescription) Your draft is still available."
        alert.addButton(withTitle: "Reload Latest")
        alert.addButton(withTitle: "Keep Editing")
        #if DEBUG
        let response = task05AlertResponse?(alert) ?? presentConfirmationAlert(alert)
        #else
        let response = presentConfirmationAlert(alert)
        #endif
        if response == .alertFirstButtonReturn {
            meetingsModel.detail.refreshSelectedDetail { [weak self] result in
                guard let self else { return }
                if case .success = result {
                    self.meetingsModel.detail.reloadDraftsAfterConfirmation()
                    if pendingSelection { self.meetingsModel.resolvePendingSelection(.discard) }
                    else { self.meetingsModel.resolvePendingWorkspaceChange(.discard) }
                }
            }
        } else if pendingSelection {
            meetingsModel.resolvePendingSelection(.cancel)
        } else {
            meetingsModel.resolvePendingWorkspaceChange(.cancel)
        }
    }


    private func configureProjectFilter(rows: [MeetingBrowserRow]) {
        let selected = projectFilter.selectedItem?.representedObject as? String
        let projects = Set(rows.compactMap(\.project))
        let currentProjects = Set(projectFilter.itemArray.dropFirst().compactMap { $0.representedObject as? String })
        guard projects != currentProjects || projectFilter.numberOfItems != currentProjects.count + 1 else { return }
        projectFilter.removeAllItems()
        projectFilter.addItem(withTitle: "All Projects")
        for project in projects.sorted() {
            projectFilter.addItem(withTitle: project)
            projectFilter.lastItem?.representedObject = project
        }
        if let selected, let index = projectFilter.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) {
            projectFilter.selectItem(at: index)
        } else if selected != nil {
            projectFilter.selectItem(at: 0)
            var filters = meetingsModel.filters
            filters.project = nil
            meetingsModel.updateFilters(filters)
        }
    }

    func updateFilterStatus(visibleCount: Int) {
        let filters = activeFilterDescriptions()
        let countText = visibleCount == 1 ? "1 Meeting" : "\(visibleCount) Meetings"
        let detail = filters.isEmpty ? "No list filters" : filters.joined(separator: " · ")
        filterStatus.stringValue = "\(visibleCount == 0 ? "No matching Meetings" : countText) • \(detail)"
        GraphiteFocusOverflow.configureSecondaryMetadata(filterStatus, fullText: filterStatus.stringValue)
        filterStatus.setAccessibilityValue(filterStatus.stringValue)
    }

    private func activeFilterDescriptions() -> [String] {
        var filters: [String] = ["Queue: \(queueTitle(selectedQueue))"]
        let query = queryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { filters.append("Text: “\(query)”") }
        if let project = projectFilter.selectedItem?.representedObject as? String { filters.append("Project: \(project)") }
        if let processing = processingFilter.selectedItem?.representedObject as? MeetingProcessingFilter,
           processing != .all,
           let title = processingFilter.titleOfSelectedItem {
            filters.append("State: \(title)")
        }
        if archiveFilter.indexOfSelectedItem == 1 { filters.append("Archived") }
        if startDateEnabled.state == .on { filters.append("From: \(Self.filterDateFormatter.string(from: startDatePicker.dateValue))") }
        if endDateEnabled.state == .on { filters.append("To: \(Self.filterDateFormatter.string(from: endDatePicker.dateValue))") }
        return filters
    }

    private func queueTitle(_ queue: MeetingQueue) -> String {
        switch queue {
        case .recorded: return "Recorded"
        case .attention: return "Needs attention"
        case .ready: return "Ready"
        }
    }

    private func currentFilters() -> MeetingBrowserFilters {
        MeetingBrowserFilters(
            query: queryField.stringValue,
            startDate: startDateEnabled.state == .on ? startDatePicker.dateValue : nil,
            endDate: endDateEnabled.state == .on ? endDatePicker.dateValue : nil,
            project: projectFilter.selectedItem?.representedObject as? String,
            processing: (processingFilter.selectedItem?.representedObject as? MeetingProcessingFilter) ?? .all,
            archived: archiveFilter.indexOfSelectedItem == 1
        )
    }

    func show(row index: Int) {
        guard rows == meetingsModel.visibleRows, rows.indices.contains(index) else { return }
        let selectedIDs = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        _ = meetingsModel.select(meetingID: rows[index].id, selectedIDs: selectedIDs)
    }

    private func renderDetail(_ selected: MeetingBrowserDetail) {
            refreshModalText(from: selected)
            isApplyingFeatureState = true
            defer { isApplyingFeatureState = false }
            let changedMeeting = renderedMeetingID != selected.row.id
            renderedMeetingID = selected.row.id
            waveform.colors = presentationColors
            playButton.updateAppearance()
            GraphiteFocusPageHeader.setTitle(selected.row.title, on: meetingTitle)
            statusBadge.isHidden = false
            pinnedAudio.isHidden = false
            configureMeetingState(selected.row)
            overview.stringValue = detailOverview(selected)
            if changedMeeting {
                timelineNavigation.jump = nil
                closeTimeline()
            }
            summaryOverviewSection?.isHidden = false
            notesOverviewSection?.isHidden = false
            diagnosticsDisclosure.isHidden = false
            updateOverviewSections(selected)
            let evidenceChanged = lastRenderedDetail != selected || changedMeeting
            lastRenderedDetail = selected
            if evidenceChanged { renderEvidence(selected) }
            toolbar.isHidden = false
            transcriptionButton.isEnabled = true
            editSummaryTool.isEnabled = selectedSummaryVersion != nil && !selected.row.isArchived
            notesSection?.isHidden = false
            editNotesTool.isEnabled = selected.notesVersion != nil && !selected.row.isArchived
            openRecordingButton.isHidden = selected.row.captureState != .live
            let pending = selected.myActionItems.filter { $0.reviewState == .pending }.count
            reviewPrompt.isHidden = pending == 0
            reviewCount.stringValue = "\(pending) action\(pending == 1 ? "" : "s") need review"
            renderArtifacts(selected.artifacts)
            renderRetryActions(selected)
            let canChangeFolder = selected.row.captureState == .stopped && !selected.jobs.contains(where: { $0.status == .queued || $0.status == .running })
            reprocessButton.isEnabled = canChangeFolder && !meetingsModel.isDirty
            renameButton.isEnabled = canChangeFolder && selected.doorwayVersion != nil && !meetingsModel.isDirty
            archiveButton.title = selected.row.isArchived ? "Restore" : "Archive"
            let archiveName = selected.row.isArchived ? "Restore meeting" : "Archive meeting"
            archiveButton.image = NSImage(systemSymbolName: selected.row.isArchived ? "arrow.uturn.backward" : "archivebox", accessibilityDescription: archiveName)
            archiveButton.toolTip = archiveName
            archiveButton.setAccessibilityLabel(archiveName)
            archiveButton.isEnabled = selected.row.captureState != .live
            status.stringValue = retryFeedback?.meetingID == selected.row.id ? retryFeedback!.message : ""
            presentationMetrics?.recordViewUpdate()
    }

    func clearAudio() {
        meetingsModel?.detail.stopPlayback()
        renderPlaybackState(meetingsModel?.detail.playbackState ?? MeetingPlaybackTransportState())
    }

    func bindAudio(_ playback: MeetingPlayback) {
        currentPlaybackTransport()?.load(playback)
    }

    private func renderPlaybackState(_ state: MeetingPlaybackTransportState) {
        let availabilityChanged = waveform.isEnabled != state.isAvailable
        waveform.levels = state.waveform.map { CGFloat($0) }
        waveform.doubleValue = state.position
        waveform.maxValue = max(state.duration, 1)
        waveform.isEnabled = state.isAvailable
        playButton.isEnabled = state.isAvailable
        playButton.title = state.isPlaying ? "Pause" : "Play"
        playButton.needsDisplay = true
        playButton.toolTip = state.isPlaying ? "Pause Meeting audio" : "Play Meeting audio"
        playButton.setAccessibilityLabel(playButton.toolTip)
        audioTime.stringValue = "\(timeLabel(state.position)) / \(timeLabel(state.duration))"
        let labelWidth: CGFloat = state.duration >= 3600 ? 180 : 116
        audioTimeWidth?.constant = labelWidth
        waveformWidth?.constant = -(52 + labelWidth + 2 * GraphiteFocusPresentation.Space.compact) // graphite-focus-native-exception: reserve native playback face and measured time label width
        if let source = state.source {
            audioStatus.stringValue = state.errorMessage ?? source.message
        } else {
            audioStatus.stringValue = "Recording Bundle unavailable. Check the recording media location."
        }
        // Playback availability arrives asynchronously after detail rendering. Rebuild
        // evidence affordances on that transition, not on every playback timer tick.
        if availabilityChanged {
            // @Published delivers before its stored value changes; evidence reads the
            // committed feature state. Recheck identity after yielding to publication.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.featureIsVisible, let detail = self.displayedDetail,
                      self.meetingsModel.detail.playbackState.source == detail.playback else { return }
                self.renderEvidence(detail)
            }
        }
        updateActiveSegment(at: state.source == nil ? nil : state.position)
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unknown" }
        let whole = Int(min(seconds, Double(Int.max / 120)))
        if whole >= 3600 { return String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) }
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }

    @objc private func toggleAudio() { meetingsModel.detail.togglePlayback() }

    @objc private func seekAudio(_ sender: NSSlider) { meetingsModel.detail.seekPlayback(to: sender.doubleValue) }

    private func detailOverview(_ detail: MeetingBrowserDetail) -> String {
        var lines: [String] = detail.row.isArchived ? ["Archived"] : []
        if let date = detail.row.startedAt { lines.append("\(date.formatted(date: .abbreviated, time: .shortened))") }
        if let project = detail.row.project { lines.append("Project: \(project)") }
        if let job = detail.job {
            lines.append("Job: \(job.title) — \(job.status.rawValue)")
            if let stage = job.stage { lines.append("Stage: \(stage)") }
            if let error = job.error { lines.append("Error: \(error)") }
        }
        return lines.joined(separator: "  ·  ")
    }

    var presentationColors: GraphiteFocusPresentation.Colors {
        GraphiteFocusPresentation.Colors(environment: .system(window: window))
    }

    private func configureMeetingState(_ row: MeetingBrowserRow) {
        let failed = row.job?.status == .failed
        let isProcessing = row.processingState == .processing && !failed
        processingStatus.isHidden = isProcessing
        processingProgress.isHidden = !isProcessing
        if isProcessing {
            let stage = row.job?.stage.map { "Stage: \($0)" } ?? "Work in progress"
            processingProgress.configure(title: "Processing", value: nil,
                                         valueDescription: stage, colors: presentationColors)
            let colors = presentationColors
            statusBadge.layer?.backgroundColor = colors.surfacePanel.cgColor
            statusBadge.layer?.borderColor = colors.accent.withAlphaComponent(0.48).cgColor
        } else {
            let meaning = statusMeaning(for: row)
            processingStatus.setStatus(statusTitle(for: row), meaning: meaning, colors: presentationColors)
            styleStatusBadge(meaning: meaning)
        }
    }

    func styleStatusBadge(meaning: GraphiteFocusStatusMeaning) {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        let tint = meaning.color(in: colors)
        let fill = colors.surfacePanel
        // Meeting readiness is the sole bounded violet status exception.
        processingStatus.textColor = meaning == .success ? colors.accent : tint
        statusBadge.layer?.backgroundColor = fill.cgColor
        statusBadge.layer?.borderColor = (meaning == .success ? colors.accent : tint).withAlphaComponent(0.48).cgColor
    }

    func statusMeaning(for row: MeetingBrowserRow) -> GraphiteFocusStatusMeaning {
        if row.job?.status == .failed { return .destructive }
        switch row.processingState {
        case .ready: return .success
        case .live, .needsAttention: return .attention
        case .processing, .unavailable: return .informational
        }
    }

    private func statusTitle(for row: MeetingBrowserRow) -> String {
        row.job?.status == .failed ? "Job failed · \(row.processingState.displayName)" : row.processingState.displayName
    }

    private func statusText(for row: MeetingBrowserRow) -> String {
        if row.processingState == .processing, row.job?.status != .failed {
            return "Processing, \(row.job?.stage.map { "stage \($0)" } ?? "work in progress")"
        }
        return "\(statusMeaning(for: row).symbol) \(statusTitle(for: row))"
    }

    private func meetingSymbol(_ name: String, label: String, color: NSColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = color
        view.toolTip = label
        view.setAccessibilityLabel(label)
        view.widthAnchor.constraint(equalToConstant: 14).isActive = true
        view.heightAnchor.constraint(equalToConstant: 14).isActive = true
        return view
    }

    @objc private func selectDetailPage(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 1 { openTimeline() } else { closeTimeline() }
    }

    @objc private func toggleDiagnostics() {
        diagnostics.isHidden = diagnosticsDisclosure.state != .on
    }

    @objc private func jumpToReview() {
        guard !pendingActionIDs.isEmpty else { return }
        if meetingsModel.detail.page != .overview { closeTimeline() }
        if let review = actionReviewControls[pendingActionIDs[0]]?.review {
            review.scrollToVisible(review.bounds)
            window?.makeFirstResponder(review)
        }
    }

    @objc func openTimeline() {
        if meetingsModel.detail.page != .transcript { meetingsModel.detail.setPage(.transcript) }
        renderPage(.transcript)
    }

    @objc func closeTimeline() {
        if meetingsModel.detail.page != .overview { meetingsModel.detail.setPage(.overview) }
        renderPage(.overview)
    }

    private func renderPage(_ page: MeetingDetailPage) {
        let isTranscript = page == .transcript
        overviewPage.isHidden = isTranscript
        status.isHidden = isTranscript
        timelinePage.isHidden = !isTranscript
        overviewScrollTop?.isActive = !isTranscript
        timelineScrollTop?.isActive = isTranscript
        pageSelector.selectedSegment = isTranscript ? 1 : 0
    }

    private func showUnavailableOverviewSections() {
        summaryOverviewSection?.update(MeetingOverviewSection(title: "Summary", editIdentifier: "meeting-overview-edit-summary", content: "", unavailable: "No meeting selected.",
            canEdit: false, expand: {}, edit: {}, copy: {}))
        notesOverviewSection?.update(MeetingOverviewSection(title: "My notes", editIdentifier: "meeting-overview-edit-notes", content: "", unavailable: "No meeting selected.",
            canEdit: false, expand: {}, edit: {}, copy: {}))
    }

    private func beginSummaryEditing() { beginTextEditing(.summary) }
    private func beginNotesEditing() { beginTextEditing(.notes) }

    private func beginTextEditing(_ field: EditableTextField) {
        guard let detail = displayedDetail, let window, !textEditPanel.isOpen, !detail.row.isArchived,
              selectedID == detail.row.id, !meetingsModel.detail.hasDirtyDrafts else { return }
        let text: String
        switch field {
        case .summary:
            guard detail.summaryVersion != nil else { return }
            text = detail.summary?.summary ?? ""
            meetingsModel.detail.beginEditingSummary()
        case .notes:
            guard detail.notesVersion != nil else { return }
            text = detail.humanNotes
            meetingsModel.detail.beginEditingNotes()
        }
        let meetingID = detail.row.id
        modalBaseVersion = field == .summary ? detail.summaryVersion : detail.notesVersion
        modalField = field
        modalOriginalText = text
        textEditPanel.present(over: window, field: field == .summary ? "Summary" : "My notes",
                              meeting: detail.row.title, text: text,
                              onChange: { [weak self] text in
            guard let self, self.selectedID == meetingID else { return }
            if field == .summary { self.meetingsModel.detail.updateSummaryDraft(text) }
            else { self.meetingsModel.detail.updateNotesDraft(text) }
        }, onSave: { [weak self] text in
            self?.saveModalText(field, meetingID: meetingID, text: text)
        }, onCancel: { [weak self] in
            guard let self else { return }
            self.meetingsModel.detail.discardDrafts()
            self.modalBaseVersion = nil
            self.modalField = nil
            self.textEditPanel.finish()
        }, onReload: { [weak self] in
            self?.reloadModalText(field, meetingID: meetingID)
        })
    }

    /// Refresh a clean editor immediately; a dirty editor keeps its original base and draft.
    private func refreshModalText(from detail: MeetingBrowserDetail) {
        guard textEditPanel.isOpen, let field = modalField else { return }
        let latestVersion = field == .summary ? detail.summaryVersion : detail.notesVersion
        guard latestVersion != modalBaseVersion else { return }
        if textEditPanel.text == modalOriginalText {
            let latest = field == .summary ? detail.summary?.summary ?? "" : detail.humanNotes
            textEditPanel.showLatest(latest)
            modalOriginalText = latest
            modalBaseVersion = latestVersion
        } else {
            let name = field == .summary ? "Summary" : "My Notes"
            textEditPanel.showError("\(name) changed while the editor was open. Your draft is preserved. Choose Reload Latest to replace it with the saved content, or Cancel.", conflict: true)
        }
    }

    private func saveModalText(_ field: EditableTextField, meetingID: String, text: String) {
        guard selectedID == meetingID else {
            textEditPanel.showError("The selected Meeting changed. Cancel to leave this editor.", conflict: false)
            return
        }
        if field == .summary { meetingsModel.detail.updateSummaryDraft(text) }
        else { meetingsModel.detail.updateNotesDraft(text) }
        let dirty = field == .summary ? meetingsModel.detail.summaryDraft?.isDirty == true
                                      : meetingsModel.detail.notesDraft?.isDirty == true
        guard dirty else {
            meetingsModel.detail.discardDrafts()
            modalBaseVersion = nil
            modalField = nil
            textEditPanel.finish()
            return
        }
        textEditPanel.setSaving(true)
        let completion: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, self.textEditPanel.isOpen else { return }
            switch result {
            case .success:
                self.modalBaseVersion = nil
                self.modalField = nil
                self.textEditPanel.finish()
                self.status.stringValue = field == .summary ? "Summary saved." : "Notes saved."
            case let .failure(error):
                let conflict: Bool
                if case .failed(_, conflict: true) = self.meetingsModel.detail.mutationState { conflict = true }
                else if case .malformed = error as? MeetingManagementError { conflict = true }
                else { conflict = false }
                self.textEditPanel.showError("Could not save: \(error.localizedDescription). Your text is still here.", conflict: conflict)
            }
        }
        if field == .summary { meetingsModel.detail.saveSummary(completion: completion) }
        else { meetingsModel.detail.saveNotes(completion: completion) }
    }

    private func reloadModalText(_ field: EditableTextField, meetingID: String) {
        guard selectedID == meetingID else { return }
        textEditPanel.setSaving(true)
        meetingsModel.detail.refreshSelectedDetail { [weak self] result in
            guard let self, self.textEditPanel.isOpen, self.selectedID == meetingID else { return }
            switch result {
            case .success:
                self.meetingsModel.detail.reloadDraftsAfterConfirmation()
                self.modalBaseVersion = field == .summary ? self.displayedDetail?.summaryVersion : self.displayedDetail?.notesVersion
                if field == .summary {
                    self.meetingsModel.detail.beginEditingSummary()
                    self.textEditPanel.showLatest(self.meetingsModel.detail.summaryDraft?.editedText ?? "")
                } else {
                    self.meetingsModel.detail.beginEditingNotes()
                    self.textEditPanel.showLatest(self.meetingsModel.detail.notesDraft?.editedText ?? "")
                }
                self.modalOriginalText = self.textEditPanel.text
                self.textEditPanel.setSaving(false)
            case let .failure(error):
                self.textEditPanel.showError("Could not reload: \(error.localizedDescription). Your text is still here.", conflict: true)
            }
        }
    }

    private func updateOverviewSections(_ detail: MeetingBrowserDetail) {
        summaryOverviewSection?.update(MeetingOverviewSection(title: "Summary", editIdentifier: "meeting-overview-edit-summary", content: detail.summary?.summary ?? "",
            unavailable: detail.jobs.contains(where: { $0.status == .queued || $0.status == .running })
                ? "Summary is processing. The recording and notes remain available."
                : "No Summary is available. Check Processing & source files for artifacts or failed Jobs.",
            canEdit: detail.summaryVersion != nil && !detail.row.isArchived,
            expand: { [weak self] in self?.expandSummary() },
            edit: { [weak self] in self?.beginSummaryEditing() },
            copy: { [weak self] in self?.copySummary() }))
        notesOverviewSection?.update(MeetingOverviewSection(title: "My notes", editIdentifier: "meeting-overview-edit-notes", content: detail.humanNotes,
            unavailable: "No notes yet. Choose Edit to add notes.", canEdit: detail.notesVersion != nil && !detail.row.isArchived,
            expand: { [weak self] in self?.expandNotes() },
            edit: { [weak self] in self?.beginNotesEditing() },
            copy: { [weak self] in self?.copyNotes() }))
    }

    @objc private func copyOutcome(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let text = outcomeCopy[key] else { return }
        copyToPasteboard(text)
    }
    @objc private func copySummary() { copyToPasteboard(displayedDetail?.summary?.summary ?? "") }
    @objc private func copyNotes() { copyToPasteboard(displayedDetail?.humanNotes ?? "") }
    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        status.stringValue = "Copied to clipboard."
    }

    // Opens the canonical Markdown document in the app's existing workspace document presentation.
    @objc private func expandSummary() {
        guard let detail = displayedDetail, detail.summaryVersion != nil else { return }
        openWorkspaceFile((detail.row.meetingRelativePath as NSString).deletingLastPathComponent + "/summary.md")
    }
    @objc private func expandNotes() {
        guard let detail = displayedDetail else { return }
        openWorkspaceFile(detail.row.meetingRelativePath)
    }

    private func clearEvidence() {
        timelineRows.arrangedSubviews.forEach { timelineRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        for group in [transcriptRows, evidenceRows] {
            group.arrangedSubviews.forEach { group.removeArrangedSubview($0); $0.removeFromSuperview() }
        }
        segmentLabels = []
        for container in [myActionsContainer, decisionsContainer, othersContainer, questionsContainer] {
            container.arrangedSubviews.forEach { container.removeArrangedSubview($0); $0.removeFromSuperview() }
        }
        actionRows = [:]
        pendingActionIDs = []
        actionReviewControls = [:]
        actionReviewEmptyState = nil
        actionReviewFeedbackLabel = nil
        evidenceTargets = [:]
        outcomeSourceTargets = [:]
        outcomeCopy = [:]
    }

    func renderEvidence(_ detail: MeetingBrowserDetail) {
        clearEvidence()
        if detail.transcript.isEmpty {
            transcriptRows.addArrangedSubview(NSTextField(wrappingLabelWithString: "No timestamped Transcript is available. Check Processing & source files for an available source or failed Job."))
        }
        // Legacy evidence controls are retained for accessibility/fixture checks, but never
        // instantiate a view for every segment of a multi-hour recording.
        for segment in detail.transcript.prefix(100) {
            let label = NSTextField(wrappingLabelWithString: "≈\(timeLabel(segment.startSeconds))–\(timeLabel(segment.endSeconds)) · \(segment.track) · \(segment.speaker): \(segment.text)")
            label.alignment = .left
            label.setAccessibilityLabel("Approximate \(timeLabel(segment.startSeconds)), \(segment.track), \(segment.speaker): \(segment.text)")
            transcriptRows.addArrangedSubview(label)
            segmentLabels.append((segment, label))
            addEvidenceControl(to: transcriptRows, segmentID: segment.id, seekSeconds: segment.seekSeconds, meetingID: detail.row.id)
        }
        let outcomes: [(String, [MeetingCitedOutcome])] = [
            ("Decision", detail.decisions),
            ("My Action Item", detail.myActionItems.map { MeetingCitedOutcome(text: $0.text + " — " + $0.reviewState.rawValue, citations: $0.citations) }),
            ("Other Action Item", detail.otherActionItems.map { MeetingCitedOutcome(text: $0.text + " — Reference only", citations: $0.citations) }),
            ("Open question", detail.openQuestions)
        ]
        if outcomes.allSatisfy({ $0.1.isEmpty }) {
            evidenceRows.addArrangedSubview(NSTextField(wrappingLabelWithString: "No structured cited outcomes available."))
        }
        for (kind, group) in outcomes {
            guard !group.isEmpty else { continue }
            evidenceRows.addArrangedSubview(sectionHeading(kind == "My Action Item" ? "My actions" :
                kind == "Other Action Item" ? "Others’ actions" : kind == "Decision" ? "Decisions" : "Open questions"))
            for outcome in group {
                let label = NSTextField(wrappingLabelWithString: "\(kind): \(outcome.text)")
                label.alignment = .left
                label.font = GraphiteFocusPresentation.Typography.body
                GraphiteFocusOverflow.configureWrappingText(label, fullText: label.stringValue)
                let copy = NSButton(title: "Copy", target: self, action: #selector(copyOutcome(_:)))
                let key = UUID().uuidString
                copy.identifier = NSUserInterfaceItemIdentifier(key)
                copy.setAccessibilityLabel("Copy \(kind): \(outcome.text)")
                outcomeCopy[key] = outcome.text
                let edit = NSButton(title: "Edit in summary ↗", target: self, action: #selector(expandSummary))
                edit.isEnabled = detail.summaryVersion != nil
                edit.setAccessibilityLabel("Edit \(kind) in summary Markdown document")
                let controls = localControlRow([copy, edit])
                let row = NSStackView(views: [label, controls])
                row.orientation = .vertical
                row.alignment = .leading
                row.spacing = GraphiteFocusPresentation.Space.compact
                evidenceRows.addArrangedSubview(row)
                label.widthAnchor.constraint(lessThanOrEqualTo: evidenceRows.widthAnchor).isActive = true
                for citation in outcome.citations {
                    evidenceRows.addArrangedSubview(NSTextField(wrappingLabelWithString: "Evidence: \(citation.segmentID) (≈\(timeLabel(citation.startSeconds))–\(timeLabel(citation.endSeconds)))"))
                    addEvidenceControl(to: evidenceRows, segmentID: citation.segmentID, seekSeconds: citation.seekSeconds, meetingID: detail.row.id)
                }
            }
        }
        renderTimeline(detail)
        renderOutcomes(detail)
        updateActiveSegment(at: meetingsModel.detail.playbackState.position)
    }

    private func renderOutcomes(_ detail: MeetingBrowserDetail) {
        for container in [myActionsContainer, decisionsContainer, othersContainer, questionsContainer] {
            container.arrangedSubviews.forEach { container.removeArrangedSubview($0); $0.removeFromSuperview() }
        }
        func makeRow(
            _ id: String,
            _ text: String,
            provenance: String,
            reviewState: ProposalReviewState? = nil,
            citations: [MeetingCitation]
        ) -> MeetingOutcomeRow {
            MeetingOutcomeRow(id: id, text: text, provenance: provenance,
                              reviewState: reviewState, citations: citations)
        }
        var groups: [MeetingOutcomeGroup] = []
        if !detail.myActionItems.isEmpty {
            groups.append(MeetingOutcomeGroup(kind: .mine, title: "My actions", note: "Generated · review before adding to Todos",
                rows: detail.myActionItems.map { item in
                    let proposalID = "meeting-action:\(detail.row.id):\(item.id)"
                    let saved = detail.actionDrafts[proposalID]
                    return makeRow(proposalID, saved?.title ?? item.text,
                                   provenance: "Generated from meeting",
                                   reviewState: item.reviewState, citations: item.citations)
                }))
        }
        if !detail.otherActionItems.isEmpty {
            groups.append(MeetingOutcomeGroup(kind: .others, title: "Others’ actions", note: "Reference only",
                rows: detail.otherActionItems.map {
                    makeRow($0.id, $0.text, provenance: "Reference only", citations: $0.citations)
                }))
        }
        if !detail.decisions.isEmpty {
            groups.append(MeetingOutcomeGroup(kind: .decisions, title: "Decisions", note: "\(detail.decisions.count) captured",
                rows: detail.decisions.enumerated().map {
                    makeRow("decision-\($0.offset)", $0.element.text,
                            provenance: "Generated from meeting", citations: $0.element.citations)
                }))
        }
        if !detail.openQuestions.isEmpty {
            groups.append(MeetingOutcomeGroup(kind: .questions, title: "Open questions", note: "\(detail.openQuestions.count) captured",
                rows: detail.openQuestions.enumerated().map {
                    makeRow("question-\($0.offset)", $0.element.text,
                            provenance: "Generated from meeting", citations: $0.element.citations)
                }))
        }
        let reviewRows = groups.filter { $0.kind.isReviewWorkspace }.flatMap(\.rows)
        actionRows = Dictionary(uniqueKeysWithValues: reviewRows.map { ($0.id, $0) })
        pendingActionIDs = reviewRows.filter(\.isPendingReview).map(\.id)
        meetingsModel.detail.selectActionProposals(Set(pendingActionIDs))
        if let feedback = actionReviewFeedback, feedback.meetingID == detail.row.id {
            let label = GraphiteFocusStatusLabel()
            label.setStatus(feedback.message, meaning: .success,
                            colors: GraphiteFocusPresentation.Colors(environment: .system(window: window)))
            myActionsContainer.addArrangedSubview(label)
            actionReviewFeedbackLabel = label
        }
        for group in groups {
            let boundedReviewWorkspace = group.kind.isReviewWorkspace
            let section = NSStackView()
            section.orientation = .vertical
            section.alignment = .leading
            section.spacing = GraphiteFocusPresentation.Space.compact
            section.edgeInsets = NSEdgeInsets(
                top: boundedReviewWorkspace ? GraphiteFocusPresentation.Space.panel : GraphiteFocusPresentation.Space.compact,
                left: boundedReviewWorkspace ? GraphiteFocusPresentation.Space.panel : 0,
                bottom: boundedReviewWorkspace ? GraphiteFocusPresentation.Space.panel : GraphiteFocusPresentation.Space.compact,
                right: boundedReviewWorkspace ? GraphiteFocusPresentation.Space.panel : 0
            )
            if boundedReviewWorkspace {
                let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
                section.wantsLayer = true
                section.layer?.cornerRadius = GraphiteFocusPresentation.Radius.panel
                section.layer?.backgroundColor = colors.surfacePanel.cgColor
                section.layer?.borderWidth = GraphiteFocusPresentation.Stroke.width
                section.layer?.borderColor = colors.structuralStroke.cgColor
            }
            let headingRow = NSStackView()
            headingRow.orientation = .horizontal
            headingRow.alignment = .firstBaseline
            headingRow.spacing = GraphiteFocusPresentation.Space.compact
            let heading = NSTextField(wrappingLabelWithString: group.title)
            heading.maximumNumberOfLines = 0
            heading.font = GraphiteFocusPresentation.Typography.sectionHeading
            heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let note = NSTextField(wrappingLabelWithString: group.note)
            note.maximumNumberOfLines = 0
            note.font = GraphiteFocusPresentation.Typography.metadata
            note.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textMetadata
            note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            headingRow.addArrangedSubview(heading)
            headingRow.addArrangedSubview(note)
            section.addArrangedSubview(headingRow)
            let horizontalInset = boundedReviewWorkspace ? 2 * GraphiteFocusPresentation.Space.panel : 0
            headingRow.widthAnchor.constraint(equalTo: section.widthAnchor, constant: -horizontalInset).isActive = true
            for (rowOffset, row) in group.rows.enumerated() {
                let comment = group.kind.isReviewWorkspace ? detail.actionDrafts[row.id]?.comment ?? "" : ""
                let text = NSTextField(wrappingLabelWithString: row.text + "\n" + row.detailText +
                    (comment.isEmpty ? "" : "\nComment: " + comment))
                text.maximumNumberOfLines = 0
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                GraphiteFocusOverflow.configureWrappingText(text, fullText: text.stringValue)
                let controls = NSStackView()
                controls.orientation = .horizontal
                controls.alignment = .centerY
                controls.spacing = GraphiteFocusPresentation.Space.compact
                appendSourceControls(for: row, groupKind: group.kind, detail: detail, to: controls)
                if group.kind.isReviewWorkspace {
                    let edit = makeActionReviewButton(name: "Edit", selector: #selector(editAction(_:)), row: row)
                    let review = makeActionReviewButton(name: "Review", selector: #selector(reviewAction(_:)), row: row)
                    actionReviewControls[row.id] = (edit, review)
                    controls.addArrangedSubview(edit)
                    controls.addArrangedSubview(review)
                }
                let line = NSStackView(views: controls.arrangedSubviews.isEmpty ? [text] : [text, controls])
                line.orientation = .vertical
                line.alignment = .leading
                line.spacing = GraphiteFocusPresentation.Space.compact
                section.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: section.widthAnchor, constant: -horizontalInset).isActive = true
                text.widthAnchor.constraint(equalTo: line.widthAnchor).isActive = true
                if !boundedReviewWorkspace && rowOffset < group.rows.count - 1 {
                    let separator = NSBox()
                    separator.boxType = .separator
                    section.addArrangedSubview(separator)
                }
            }
            if boundedReviewWorkspace && pendingActionIDs.isEmpty {
                let emptyState = FocusableMeetingEmptyState(
                    labelWithString: "No actions are awaiting review."
                )
                emptyState.font = GraphiteFocusPresentation.Typography.body
                emptyState.textColor = presentationColors.textSecondary
                emptyState.setAccessibilityLabel("No actions are awaiting review")
                section.addArrangedSubview(emptyState)
                actionReviewEmptyState = emptyState
            }
            let container: NSStackView
            switch group.kind {
            case .mine: container = myActionsContainer
            case .others: container = othersContainer
            case .decisions: container = decisionsContainer
            case .questions: container = questionsContainer
            }
            container.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
    }

    private func makeActionReviewButton(name: String, selector: Selector, row: MeetingOutcomeRow) -> NSButton {
        let button = NSButton(title: name, target: self, action: selector)
        button.identifier = NSUserInterfaceItemIdentifier(row.id)
        button.toolTip = "\(name) my action: \(row.text)"
        button.setAccessibilityLabel(button.toolTip!)
        button.setAccessibilityIdentifier("meeting-action-\(name.lowercased())-\(row.id)")
        button.isEnabled = row.isPendingReview
        GraphiteFocusOverflow.protectTrailingControl(button)
        return button
    }

    private func appendSourceControls(for row: MeetingOutcomeRow, groupKind: MeetingOutcomeGroup.Kind, detail: MeetingBrowserDetail, to controls: NSStackView) {
        guard !row.citations.isEmpty else { return }
        let sourceButtons: [(key: String, button: NSButton)] = row.citations.enumerated().map { index, citation in
            let valid = detail.transcript.contains(where: citation.matches)
            let key = "\(row.id)-\(index)"
            if valid {
                outcomeSourceTargets[key] = OutcomeSourceTarget(
                    meetingID: detail.row.id,
                    citation: citation,
                    kind: groupKind.timelineKind
                )
            }
            let label = timeLabel(citation.startSeconds)
            let source = NSButton(title: valid ? "↗ source \(label)" : "Source unavailable",
                                  target: self, action: #selector(seekOutcomeSource(_:)))
            source.identifier = NSUserInterfaceItemIdentifier(key)
            source.setAccessibilityIdentifier("meeting-outcome-source-\(key)")
            source.setAccessibilityLabel(valid ? "Show transcript source at \(label)" : "Transcript source unavailable")
            source.isEnabled = valid
            GraphiteFocusOverflow.protectTrailingControl(source)
            return (key, source)
        }
        if sourceButtons.count <= 2 {
            sourceButtons.forEach { controls.addArrangedSubview($0.button) }
            return
        }
        let menuButton = NSPopUpButton(frame: .zero, pullsDown: true)
        menuButton.addItem(withTitle: "Sources (\(sourceButtons.count))")
        menuButton.setAccessibilityLabel("Transcript sources for \(row.text)")
        for item in sourceButtons {
            menuButton.menu?.addItem(NSMenuItem(title: item.button.title, action: #selector(seekOutcomeSourceMenuItem(_:)), keyEquivalent: ""))
            menuButton.menu?.items.last?.target = self
            menuButton.menu?.items.last?.representedObject = item.key
            menuButton.menu?.items.last?.isEnabled = item.button.isEnabled
        }
        GraphiteFocusOverflow.protectTrailingControl(menuButton)
        controls.addArrangedSubview(menuButton)
    }

    private struct OutcomeSourceTarget {
        let meetingID: String
        let citation: MeetingCitation
        let kind: MeetingTimelineMoment.Kind
    }

    @objc private func seekOutcomeSourceMenuItem(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        seekOutcomeSource(key: key)
    }

    @objc private func seekOutcomeSource(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        seekOutcomeSource(key: key)
    }

    private func seekOutcomeSource(key: String) {
        guard let target = outcomeSourceTargets[key],
              let detail = displayedDetail, selectedID == target.meetingID,
              detail.transcript.contains(where: target.citation.matches) else { return }
        openTimeline()
        timelineNavigation.show(seconds: target.citation.startSeconds,
                                segmentID: target.citation.segmentID, kind: target.kind)
        if audioSource == detail.playback,
           let seconds = target.citation.validatedSeekSeconds(playbackDuration: meetingsModel.detail.playbackState.duration) {
            meetingsModel.detail.seekPlayback(to: seconds)
        }
    }

    @objc private func editAction(_ sender: NSButton) { presentActionEditor(sender, reviewing: false) }
    @objc private func reviewAction(_ sender: NSButton) { presentActionEditor(sender, reviewing: true) }

    private func presentActionEditor(_ sender: NSButton, reviewing: Bool,
                                     initialTitle: String? = nil, initialComment: String? = nil,
                                     failureMessage: String? = nil) {
        guard let id = sender.identifier?.rawValue, let row = actionRows[id], row.isPendingReview,
              let meetingID = selectedID, let detail = displayedDetail else { return }
        let removedIndex = pendingActionIDs.firstIndex(of: id)
        let draft = detail.actionDrafts[id]
        let titleScroll = NSTextView.scrollableTextView()
        let commentScroll = NSTextView.scrollableTextView()
        let title = titleScroll.documentView as! NSTextView
        let comment = commentScroll.documentView as! NSTextView
        for (editor, label) in [(title, "Action item text"), (comment, "Comment")] {
            editor.font = GraphiteFocusPresentation.Typography.body
            editor.textColor = .labelColor
            editor.backgroundColor = .textBackgroundColor
            editor.isRichText = false
            editor.textContainerInset = NSSize(width: GraphiteFocusPresentation.Space.compact,
                                               height: GraphiteFocusPresentation.Space.compact)
            editor.setAccessibilityLabel(label)
        }
        title.string = initialTitle ?? draft?.title ?? row.text
        comment.string = initialComment ?? draft?.comment ?? ""
        titleScroll.hasVerticalScroller = true
        commentScroll.hasVerticalScroller = true
        titleScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
        commentScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let sources = row.citations.map { timeLabel($0.startSeconds) }.joined(separator: ", ")
        let context = NSTextField(wrappingLabelWithString: "Provenance: \(row.detailText)\nSource: \(sources.isEmpty ? "No transcript citation available" : sources)")
        let failure = GraphiteFocusStatusLabel()
        failure.isHidden = failureMessage == nil
        if let failureMessage {
            failure.setStatus(failureMessage, meaning: .destructive,
                              colors: GraphiteFocusPresentation.Colors(environment: .system(window: window)))
        }
        let fields = NSStackView(views: [context, NSTextField(labelWithString: "Action item text"), titleScroll,
                                         NSTextField(labelWithString: "Comment"), commentScroll, failure])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = GraphiteFocusPresentation.Space.compact
        fields.frame = NSRect(x: 0, y: 0, width: 480, height: 270)
        titleScroll.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        commentScroll.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        failure.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: reviewing ? "checklist" : "square.and.pencil",
                             accessibilityDescription: reviewing ? "Review action" : "Edit action")
        alert.messageText = reviewing ? "Review my action" : "Edit my action"
        alert.informativeText = reviewing ? "Accept creates a Todo Item. Decline dismisses this proposal." : "Save updates only the proposal; it does not accept or create a Todo Item."
        alert.accessoryView = fields
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: failureMessage == nil ? (reviewing ? "Accept" : "Save") : (reviewing ? "Retry Accept" : "Retry Save"))
        if reviewing { alert.addButton(withTitle: "Decline") }
        let focusTracker = MeetingEditorFocusTracker(initial: title)
        title.delegate = focusTracker
        comment.delegate = focusTracker
        alert.window.initialFirstResponder = title
        let choice = presentConfirmationAlert(alert)
        guard choice != .alertFirstButtonReturn, selectedID == meetingID else { return }
        let newTitle = title.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let newComment = comment.string
        let finish: (Result<Void, Error>, String) -> Void = { [weak self, weak sender] result, success in
            guard let self, self.selectedID == meetingID else { return }
            switch result {
            case .success:
                self.showActionReviewSuccess(success, meetingID: meetingID)
                if reviewing, let removedIndex { self.focusAfterActionRemoval(removedIndex: removedIndex) }
                else { self.focusActionControl(id: id, reviewing: false) }
            case let .failure(error):
                let message = "Review failed. Your edits remain available. Retry when ready. \(error.localizedDescription)"
                if let sender { self.presentActionEditor(sender, reviewing: reviewing,
                    initialTitle: newTitle, initialComment: newComment, failureMessage: message) }
            }
        }
        if reviewing && choice == .alertThirdButtonReturn {
            meetingsModel.detail.reviewAction(id: id, accept: false) { result in finish(result, "Proposal dismissed.") }
            return
        }
        guard !newTitle.isEmpty else {
            let error = MeetingManagementError.retryRejected("Action text cannot be empty.")
            finish(.failure(error), "")
            return
        }
        meetingsModel.detail.saveActionDraft(id: id, title: newTitle, comment: newComment) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure: finish(result, "")
            case .success where reviewing:
                self.meetingsModel.detail.reviewAction(id: id, accept: true) { reviewResult in
                    finish(reviewResult, "Added ‘\(newTitle)’ to Todos.")
                }
            case .success: finish(.success(()), "Changes saved.")
            }
        }
    }

    private func focusActionControl(id: String, reviewing: Bool) {
        guard let controls = actionReviewControls[id] else {
            focusActionReviewEmptyState()
            return
        }
        let control = reviewing ? controls.review : controls.edit
        guard control.isEnabled else {
            focusActionReviewEmptyState()
            return
        }
        window?.makeFirstResponder(control)
        control.scrollToVisible(control.bounds)
    }

    private func focusAfterActionRemoval(removedIndex: Int) {
        if pendingActionIDs.indices.contains(removedIndex) {
            focusActionControl(id: pendingActionIDs[removedIndex], reviewing: true)
        } else if let previous = pendingActionIDs.last {
            focusActionControl(id: previous, reviewing: true)
        } else {
            focusActionReviewEmptyState()
        }
    }

    private func focusActionReviewEmptyState() {
        guard let emptyState = actionReviewEmptyState else { return }
        window?.makeFirstResponder(emptyState)
        emptyState.scrollToVisible(emptyState.bounds)
    }

    private func showActionReviewSuccess(_ message: String, meetingID: String) {
        actionReviewFeedbackDismissal?.cancel()
        actionReviewFeedback = (meetingID, message)
        let dismissal = DispatchWorkItem { [weak self] in
            guard self?.actionReviewFeedback?.meetingID == meetingID,
                  self?.actionReviewFeedback?.message == message else { return }
            self?.actionReviewFeedback = nil
            guard self?.selectedID == meetingID, let label = self?.actionReviewFeedbackLabel else { return }
            self?.myActionsContainer.removeArrangedSubview(label)
            label.removeFromSuperview()
            self?.actionReviewFeedbackLabel = nil
        }
        actionReviewFeedbackDismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: dismissal)
    }

    private func renderTimeline(_ detail: MeetingBrowserDetail) {
        var moments: [MeetingTimelineMoment] = detail.transcript.filter { $0.startSeconds.isFinite && $0.startSeconds >= 0 }.map {
            MeetingTimelineMoment(id: "transcript-\($0.id)", seconds: $0.startSeconds, kind: .transcript,
                text: $0.text, context: $0.track == $0.speaker ? $0.speaker : "\($0.track) · \($0.speaker)", seekSeconds: $0.seekSeconds)
        }
        func add(_ kind: MeetingTimelineMoment.Kind, _ text: String, _ context: String, _ citations: [MeetingCitation]) {
            for (index, citation) in citations.enumerated() where citation.startSeconds.isFinite && citation.startSeconds >= 0 {
                moments.append(MeetingTimelineMoment(id: "\(kind.rawValue)-\(citation.segmentID)-\(index)-\(moments.count)",
                    seconds: citation.startSeconds, kind: kind, text: text, context: context,
                    seekSeconds: citation.seekSeconds))
            }
        }
        for decision in detail.decisions { add(.decision, decision.text, "Cited decision", decision.citations) }
        for item in detail.myActionItems { add(.action, item.text, "My action · \(item.reviewState.rawValue)", item.citations) }
        for item in detail.otherActionItems { add(.action, item.text, "Others’ action · reference only", item.citations) }
        let hosting = NSHostingView(rootView: MeetingTimelineView(moments: moments.sorted { $0.seconds < $1.seconds },
            duration: max(detail.playback.durationSeconds, detail.transcript.map(\.endSeconds).max() ?? 0,
                          moments.map(\.seconds).max() ?? 0), hasAudio: meetingsModel.detail.playbackState.isAvailable,
            seek: { [weak self] moment in
                guard let self, self.selectedID == detail.row.id,
                      self.audioSource == detail.playback,
                      let seconds = moment.seekSeconds, seconds <= self.meetingsModel.detail.playbackState.duration,
                      detail.transcript.contains(where: { $0.seekSeconds == seconds && $0.startSeconds <= moment.seconds && $0.endSeconds >= moment.seconds }) else { return }
                self.meetingsModel.detail.seekPlayback(to: seconds)
            }, navigation: timelineNavigation))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        timelineRows.addArrangedSubview(hosting)
        hosting.widthAnchor.constraint(equalTo: timelineRows.widthAnchor).isActive = true
    }

    private func addEvidenceControl(to group: NSStackView, segmentID: String, seekSeconds: Double?, meetingID: String) {
        guard let seekSeconds, meetingsModel.detail.playbackState.isAvailable,
              seekSeconds <= meetingsModel.detail.playbackState.duration else {
            group.addArrangedSubview(NSTextField(wrappingLabelWithString: "Seek unavailable: missing or invalid timing, citation, or playable audio."))
            return
        }
        let button = NSButton(title: "Seek to ≈\(timeLabel(seekSeconds))", target: self, action: #selector(seekEvidence(_:)))
        button.setAccessibilityLabel("Seek selected Meeting audio to approximately \(timeLabel(seekSeconds)), segment \(segmentID)")
        let key = UUID().uuidString
        button.identifier = NSUserInterfaceItemIdentifier(key)
        evidenceTargets[key] = EvidenceTarget(meetingID: meetingID, segmentID: segmentID, seconds: seekSeconds)
        group.addArrangedSubview(button)
    }

    private struct EvidenceTarget {
        let meetingID: String
        let segmentID: String
        let seconds: Double
    }

    @objc func seekEvidence(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let target = evidenceTargets[key],
              (transcriptRows.arrangedSubviews.contains(sender) || evidenceRows.arrangedSubviews.contains(sender)),
              let detail = displayedDetail, selectedID == target.meetingID, detail.row.id == target.meetingID,
              meetingsModel.detail.playbackState.isAvailable, audioSource == detail.playback,
              detail.transcript.contains(where: { $0.id == target.segmentID && $0.seekSeconds == target.seconds }) else { return }
        openTimeline()
        meetingsModel.detail.seekPlayback(to: target.seconds)
    }

    private func updateActiveSegment(at seconds: Double?) {
        // Sorted segments give deterministic priority to the first matching track during overlaps.
        let active = seconds.flatMap { time in
            segmentLabels.first { $0.0.seekSeconds != nil && $0.0.startSeconds <= time && time < $0.0.endSeconds }?.0.id
        }
        for (segment, label) in segmentLabels {
            label.font = segment.id == active ? GraphiteFocusPresentation.Typography.activeTranscriptSegment : GraphiteFocusPresentation.Typography.body
        }
    }

    private func renderArtifacts(_ artifacts: [MeetingArtifact]) {
        files.arrangedSubviews.forEach { files.removeArrangedSubview($0); $0.removeFromSuperview() }
        for artifact in artifacts where artifact.role != .extraction {
            let title = artifact.available ? "Open \(artifact.role.rawValue.capitalized)" : (artifact.message ?? "\(artifact.role.rawValue.capitalized) unavailable")
            let button = NSButton(title: title, target: self, action: #selector(openArtifact(_:)))
            button.isEnabled = artifact.available
            button.identifier = NSUserInterfaceItemIdentifier(artifact.relativePath)
            button.toolTip = artifact.relativePath
            button.setAccessibilityLabel("\(title): \(artifact.relativePath)")
            files.addArrangedSubview(button)
        }
    }

    @objc func filtersChanged(_ sender: Any?) { applyFilters() }

    @objc private func dateFilterChanged(_ sender: NSButton) {
        let picker = sender === startDateEnabled ? startDatePicker : endDatePicker
        picker.isEnabled = sender.state == .on
        applyFilters()
    }

    @objc private func clearFilters(_ sender: Any?) {
        queryField.stringValue = ""
        projectFilter.selectItem(at: 0)
        processingFilter.selectItem(at: 0)
        archiveFilter.selectItem(at: 0)
        startDateEnabled.state = .off
        endDateEnabled.state = .off
        startDatePicker.isEnabled = false
        endDatePicker.isEnabled = false
        applyFilters()
    }

    private func renderRetryActions(_ detail: MeetingBrowserDetail) {
        retryRows.arrangedSubviews.forEach { retryRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let failedJobs = detail.jobs.filter { $0.status == .failed }
        if failedJobs.isEmpty && detail.row.processingState == .needsAttention {
            let notice = NSTextField(wrappingLabelWithString: "! Processing needs attention. Your Meeting files are preserved; inspect Processing & source files for available artifacts.")
            notice.font = GraphiteFocusPresentation.Typography.body
            notice.textColor = presentationColors.attention
            notice.alignment = .left
            retryRows.addArrangedSubview(notice)
        }
        for job in failedJobs {
            let row = NSStackView()
            row.orientation = .vertical
            row.spacing = GraphiteFocusPresentation.Space.compact
            let label = NSTextField(wrappingLabelWithString: "\(job.title) failed at \(job.stage ?? "unknown stage"). Meeting files are preserved. \(job.error ?? "Inspect source files for details.")")
            label.maximumNumberOfLines = 0
            label.alignment = .left
            label.textColor = presentationColors.destructive
            row.addArrangedSubview(label)
            let reason = job.retryReason ?? (detail.jobs.contains(where: { $0.jobID != job.jobID && ($0.status == .queued || $0.status == .running) }) ? "This Meeting already has processing work in progress." : nil)
            let button = NSButton(title: "Retry", target: self, action: #selector(retryFailedJob(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(job.jobID)
            button.setAccessibilityLabel("Retry \(job.title) for this Meeting")
            button.isEnabled = reason == nil
            if let reason {
                let explanation = NSTextField(wrappingLabelWithString: reason)
                explanation.setAccessibilityLabel("Retry unavailable: \(reason)")
                row.addArrangedSubview(explanation)
            }
            row.addArrangedSubview(button)
            retryRows.addArrangedSubview(row)
        }
    }

    @objc private func editSummaryFromToolbar() {
        guard editSummaryTool.isEnabled else { return }
        beginSummaryEditing()
    }

    @objc private func editNotesFromToolbar() {
        guard editNotesTool.isEnabled else { return }
        beginNotesEditing()
    }

    @objc private func showMeetingMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let rename = NSMenuItem(title: "Rename…", action: #selector(confirmRename), keyEquivalent: "")
        rename.target = self
        rename.isEnabled = renameButton.isEnabled
        menu.addItem(rename)
        let archive = NSMenuItem(title: displayedDetail?.row.isArchived == true ? "Restore" : "Archive", action: #selector(toggleArchive), keyEquivalent: "")
        archive.target = self
        archive.isEnabled = archiveButton.isEnabled
        menu.addItem(archive)
        let regenerate = NSMenuItem(title: "Regenerate…", action: #selector(confirmReprocess), keyEquivalent: "")
        regenerate.target = self
        regenerate.isEnabled = reprocessButton.isEnabled
        menu.addItem(regenerate)
        let remove = NSMenuItem(title: "Remove…", action: #selector(confirmRemove), keyEquivalent: "")
        remove.target = self
        remove.isEnabled = displayedDetail?.row.captureState == .stopped && reprocessButton.isEnabled
        menu.addItem(remove)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func confirmRemove() {
        guard displayedDetail != nil else { return }
        guard !meetingsModel.isDirty else {
            status.stringValue = "Save or discard this Meeting's edits before removing it."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove this Meeting?"
        alert.informativeText = "Move the Meeting folder to Trash. External recording files and already accepted Todos are not removed."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard presentConfirmationAlert(alert) == .alertFirstButtonReturn else { return }
        meetingsModel.remove { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.status.stringValue = "Meeting moved to Trash."
            case let .failure(error): self.status.stringValue = "Could not remove Meeting: \(error.localizedDescription)"
            }
        }
    }

    @objc private func toggleArchive() {
        guard let detail = displayedDetail else { return }
        archiveButton.isEnabled = false
        let operation = detail.row.isArchived ? meetingsModel.restore : meetingsModel.archive
        operation { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.retryFeedback = (detail.row.id, detail.row.isArchived ? "Meeting restored." : "Meeting archived.")
                if detail.row.isArchived {
                    self.restoredSelectionID = detail.row.id
                    self.archiveFilter.selectItem(at: 0)
                    self.applyFilters()
                }
            case let .failure(error):
                self.retryFeedback = (detail.row.id, "Could not update Meeting archive: \(error.localizedDescription)")
            }
            self.archiveButton.isEnabled = true
        }
    }

    @objc func confirmRename() {
        guard let detail = displayedDetail, selectedDoorwayVersion != nil else { return }
        guard !meetingsModel.isDirty else {
            status.stringValue = "Save or discard this Meeting's edits before renaming it."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rename this Meeting?"
        alert.informativeText = "The Meeting folder and links within this workspace will change. Links copied outside Stillmatter cannot be updated and may break."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        input.stringValue = detail.row.title
        input.setAccessibilityLabel("New Meeting title")
        alert.accessoryView = input
        guard presentConfirmationAlert(alert) == .alertFirstButtonReturn else { return }
        renameButton.isEnabled = false
        meetingsModel.rename(to: input.stringValue) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(renamed): self.retryFeedback = (renamed.row.id, "Meeting renamed.")
            case let .failure(error): self.retryFeedback = (detail.row.id, "Could not rename Meeting: \(error.localizedDescription)")
            }
            self.renameButton.isEnabled = true
        }
    }

    @objc func confirmReprocess() {
        guard let detail = displayedDetail else { return }
        guard !meetingsModel.isDirty else {
            status.stringValue = "Save or discard this Meeting's edits before reprocessing it."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Reprocess this Meeting?"
        alert.informativeText = "The current Transcript and Summary, including manual Summary edits, will be replaced after new results are validated. Inbox review decisions and accepted Todo Items will remain."
        alert.addButton(withTitle: "Reprocess")
        alert.addButton(withTitle: "Cancel")
        let languages = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 28), pullsDown: false)
        languages.addItems(withTitles: ["English", "Ukrainian"])
        languages.setAccessibilityLabel("Reprocessing language")
        alert.accessoryView = languages
        guard presentConfirmationAlert(alert) == .alertFirstButtonReturn else { return }
        reprocessButton.isEnabled = false
        meetingsModel.reprocess(language: languages.indexOfSelectedItem == 1 ? .ukrainian : .english) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.retryFeedback = (detail.row.id, "Reprocessing queued for this Meeting.")
            case let .failure(error): self.retryFeedback = (detail.row.id, "Could not reprocess: \(error.localizedDescription)")
            }
            self.reprocessButton.isEnabled = true
        }
    }

    @objc func retryFailedJob(_ sender: NSButton) {
        guard let detail = displayedDetail, let jobID = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        meetingsModel.retry(jobID: jobID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success: self.retryFeedback = (detail.row.id, "Retry queued for this Meeting.")
            case let .failure(error): self.retryFeedback = (detail.row.id, "Could not retry processing: \(error.localizedDescription)")
            }
            sender.isEnabled = true
        }
    }

    @objc private func openArtifact(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue, !path.isEmpty else { return }
        if path.hasPrefix("/") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        else { openWorkspaceFile(path) }
    }

    @objc private func openRecordingAction() { openRecording() }

    private static let filterDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// Image-only AppKit buttons have inconsistent bezel heights across SF Symbols.
/// Draw a fixed square bezel so every meeting control has the same visible size.
final class MeetingHeaderButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 36
        let square = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                            width: side, height: side)
        let bezel = NSBezierPath(roundedRect: square.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7)
        GraphiteFocusPresentation.Colors(environment: .system(window: window)).surfacePanel.setFill()
        bezel.fill()
        GraphiteFocusPresentation.Colors(environment: .system(window: window)).structuralStroke.setStroke()
        bezel.lineWidth = 1
        bezel.stroke()
        super.draw(dirtyRect)
    }
}

private final class MeetingDetailDocumentView: NSStackView {
    override var isFlipped: Bool { true }
}

private final class MeetingEditorFocusTracker: NSObject, NSTextViewDelegate {
    private(set) var current: NSTextView

    init(initial: NSTextView) {
        current = initial
    }

    func textDidBeginEditing(_ notification: Notification) {
        if let editor = notification.object as? NSTextView { current = editor }
    }
}

final class FocusableMeetingEmptyState: NSTextField {
    override var acceptsFirstResponder: Bool { true }
}

extension MeetingManagementView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        MeetingSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // AppKit can request a previously visible row during deferred layout after a
        // workspace switch has emptied the read model. Never index stale row positions.
        guard rows.indices.contains(row) else { return nil }
        let meeting = rows[row]
        let title = NSTextField(labelWithString: meeting.displayTitle)
        title.font = GraphiteFocusPresentation.Typography.rowTitle
        GraphiteFocusOverflow.configurePrimaryTitle(title, fullText: meeting.title)
        title.alignment = .left
        let date = NSTextField(labelWithString: meeting.startedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Date unavailable")
        date.font = GraphiteFocusPresentation.Typography.metadata
        date.textColor = .secondaryLabelColor
        GraphiteFocusOverflow.configureSecondaryMetadata(date, fullText: date.stringValue, lineBreakMode: .byTruncatingTail)
        date.alignment = .left
        let colors = presentationColors
        var metadataParts: [NSView] = [date]
        if let duration = meeting.durationSeconds, duration.isFinite, duration >= 0 {
            metadataParts.append(meetingSymbol("clock", label: "Duration", color: colors.textMetadata))
            let durationLabel = NSTextField(labelWithString: timeLabel(duration))
            durationLabel.font = GraphiteFocusPresentation.Typography.metadata
            durationLabel.textColor = colors.textMetadata
            metadataParts.append(durationLabel)
        }
        if meeting.hasMyActions {
            metadataParts.append(meetingSymbol("person.fill", label: "My actions", color: colors.accent))
        }
        if meeting.hasOthersActions {
            metadataParts.append(meetingSymbol("person.2.fill", label: "Others' actions", color: colors.textMetadata))
        }
        if meeting.needsActionReview {
            metadataParts.append(meetingSymbol("bell.badge.fill", label: "Actions need review", color: colors.attention))
        }
        if meeting.processingState == .processing && meeting.job?.status != .failed {
            let progress = GraphiteFocusProgressStatusView()
            let stage = meeting.job?.stage.map { "Stage: \($0)" } ?? "Work in progress"
            progress.configure(title: "Processing", value: nil,
                               valueDescription: stage, colors: colors)
            metadataParts.append(progress)
        } else {
            let statusName = meeting.job?.status == .failed ? "xmark.octagon.fill" :
                meeting.requiresAttention ? "exclamationmark.circle.fill" :
                meeting.processingState == .ready ? "checkmark.circle.fill" : "info.circle.fill"
            let statusLabel = meeting.needsActionReview && meeting.processingState == .ready ? "Needs attention" : statusTitle(for: meeting)
            let statusColor = meeting.job?.status == .failed ? colors.destructive :
                meeting.requiresAttention ? colors.attention : meeting.processingState == .ready
                    ? colors.accent
                    : statusMeaning(for: meeting).color(in: colors)
            metadataParts.append(meetingSymbol(statusName, label: statusLabel, color: statusColor))
            let visibleStatus = NSTextField(labelWithString: statusLabel)
            visibleStatus.font = GraphiteFocusPresentation.Typography.metadata
            visibleStatus.textColor = statusColor
            GraphiteFocusOverflow.configureSecondaryMetadata(visibleStatus, fullText: statusLabel, lineBreakMode: .byTruncatingTail)
            metadataParts.append(visibleStatus)
        }
        let metadata = NSStackView(views: metadataParts)
        metadata.orientation = .horizontal
        metadata.alignment = .centerY
        metadata.spacing = GraphiteFocusPresentation.Space.primitive
        date.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let cell = NSStackView(views: [title, metadata])
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = GraphiteFocusPresentation.Space.primitive
        cell.edgeInsets = NSEdgeInsets(top: GraphiteFocusPresentation.Space.compact, left: GraphiteFocusPresentation.Space.panel, bottom: GraphiteFocusPresentation.Space.compact, right: GraphiteFocusPresentation.Space.panel)
        cell.setAccessibilityLabel("\(meeting.title), \(date.stringValue), \(meeting.durationSeconds.map { "duration \(timeLabel($0)), " } ?? "")\(meeting.hasMyActions ? "my actions, " : "")\(meeting.hasOthersActions ? "others' actions, " : "")\(meeting.needsActionReview ? "actions need review, " : "")\(statusText(for: meeting))\(meeting.isArchived ? ", Archived" : "")")
        return cell
    }

    @objc private func openClickedMeeting(_ sender: NSTableView) {
        // Back retains the selected Meeting. AppKit sends no selection-change
        // notification when that same row is clicked again in the narrow list.
        guard !isApplyingFeatureState, rows == meetingsModel.visibleRows,
              sender.clickedRow == sender.selectedRow,
              rows.indices.contains(sender.clickedRow),
              rows[sender.clickedRow].id == selectedID else { return }
        onOpenSelection()
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingFeatureState, rows == meetingsModel.visibleRows else { return }
        if rows.indices.contains(table.selectedRow), rows[table.selectedRow].id != selectedID { retryFeedback = nil }
        let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        guard rows.indices.contains(table.selectedRow) else { return }
        let result = meetingsModel.select(meetingID: rows[table.selectedRow].id, selectedIDs: selected)
        guard result == .applied else {
            syncSelectedRows(force: true)
            return
        }
        onOpenSelection()
    }
}
