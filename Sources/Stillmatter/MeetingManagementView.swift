import AppKit
import AVFoundation
import SwiftUI
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Meeting detail canvas. `browserView` is hosted independently in the shell's content-list region.
final class MeetingManagementView: NSView {
    let browserView = NSView()

    private let serviceProvider: () -> MeetingManagementService?
    private let openRecording: () -> Void
    private let openWorkspaceFile: (String) -> Void
    private let presentConfirmationAlert: (NSAlert) -> NSApplication.ModalResponse
    private var onOpenSelection: () -> Void = {}

    private let table = NSTableView()
    private let queryField = NSSearchField()
    private let startDatePicker = NSDatePicker()
    private let endDatePicker = NSDatePicker()
    private let startDateEnabled = NSButton(checkboxWithTitle: "From", target: nil, action: nil)
    private let endDateEnabled = NSButton(checkboxWithTitle: "To", target: nil, action: nil)
    private let clearFiltersButton = NSButton(title: "Clear filters", target: nil, action: nil)
    private let projectFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let processingFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let archiveFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let filterStatus = NSTextField(labelWithString: "")
    private let advancedFiltersButton = NSButton(title: "Filters", target: nil, action: nil)
    private let advancedFilters = NSStackView()
    private enum MeetingQueue: Int { case recorded, attention, ready }
    private var selectedQueue: MeetingQueue = .recorded
    private var queueButtons: [NSButton] = []

    private let titleBar = NSStackView()
    private let caption = NSStackView()
    private let metadataBar = NSStackView()
    private let eyebrow = NSTextField(labelWithString: "MEETING DETAIL")
    private let meetingTitle = NSTextField(labelWithString: "")
    private let overview = NSTextField(wrappingLabelWithString: "")
    private let processingStatus = GraphiteFocusStatusLabel()
    private let statusBadge = NSView()
    private let summaryPlaceholder = NSTextField(wrappingLabelWithString: "Summary unavailable or still being generated.")
    private weak var summaryEditorScroll: NSScrollView?
    private weak var notesEditorScroll: NSScrollView?
    private var summaryOverviewSection: NSHostingView<MeetingOverviewSection>?
    private var notesOverviewSection: NSHostingView<MeetingOverviewSection>?
    private weak var summaryEditorRow: NSStackView?
    private weak var notesEditorRow: NSStackView?
    private let notes = NSTextView()
    private let summary = NSTextView()
    private let actionItems = NSTextField(wrappingLabelWithString: "")
    private let overviewPage = NSStackView()
    private let timelinePage = NSStackView()
    private let pinnedAudio = NSStackView()
    private var overviewScrollTop: NSLayoutConstraint?
    private var timelineScrollTop: NSLayoutConstraint?
    private let timelineRows = NSStackView()
    private let timelineNavigation = MeetingTimelineNavigation()
    private let transcriptionButton = MeetingHeaderButton(title: "", target: nil, action: nil)
    private let editSummaryTool = MeetingHeaderButton()
    private let editNotesTool = MeetingHeaderButton()
    private let moreButton = MeetingHeaderButton()
    private let toolbar = NSStackView()
    private let backButton = NSButton(title: "← Back to meeting", target: nil, action: nil)
    private var outcomeCopy: [String: String] = [:]
    private let files = NSStackView()
    private let transcriptRows = NSStackView()
    private let evidenceRows = NSStackView()
    private let myActionsContainer = NSStackView()
    private let outcomesContainer = NSStackView()
    private weak var notesSection: NSView?
    private var actionRows: [String: MeetingOutcomeRow] = [:]
    private var segmentLabels: [(MeetingTranscriptSegment, NSTextField)] = []
    private var displayedDetail: MeetingBrowserDetail?
    private var evidenceTargets: [String: EvidenceTarget] = [:]
    private var outcomeSourceTargets: [String: OutcomeSourceTarget] = [:]
    private let status = NSTextField(wrappingLabelWithString: "")
    private let retryRows = NSStackView()
    private let reprocessButton = NSButton(title: "Reprocess…", target: nil, action: nil)
    private let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    private let archiveButton = MeetingHeaderButton(title: "Archive", target: nil, action: nil)
    private var retryFeedback: (meetingID: String, message: String)?
    private let saveNotesButton = NSButton(title: "Save Notes", target: nil, action: nil)
    private let saveSummaryButton = NSButton(title: "Save Summary", target: nil, action: nil)
    private let openRecordingButton = NSButton(title: "Open Recording", target: nil, action: nil)
    private let audioStatus = NSTextField(wrappingLabelWithString: "Recording Bundle unavailable")
    private let playButton = MeetingPlaybackButton(frame: .zero)
    private let waveform = MeetingWaveformView()
    private var waveformRevision = UUID()
    private let audioTime = NSTextField(labelWithString: "0:00 / 0:00")
    private var audioTimeWidth: NSLayoutConstraint?
    private var waveformWidth: NSLayoutConstraint?
    private var audioPlayer: MeetingAudioPlayer?
    private var audioSource: MeetingPlayback?

    private var rows: [MeetingBrowserRow] = []
    private var selectedID: String?
    private var selectedDoorwayVersion: WorkspaceFileVersion?
    private var selectedSummaryVersion: WorkspaceFileVersion?
    private var loadedNotes = ""
    private var loadedSummary = ""
    private var isReloading = false
    private var timer: Timer?

    init(
        serviceProvider: @escaping () -> MeetingManagementService?,
        openRecording: @escaping () -> Void,
        openWorkspaceFile: @escaping (String) -> Void,
        presentConfirmationAlert: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    ) {
        self.serviceProvider = serviceProvider
        self.openRecording = openRecording
        self.openWorkspaceFile = openWorkspaceFile
        self.presentConfirmationAlert = presentConfirmationAlert
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildBrowser()
        buildDetail()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, !self.isHidden else { return }
            self.refresh(isVisible: true)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { timer?.invalidate(); audioPlayer?.stop() }

    func setOnOpenSelection(_ handler: @escaping () -> Void) {
        onOpenSelection = handler
    }

    func refresh(isVisible: Bool) {
        isHidden = !isVisible
        browserView.isHidden = !isVisible
        guard isVisible else { clearAudio(); return }
        reload()
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
        notes.font = GraphiteFocusPresentation.Typography.body
        notes.textColor = .labelColor
        notes.backgroundColor = .textBackgroundColor
        notes.setAccessibilityLabel("Meeting notes")
        notes.isRichText = false
        notes.alignment = .left
        summary.font = GraphiteFocusPresentation.Typography.body
        summary.textColor = .labelColor
        summary.backgroundColor = .textBackgroundColor
        summary.setAccessibilityLabel("Meeting Summary")
        summary.isRichText = false
        summary.alignment = .left
        summaryPlaceholder.font = GraphiteFocusPresentation.Typography.body
        summaryPlaceholder.textColor = .secondaryLabelColor
        summaryPlaceholder.alignment = .left
        summaryPlaceholder.isHidden = true
        actionItems.alignment = .left
        actionItems.setAccessibilityLabel("Meeting Action Items")
        actionItems.maximumNumberOfLines = 0
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
        saveNotesButton.target = self
        saveNotesButton.action = #selector(saveNotes)
        saveSummaryButton.target = self
        saveSummaryButton.action = #selector(saveSummary)
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
            constant: -(52 + 116 + 2 * GraphiteFocusPresentation.Space.compact))
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
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 36).isActive = true
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            toolbar.addArrangedSubview(button)
        }
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = GraphiteFocusPresentation.Space.compact
        toolbar.setContentCompressionResistancePriority(.required, for: .horizontal)
        // NSStackView's top alignment positions image-only buttons at different y values
        // depending on their symbols. Center each fixed-size native button in one row.
        [transcriptionButton, editSummaryTool, editNotesTool, archiveButton, moreButton].forEach { button in
            button.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor).isActive = true
        }
        transcriptionButton.target = self
        transcriptionButton.action = #selector(openTimeline)
        transcriptionButton.setAccessibilityIdentifier("meeting-open-transcription")
        backButton.target = self
        backButton.action = #selector(closeTimeline)
        backButton.setAccessibilityIdentifier("meeting-back-to-overview")
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
        pinnedAudio.addArrangedSubview(backButton)
        pinnedAudio.addArrangedSubview(section("Meeting audio", body: audioSection))
        pinnedAudio.isHidden = true
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
        titleBar.spacing = 0
        headerRow.widthAnchor.constraint(equalTo: titleBar.widthAnchor).isActive = true
        let notesSection = section("My notes", editor: notes, height: 90, button: saveNotesButton)
        self.notesSection = notesSection
        [section("AI summary", editor: summary, height: 150, button: saveSummaryButton),
         myActionsContainer, notesSection, outcomesContainer,
         retryRows, section("Source files", body: files), openRecordingButton].forEach { overviewPage.addArrangedSubview($0) }
        metadataBar.addArrangedSubview(overview)
        metadataBar.orientation = .horizontal
        metadataBar.alignment = .centerY
        overview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = GraphiteFocusPresentation.Radius.compact
        statusBadge.layer?.borderWidth = 1
        processingStatus.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.addSubview(processingStatus)
        NSLayoutConstraint.activate([
            processingStatus.leadingAnchor.constraint(equalTo: statusBadge.leadingAnchor, constant: GraphiteFocusPresentation.Space.compact),
            processingStatus.trailingAnchor.constraint(equalTo: statusBadge.trailingAnchor, constant: -GraphiteFocusPresentation.Space.compact),
            processingStatus.topAnchor.constraint(equalTo: statusBadge.topAnchor, constant: GraphiteFocusPresentation.Space.primitive),
            processingStatus.bottomAnchor.constraint(equalTo: statusBadge.bottomAnchor, constant: -GraphiteFocusPresentation.Space.primitive)
        ])
        caption.addArrangedSubview(titleBar)
        caption.addArrangedSubview(metadataBar)
        caption.addArrangedSubview(statusBadge)
        caption.orientation = .vertical
        caption.alignment = .leading
        caption.spacing = GraphiteFocusPresentation.Space.compact
        titleBar.widthAnchor.constraint(equalTo: caption.widthAnchor).isActive = true
        metadataBar.widthAnchor.constraint(lessThanOrEqualTo: caption.widthAnchor).isActive = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)
        for container in [myActionsContainer, outcomesContainer] {
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
        overviewScrollTop = scroll.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact)
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
            pinnedAudio.arrangedSubviews[1].widthAnchor.constraint(equalTo: pinnedAudio.widthAnchor),
            overviewScrollTop!,
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
    }

    private func section(_ title: String, editor: NSTextView, height: CGFloat, button: NSButton) -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = editor
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = GraphiteFocusPresentation.Radius.compact
        scroll.layer?.borderWidth = GraphiteFocusPresentation.Stroke.width
        scroll.layer?.borderColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).structuralStroke.cgColor
        editor.textContainerInset = NSSize(width: GraphiteFocusPresentation.Space.compact, height: GraphiteFocusPresentation.Space.compact)
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        scroll.setAccessibilityIdentifier(title.hasPrefix("AI summary") ? "meeting-summary-editor" : "meeting-notes-editor")
        let isSummary = title.hasPrefix("AI summary")
        let card = NSHostingView(rootView: MeetingOverviewSection(title: title, content: "", unavailable: "Content unavailable.",
            canEdit: false, expand: {}, edit: {}, copy: {}))
        card.translatesAutoresizingMaskIntoConstraints = false
        if isSummary { summaryOverviewSection = card; summaryEditorScroll = scroll }
        else { notesOverviewSection = card; notesEditorScroll = scroll }
        let editorRow = NSStackView(views: [scroll, button])
        editorRow.orientation = .vertical
        editorRow.alignment = .leading
        editorRow.spacing = GraphiteFocusPresentation.Space.compact
        editorRow.isHidden = true
        scroll.widthAnchor.constraint(equalTo: editorRow.widthAnchor).isActive = true
        let stack = NSStackView(views: [card, editorRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.compact
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        editorRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        if isSummary { summaryEditorRow = editorRow } else { notesEditorRow = editorRow }
        return stack
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
        selectedQueue = queue
        processingFilter.selectItem(at: 0)
        updateQueueButtons()
        reload()
    }

    private func updateQueueButtons() {
        for button in queueButtons {
            button.state = button.tag == selectedQueue.rawValue ? .on : .off
            button.setAccessibilityValue(button.state == .on ? "Selected" : "Not selected")
        }
    }

    private func matchesQueue(_ row: MeetingBrowserRow) -> Bool {
        switch selectedQueue {
        case .recorded: return true
        case .attention: return row.requiresAttention
        case .ready: return row.processingState == .ready && !row.requiresAttention
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

    private func reload() {
        isReloading = true
        defer { isReloading = false }
        guard let service = serviceProvider() else {
            clearAudio()
            selectedID = nil
            rows = []
            table.reloadData()
            GraphiteFocusPageHeader.setTitle("Meetings unavailable", on: meetingTitle)
            statusBadge.isHidden = true
            overview.stringValue = "Choose a workspace in Settings to see your Meetings."
            status.stringValue = "Meetings unavailable. Choose a workspace in Settings."
            clearEvidence()
            showUnavailableOverviewSections()
            reprocessButton.isEnabled = false
            renameButton.isEnabled = false
            archiveButton.isEnabled = false
            toolbar.isHidden = true
            return
        }
        do {
            let oldSelection = selectedID
            let selectedIDs = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
            let browserRows = try service.browserRows(filters: currentFilters())
            rows = browserRows.visible.filter(matchesQueue)
            configureProjectFilter(rows: browserRows.available)
            table.reloadData()
            updateFilterStatus(visibleCount: rows.count)
            guard !rows.isEmpty else {
                clearAudio()
                closeTimeline()
                selectedID = nil
                selectedDoorwayVersion = nil
                selectedSummaryVersion = nil
                GraphiteFocusPageHeader.setTitle("No matching Meetings", on: meetingTitle)
                statusBadge.isHidden = true
                summaryPlaceholder.isHidden = true
                summaryEditorRow?.isHidden = true
                notesEditorRow?.isHidden = true
                overview.stringValue = "Adjust the search or filters to see more Meetings."
                notes.string = ""
                summary.string = ""
                actionItems.stringValue = ""
                displayedDetail = nil
                clearEvidence()
                showUnavailableOverviewSections()
                files.arrangedSubviews.forEach { files.removeArrangedSubview($0); $0.removeFromSuperview() }
                saveNotesButton.isEnabled = false
                saveSummaryButton.isEnabled = false
                reprocessButton.isEnabled = false
                renameButton.isEnabled = false
                archiveButton.isEnabled = false
                toolbar.isHidden = true
                return
            }
            let index = oldSelection.flatMap { id in rows.firstIndex(where: { $0.id == id }) } ?? 0
            let indices = IndexSet(rows.indices.filter { selectedIDs.contains(rows[$0].id) })
            table.selectRowIndexes(indices.isEmpty ? IndexSet(integer: index) : indices, byExtendingSelection: false)
            show(row: index)
        } catch {
            clearAudio()
            status.stringValue = "Meetings unavailable: \(error.localizedDescription)"
            reprocessButton.isEnabled = false
            renameButton.isEnabled = false
            archiveButton.isEnabled = false
        }
    }

    private func configureProjectFilter(rows: [MeetingBrowserRow]) {
        let selected = projectFilter.selectedItem?.representedObject as? String
        let projects = Set(rows.compactMap(\.project)).sorted()
        projectFilter.removeAllItems()
        projectFilter.addItem(withTitle: "All Projects")
        for project in projects {
            projectFilter.addItem(withTitle: project)
            projectFilter.lastItem?.representedObject = project
        }
        if let selected, let index = projectFilter.itemArray.firstIndex(where: { ($0.representedObject as? String) == selected }) {
            projectFilter.selectItem(at: index)
        }
    }

    private func updateFilterStatus(visibleCount: Int) {
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

    private func show(row index: Int) {
        guard rows.indices.contains(index), let service = serviceProvider() else { return }
        do {
            let selected = try service.detail(for: rows[index])
            let changedMeeting = selectedID != selected.row.id
            if selectedID != selected.row.id || audioSource != selected.playback || audioPlayer == nil && selected.playback.capability != .unavailable {
                bindAudio(selected.playback)
            }
            selectedID = selected.row.id
            waveform.colors = presentationColors
            playButton.updateAppearance()
            selectedDoorwayVersion = selected.doorwayVersion
            selectedSummaryVersion = selected.summaryVersion
            GraphiteFocusPageHeader.setTitle(selected.row.title, on: meetingTitle)
            statusBadge.isHidden = false
            processingStatus.setStatus(statusTitle(for: selected.row),
                meaning: statusMeaning(for: selected.row), colors: presentationColors)
            styleStatusBadge(meaning: statusMeaning(for: selected.row))
            overview.stringValue = detailOverview(selected)
            summaryPlaceholder.isHidden = true
            if changedMeeting {
                timelineNavigation.jump = nil
                closeTimeline()
                summaryEditorRow?.isHidden = true
                notesEditorRow?.isHidden = true
            }
            if changedMeeting || notes.string == loadedNotes {
                notes.string = selected.humanNotes
                loadedNotes = selected.humanNotes
            }
            let renderedSummary = selected.summary?.summary ?? ""
            if changedMeeting || summary.string == loadedSummary {
                summary.string = renderedSummary
                loadedSummary = renderedSummary
            }
            updateOverviewSections(selected)
            actionItems.stringValue = actionItemText(selected)
            let evidenceChanged = displayedDetail != selected || changedMeeting
            displayedDetail = selected
            if evidenceChanged { renderEvidence(selected) }
            toolbar.isHidden = false
            transcriptionButton.isEnabled = true
            editSummaryTool.isEnabled = selectedSummaryVersion != nil
            let hasNotes = !selected.humanNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            editNotesTool.isHidden = !hasNotes
            notesSection?.isHidden = !hasNotes
            editNotesTool.isEnabled = selectedDoorwayVersion != nil
            saveNotesButton.isEnabled = selectedDoorwayVersion != nil
            saveSummaryButton.isEnabled = selectedSummaryVersion != nil
            openRecordingButton.isHidden = selected.row.captureState != .live
            renderArtifacts(selected.artifacts)
            renderRetryActions(selected)
            let canChangeFolder = selected.row.captureState == .stopped && !selected.jobs.contains(where: { $0.status == .queued || $0.status == .running })
            reprocessButton.isEnabled = canChangeFolder
            renameButton.isEnabled = canChangeFolder && selected.doorwayVersion != nil
            let archiveName = selected.row.isArchived ? "Restore meeting" : "Archive meeting"
            archiveButton.image = NSImage(systemSymbolName: selected.row.isArchived ? "arrow.uturn.backward" : "archivebox", accessibilityDescription: archiveName)
            archiveButton.toolTip = archiveName
            archiveButton.setAccessibilityLabel(archiveName)
            archiveButton.isEnabled = selected.row.captureState != .live
            status.stringValue = retryFeedback?.meetingID == selected.row.id
                ? retryFeedback!.message
                : (selected.summary == nil ? "Summary unavailable or still being generated." : "")
        } catch {
            clearAudio()
            status.stringValue = "Meeting unavailable: \(error.localizedDescription)"
        }
    }

    func validateBrowserFilterPresentationFixture() {
        let savedQuery = queryField.stringValue
        let savedQueue = selectedQueue
        defer {
            queryField.stringValue = savedQuery
            selectedQueue = savedQueue
            updateQueueButtons()
            updateFilterStatus(visibleCount: rows.count)
        }
        precondition(queryField.placeholderString == "Filter meetings", "Meeting browser field must be labeled as a row filter")
        precondition(queryField.accessibilityLabel() as? String == "Filter meetings", "Meeting browser filter must have a distinct VoiceOver name")
        queryField.stringValue = "roadmap"
        selectedQueue = .ready
        updateQueueButtons()
        updateFilterStatus(visibleCount: 2)
        precondition(filterStatus.stringValue.contains("Queue: Ready") && filterStatus.stringValue.contains("Text: “roadmap”"),
                     "Meeting browser must show active list filter context")
    }

    func validateLongContentOverflowFixture() {
        let savedQuery = queryField.stringValue
        let savedStatus = filterStatus.stringValue
        defer {
            queryField.stringValue = savedQuery
            filterStatus.stringValue = savedStatus
            GraphiteFocusOverflow.configureSecondaryMetadata(filterStatus, fullText: savedStatus)
        }
        let longTitle = "Зустріч із надзвичайно довгою перекладеною назвою про контрольні інтерфейси, цитати, фільтри та поведінку переповнення на підтримуваному мінімумі"
        GraphiteFocusPageHeader.setTitle(longTitle, on: meetingTitle)
        precondition(meetingTitle.maximumNumberOfLines == 1 && meetingTitle.lineBreakMode == .byTruncatingTail,
                     "Long Meeting titles must tail-truncate visually")
        precondition(meetingTitle.toolTip == longTitle && meetingTitle.accessibilityLabel() == longTitle,
                     "Long Meeting titles must remain readable in full")
        queryField.stringValue = "надзвичайно-довгий-фільтр-який-не-може-витіснити-список"
        updateFilterStatus(visibleCount: 0)
        precondition(filterStatus.toolTip?.contains(queryField.stringValue) == true,
                     "Filtered empty state must expose full active Meeting filters")
        let path = "Meetings/2026/09/20/дуже-довга-назва-наради-з-перекладеним-шляхом/transcript.json"
        let pathLabel = NSTextField(labelWithString: path)
        GraphiteFocusOverflow.configureSecondaryMetadata(pathLabel, fullText: path)
        precondition(pathLabel.lineBreakMode == .byTruncatingMiddle && pathLabel.toolTip == path,
                     "Long source paths may truncate only with a full-text route")
        let prose = NSTextField(wrappingLabelWithString: "Status explanation with a long localized-looking sentence wraps instead of clipping or using an ellipsis as the sole essential state text.")
        GraphiteFocusOverflow.configureWrappingText(prose, fullText: prose.stringValue)
        precondition(prose.maximumNumberOfLines == 0 && prose.lineBreakMode == .byWordWrapping,
                     "Status explanations and prose must wrap")
        let citations = NSPopUpButton(frame: .zero, pullsDown: true)
        citations.addItem(withTitle: "Sources (6)")
        citations.setAccessibilityLabel("Transcript sources for the cited action")
        precondition(citations.accessibilityLabel() == "Transcript sources for the cited action",
                     "Crowded citations must have an accessible disclosure or menu route")
    }

    func validateTimelineSelectionFixture() {
        let kinds = Set(MeetingTimelineMoment.Kind.allCases)
        let moments = (0..<240).map { index in
            MeetingTimelineMoment(id: "\(index)", seconds: Double(index * 60),
                kind: index.isMultiple(of: 3) ? .action : .transcript,
                text: index == 235 ? "unique late phrase" : "ordinary", context: "Speaker", seekSeconds: Double(index * 60))
        }
        let first = MeetingTimelineSelection.visible(moments, included: kinds, position: 0, query: "")
        precondition(first.count == 15 && first.last?.seconds == 840, "Ordinary browsing must bound a four-hour timeline")
        let fourthHour = MeetingTimelineSelection.visible(moments, included: [.action], position: 3 * 3600 + 15 * 60, query: "")
        precondition(fourthHour.allSatisfy { $0.kind == .action && $0.seconds >= 11700 && $0.seconds < 12600 },
                     "Hour jumps and independent filters must respect the selected window")
        precondition(MeetingTimelineSelection.visible(moments, included: kinds, position: 0, query: "unique late phrase").count == 1,
                     "Search must cover the whole recording")
        precondition(MeetingTimelineSelection.visible(moments, included: kinds, position: 0, query: "no match").isEmpty,
                     "Missing search terms must produce an empty result")
        openTimeline()
        precondition(!caption.isHidden && overviewPage.isHidden && !timelinePage.isHidden,
                     "Transcript replaces detail content but retains the meeting header")
        closeTimeline()
        precondition(!overviewPage.isHidden && timelinePage.isHidden, "Back must restore meeting details")
    }

    func validateCaptionLayoutFixture() {
        let savedTitle = meetingTitle.stringValue
        let savedOverview = overview.stringValue
        let savedHidden = statusBadge.isHidden
        defer {
            GraphiteFocusPageHeader.setTitle(savedTitle, on: meetingTitle)
            overview.stringValue = savedOverview
            statusBadge.isHidden = savedHidden
        }
        GraphiteFocusPageHeader.setTitle("Untitled Meeting at 2026-10-07 17:35 — This deliberately localized-looking title continues far beyond the available header width so the Page Header title must truncate at the tail while all local actions remain visible", on: meetingTitle)
        overview.stringValue = "7 Oct 2026 at 17:35  ·  Project: Orchid"
        statusBadge.isHidden = false
        processingStatus.setStatus("Ready", meaning: .success, colors: presentationColors)
        styleStatusBadge(meaning: .success)
        layoutSubtreeIfNeeded()
        let title = meetingTitle.convert(meetingTitle.bounds, to: self)
        let metadata = overview.convert(overview.bounds, to: self)
        let state = statusBadge.convert(statusBadge.bounds, to: self)
        precondition(bounds.height - title.maxY < 85, "Meeting caption must occupy the compact top region")
        let toolbarFrame = toolbar.convert(toolbar.bounds, to: self)
        precondition(meetingTitle.maximumNumberOfLines == 1 && meetingTitle.lineBreakMode == .byTruncatingTail,
                     "Meeting Page Header title must be a single tail-truncated line")
        precondition(meetingTitle.toolTip == meetingTitle.stringValue && meetingTitle.accessibilityLabel() == meetingTitle.stringValue,
                     "Meeting Page Header title must expose the complete title outside the truncated visual line")
        precondition(title.maxX <= toolbarFrame.minX - GraphiteFocusPresentation.Space.compact + 1,
                     "Meeting title must yield width before overlapping local header actions")
        precondition(state.minY >= metadata.maxY - 1, "Meeting state must occupy the third caption line")
        precondition(abs(state.minX - metadata.minX) < 2, "Meeting state must align with the date")
        precondition(abs(toolbarFrame.maxX - caption.convert(caption.bounds, to: self).maxX) < 2,
                     "Meeting controls must align to the right edge of the caption")
        precondition(transcriptionButton.bounds.width == 36 && transcriptionButton.bounds.height == 36,
                     "Meeting toolbar controls must match the reference dimensions")
        let controls = [transcriptionButton, editSummaryTool, editNotesTool, archiveButton, moreButton]
        for control in controls {
            let frame = control.convert(control.bounds, to: toolbar)
            let reference = transcriptionButton.convert(transcriptionButton.bounds, to: toolbar)
            precondition(abs(frame.minY - reference.minY) < 1 && abs(frame.maxY - reference.maxY) < 1,
                         "Meeting header buttons must share top and bottom edges")
        }
    }

    func validateAudioTransportFixture() {
        timer?.invalidate() // The synthetic fixture must not be replaced by the shell's periodic reload.
        if let root = ProcessInfo.processInfo.environment["STILLMATTER_REPLAY_WORKSPACE_ROOT"],
           let recordingID = ProcessInfo.processInfo.environment["STILLMATTER_REPLAY_RECORDING_ID"] {
            let vault = WorkspaceVault(workspaceRootURL: URL(fileURLWithPath: root),
                appSupportRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterAudioReplay-\(UUID().uuidString)"))
            let service = MeetingManagementService(vault: vault)
            let matches = (try? service.list())?.filter { row in
                guard let data = try? vault.readMarkdown(relativePath: row.meetingRelativePath).data,
                      let text = String(data: data, encoding: .utf8) else { return false }
                return text.components(separatedBy: .newlines).contains { $0.hasPrefix("recording_bundle:") && $0.contains(recordingID) }
            } ?? []
            precondition(matches.count == 1, "Replay must select exactly one recording")
            let playback = try! service.detail(for: matches[0].meetingRelativePath).playback
            precondition(playback.capability != .unavailable, "Replay bundle must be playable")
            bindAudio(playback)
            precondition(playButton.isEnabled, "Replay Play must be enabled")
            playButton.performClick(nil)
            let deadline = Date().addingTimeInterval(3)
            while (audioPlayer?.elapsed ?? 0) < 0.05 && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition((audioPlayer?.elapsed ?? 0) >= 0.05, "Replay Play must advance audio")
            precondition(audioPlayer?.activeTrackCount == (playback.systemPath == nil ? 1 : 2),
                         "Replay must play both available source tracks together")
            clearAudio()
        }
        clearAudio()
        precondition(!playButton.isEnabled && !waveform.isEnabled, "Missing Meeting audio must not expose a functional transport")
        precondition(audioStatus.stringValue.contains("Recording Bundle unavailable"), "Missing audio must explain the unavailable state")
        precondition(playButton.accessibilityLabel() == "Play Meeting audio", "Transport needs a spoken play label")
        precondition(waveform.accessibilityLabel() == "Meeting audio position", "Timeline needs a spoken seek label")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Stillmatter-MeetingAudio-\(UUID().uuidString).caf")
        defer { clearAudio(); try? FileManager.default.removeItem(at: file) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            try { () throws in
                let writer = try AVAudioFile(forWriting: file, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
                buffer.frameLength = 48000
                try writer.write(from: buffer)
            }()
            let original = try Data(contentsOf: file)
            let waveformLevels = MeetingWaveformView.sample(path: file.path, duration: 1)
            precondition(waveformLevels.count == 96 && waveformLevels.allSatisfy { (0...1).contains($0) },
                         "Waveform sampling must be bounded and normalized")
            bindAudio(MeetingPlayback(capability: .microphoneOnly, microphonePath: file.path,
                durationSeconds: 1, message: "Partial recording: microphone-only audio; system audio unavailable."))
            precondition(playButton.isEnabled && waveform.isEnabled, "Recovered microphone audio needs one transport")
            precondition(audioStatus.stringValue.contains("microphone-only"), "Degraded playback must be labeled")
            precondition(abs(waveform.maxValue - 1) < 0.01, "Seek range must match playable duration")
            precondition(waveform.accessibilityRole() == .slider, "Waveform must retain native slider accessibility")
            openTimeline()
            layoutSubtreeIfNeeded()
            precondition(waveform.bounds.width > 100 && waveform.bounds.height > 0,
                         "Playable audio must have a visible, full-width seek target in the real detail layout")
            waveform.setFrameSize(NSSize(width: 220, height: 44))
            let click = NSEvent.mouseEvent(with: .leftMouseDown,
                location: waveform.convert(NSPoint(x: 110, y: 22), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            waveform.mouseDown(with: click)
            precondition(abs((audioPlayer?.elapsed ?? 0) - 0.5) < 0.01,
                         "Clicking the waveform must seek the selected Meeting audio")
            let drag = NSEvent.mouseEvent(with: .leftMouseDragged,
                location: waveform.convert(NSPoint(x: 160, y: 22), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            waveform.mouseDragged(with: drag)
            precondition(abs((audioPlayer?.elapsed ?? 0) - 0.75) < 0.01,
                         "Dragging the waveform must seek continuously")
            audioPlayer?.seek(to: 10)
            precondition(abs(waveform.doubleValue - 1) < 0.01, "Seeking past the end must clamp")
            audioPlayer?.seek(to: 0)
            let playbackStartedAt = Date()
            playButton.performClick(nil)
            precondition(audioPlayer?.isPlaying == true && playButton.title == "Pause" &&
                         playButton.accessibilityLabel() == "Pause Meeting audio",
                         "Activating Play must start playback and offer Pause")
            let syntheticPlaybackDeadline = Date().addingTimeInterval(2)
            while ((audioPlayer?.elapsed ?? 0) < 0.05 || waveform.doubleValue == 0) && Date() < syntheticPlaybackDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition((audioPlayer?.elapsed ?? 0) >= 0.05 && waveform.doubleValue > 0,
                         "Play must advance audio and its visible timeline")
            while Date().timeIntervalSince(playbackStartedAt) < 0.65 {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition((audioPlayer?.elapsed ?? 0) < 0.9 && audioPlayer?.isPlaying == true,
                         "Playback must not count elapsed device time again on every timer tick")
            waveform.mouseDown(with: click)
            precondition(abs((audioPlayer?.elapsed ?? 0) - 0.5) < 0.08 && audioPlayer?.isPlaying == true,
                         "Seeking during playback must move the playhead without stopping playback")
            playButton.performClick(nil)
            precondition(audioPlayer?.isPlaying == false && playButton.title == "Play" &&
                         playButton.accessibilityLabel() == "Play Meeting audio",
                         "Activating Pause must stop playback and offer Play")

            let workspaceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("Stillmatter-MeetingSelection-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: workspaceRoot) }
            try FileManager.default.createDirectory(at: workspaceRoot, withIntermediateDirectories: true)
            let vault = WorkspaceVault(workspaceRootURL: workspaceRoot, appSupportRootURL: workspaceRoot.appendingPathComponent("Support"))
            for id in ["first", "second"] {
                let audioURL = workspaceRoot.appendingPathComponent("\(id).caf")
                try FileManager.default.copyItem(at: file, to: audioURL)
                let metadataURL = workspaceRoot.appendingPathComponent("\(id).json")
                try Data("{}".utf8).write(to: metadataURL)
                var microphone = MicTrackRecordingMetadata(
                    captureSessionID: id,
                    meetingRelativePath: "Meetings/\(id)/meeting.md",
                    recoveryFilePath: audioURL.path,
                    finalFilePath: workspaceRoot.appendingPathComponent("\(id).m4a").path,
                    metadataFilePath: metadataURL.path,
                    startedAt: Date(),
                    sampleRate: 48_000,
                    channelCount: 1
                )
                microphone.status = .partial
                microphone.durationSeconds = 1
                let bundle = try RecordingBundleFinalizer().finalize(mic: microphone, system: nil, reason: .recovery)
                _ = try vault.writeMarkdown(
                    Data("---\ntitle: \(id)\ncapture_session_id: \(id)\nrecording_bundle: \(bundle.bundleFilePath)\n---\n# \(id)\n".utf8),
                    relativePath: "Meetings/\(id)/meeting.md",
                    expectedVersion: nil
                )
                let transcript = #"{"schema_version":1,"capture_session_id":"\#(id)","meeting_relative_path":"Meetings/\#(id)/meeting.md","language":"en","detected_languages":["en"],"engine":"fixture","model":"fixture","generated_at":"2026-01-01T00:00:00Z","audio_sources":[],"segments":[{"id":"s1","start":0.1,"end":0.4,"text":"Evidence \#(id)","language":"en","track":"microphone","speaker":"Me"}],"diagnostics":[]}"#
                _ = try vault.writeMarkdown(Data(transcript.utf8), relativePath: "Meetings/\(id)/transcript.json", expectedVersion: nil)
                let extraction = #"{"schema_version":1,"meeting":"Meetings/\#(id)/meeting.md","transcript":"Meetings/\#(id)/transcript.json","decisions":[{"id":"d1","text":"Decision \#(id)","citations":[{"segment_id":"s1","start_seconds":0.1,"end_seconds":0.4}]}],"my_action_items":[],"other_action_items":[],"open_questions":[]}"#
                _ = try vault.writeMarkdown(Data(extraction.utf8), relativePath: "Meetings/\(id)/summary-extraction.json", expectedVersion: nil)
            }
            let selectionView = MeetingManagementView(
                serviceProvider: { MeetingManagementService(vault: vault) },
                openRecording: {},
                openWorkspaceFile: { _ in }
            )
            selectionView.refresh(isVisible: true)
            precondition(selectionView.segmentLabels.count == 1 && selectionView.evidenceRows.arrangedSubviews.count > 1,
                         "Selected Meeting must show its Transcript and cited decision")
            let segmentButton = selectionView.transcriptRows.arrangedSubviews.compactMap { $0 as? NSButton }.first!
            selectionView.seekEvidence(segmentButton)
            precondition(abs(selectionView.waveform.doubleValue - 0.1) < 0.01, "Transcript segment must seek selected audio")
            selectionView.audioPlayer?.seek(to: 0.8)
            precondition(selectionView.segmentLabels[0].1.font?.fontDescriptor.symbolicTraits.contains(.bold) == false,
                         "Gaps must not highlight a Transcript segment")
            let firstEvidence = selectionView.evidenceRows.arrangedSubviews.compactMap { $0 as? NSButton }.first!
            precondition(firstEvidence.accessibilityLabel()?.contains("approximately") == true, "Evidence seek must be accessible and approximate")
            selectionView.seekEvidence(firstEvidence)
            precondition(abs(selectionView.waveform.doubleValue - 0.1) < 0.01, "Cited outcome must seek selected audio")
            precondition(selectionView.segmentLabels[0].1.font?.fontDescriptor.symbolicTraits.contains(.bold) == true,
                         "Playback position must highlight the current segment")
            selectionView.playButton.performClick(nil)
            precondition(selectionView.playButton.title == "Pause", "Selected Meeting Play must offer Pause")
            guard let firstPlayer = selectionView.audioPlayer else {
                preconditionFailure("First Meeting must bind its audio player")
            }
            selectionView.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            selectionView.show(row: 1)
            let secondPlayer = selectionView.audioPlayer
            selectionView.seekEvidence(firstEvidence)
            precondition(selectionView.audioPlayer === secondPlayer && selectionView.waveform.doubleValue == 0,
                         "Stale evidence must not seek the new Meeting")
            precondition(selectionView.segmentLabels[0].1.stringValue.contains(selectionView.rows[1].title),
                         "Transcript must switch with the selected Meeting")
            precondition(selectionView.audioPlayer !== firstPlayer && !firstPlayer.isPlaying,
                         "Selecting another Meeting must stop and replace the previous Meeting player")
            precondition(selectionView.playButton.title == "Play" &&
                         selectionView.playButton.accessibilityLabel() == "Play Meeting audio",
                         "Switching Meetings must reset Play and its spoken label")
            let secondTimeline = selectionView.audioTime.stringValue
            firstPlayer.seek(to: 0.5)
            precondition(selectionView.audioTime.stringValue == secondTimeline,
                         "A stale Meeting player must not update the selected Meeting timeline")
            let readable = selectionView.displayedDetail!
            selectionView.bindAudio(MeetingPlayback(capability: .unavailable, message: "Audio unavailable"))
            selectionView.renderEvidence(readable)
            precondition(selectionView.segmentLabels.count == 1 &&
                         selectionView.transcriptRows.arrangedSubviews.compactMap({ $0 as? NSButton }).isEmpty &&
                         selectionView.transcriptRows.arrangedSubviews.contains(where: { ($0 as? NSTextField)?.stringValue.contains("Seek unavailable") == true }),
                         "Transcript stays readable without audio, with no working evidence seek")

            let jobStore = try JobStore(databaseURL: workspaceRoot.appendingPathComponent("Support/retry-fixture.sqlite"))
            let scheduler = JobScheduler(store: jobStore, executor: RetryFixtureExecutor())
            _ = try scheduler.enqueue(id: "failed-first", manifest: JobManifest(
                type: MeetingSummaryJob.type, title: "Summarize first", executionClass: .heavy,
                stages: [JobStageDefinition(id: "summarize", title: "Generate Summary")],
                metadata: ["capture_session_id": "first"], maxAutomaticRetries: 0))
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline && (try? jobStore.job(id: "failed-first")?.status) != .failed {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            let failedFixtureJob = try jobStore.job(id: "failed-first")
            precondition(failedFixtureJob?.status == .failed, "Retry fixture must fail")
            let retryView = MeetingManagementView(serviceProvider: {
                MeetingManagementService(vault: vault, jobStore: jobStore, retryUnavailableReason: { _ in nil },
                    retryDispatcher: { _, id, path, session in
                        try scheduler.retry(id: id, meetingRelativePath: path, captureSessionID: session)
                    })
            }, openRecording: {}, openWorkspaceFile: { _ in })
            retryView.refresh(isVisible: true)
            let firstIndex = retryView.rows.firstIndex(where: { $0.id == "first" })!
            retryView.table.selectRowIndexes(IndexSet(integer: firstIndex), byExtendingSelection: false)
            retryView.show(row: firstIndex)
            let retryButton = retryView.retryRows.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first }.first
            precondition(retryButton?.isEnabled == true && retryButton?.accessibilityLabel()?.contains("Summarize first") == true,
                         "Failed Meeting needs an accessible Retry control")
            retryView.retryFailedJob(retryButton!)
            precondition(retryView.status.stringValue.contains("Retry queued") && retryView.selectedID == "first",
                         "Retry feedback and selected Meeting must survive refresh")
            precondition(retryView.retryRows.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first }.isEmpty,
                         "Repeated Retry must not remain available while processing")
            retryView.refresh(isVisible: false)

            let cancelView = MeetingManagementView(serviceProvider: {
                MeetingManagementService(vault: vault, jobStore: jobStore, retryUnavailableReason: { _ in nil })
            }, openRecording: {}, openWorkspaceFile: { _ in }, presentConfirmationAlert: { alert in
                precondition(alert.buttons.count == 2, "Actions must offer Cancel")
                if alert.messageText.contains("Rename") {
                    precondition(alert.informativeText.contains("outside Stillmatter") &&
                                 (alert.accessoryView as? NSTextField)?.stringValue == "second",
                                 "Rename must warn about external links and offer the current title")
                } else {
                    precondition(alert.informativeText.contains("manual Summary edits"),
                                 "Reprocess must warn about replacement")
                    precondition((alert.accessoryView as? NSPopUpButton)?.itemTitles == ["English", "Ukrainian"],
                                 "Reprocess must offer both supported languages")
                }
                return .alertSecondButtonReturn
            })
            cancelView.refresh(isVisible: true)
            let cancelIndex = cancelView.rows.firstIndex(where: { $0.id == "second" })!
            cancelView.table.selectRowIndexes(IndexSet(integer: cancelIndex), byExtendingSelection: false)
            cancelView.show(row: cancelIndex)
            let beforeCancel = try jobStore.jobs().count
            cancelView.confirmReprocess()
            cancelView.confirmRename()
            let originalDoorway = try vault.versionOfMarkdown(relativePath: "Meetings/second/meeting.md")
            precondition(originalDoorway != nil && cancelView.selectedID == "second",
                         "Cancel Rename must leave Meeting and selection intact")
            let afterCancel = try jobStore.jobs().count
            precondition(afterCancel == beforeCancel && cancelView.selectedID == "second",
                         "Cancel must not queue work or change Meeting selection")
            cancelView.refresh(isVisible: false)

            let renameView = MeetingManagementView(serviceProvider: {
                MeetingManagementService(vault: vault, jobStore: jobStore)
            }, openRecording: {}, openWorkspaceFile: { _ in }, presentConfirmationAlert: { alert in
                precondition(alert.informativeText.contains("outside Stillmatter"),
                             "Rename confirmation must warn about external links")
                (alert.accessoryView as? NSTextField)?.stringValue = "Renamed second"
                return .alertFirstButtonReturn
            })
            renameView.refresh(isVisible: true)
            let renameIndex = renameView.rows.firstIndex(where: { $0.id == "second" })!
            renameView.table.selectRowIndexes(IndexSet(integer: renameIndex), byExtendingSelection: false)
            renameView.show(row: renameIndex)
            renameView.confirmRename()
            precondition(renameView.selectedID == "second" && renameView.status.stringValue == "Meeting renamed." &&
                         renameView.rows.contains(where: { $0.id == "second" && $0.title == "Renamed second" }),
                         "Confirmed Rename must preserve selection and display the new title")
            let removedDoorway = try vault.versionOfMarkdown(relativePath: "Meetings/second/meeting.md")
            precondition(removedDoorway == nil, "Confirmed Rename must remove the old path")
            renameView.refresh(isVisible: false)

            let archiveView = MeetingManagementView(serviceProvider: {
                MeetingManagementService(vault: vault)
            }, openRecording: {}, openWorkspaceFile: { _ in })
            archiveView.refresh(isVisible: true)
            let archiveIndex = archiveView.rows.firstIndex(where: { $0.id == "first" })!
            archiveView.table.selectRowIndexes(IndexSet(integer: archiveIndex), byExtendingSelection: false)
            archiveView.show(row: archiveIndex)
            archiveView.archiveButton.performClick(nil)
            precondition(!archiveView.rows.contains(where: { $0.id == "first" }),
                         "Archive must hide the Meeting from the current list")
            archiveView.archiveFilter.selectItem(at: 1)
            archiveView.refresh(isVisible: true)
            precondition(archiveView.rows.map(\.id) == ["first"] &&
                         archiveView.displayedDetail?.row.isArchived == true &&
                         archiveView.archiveButton.title == "Restore",
                         "Archived filter must expose the Meeting detail and Restore")
            archiveView.archiveButton.performClick(nil)
            precondition(archiveView.archiveFilter.indexOfSelectedItem == 0 &&
                         archiveView.selectedID == "first" &&
                         archiveView.rows.contains(where: { $0.id == "first" && !$0.isArchived }),
                         "Restore must return the same Meeting to the current list and selection")
            archiveView.refresh(isVisible: false)

            selectionView.refresh(isVisible: false)
            precondition(selectionView.evidenceRows.arrangedSubviews.isEmpty && selectionView.audioPlayer == nil,
                         "Leaving Meetings must remove evidence controls and stop audio")
            clearAudio() // Leaving Meetings stops the previous audio.
            precondition(!playButton.isEnabled && waveform.doubleValue == 0 && audioPlayer == nil,
                         "Leaving Meetings must discard the old Meeting timeline")
            let after = try Data(contentsOf: file)
            precondition(after == original, "Listening must not modify source audio")
        } catch { preconditionFailure("Meeting audio shell fixture failed: \(error)") }
    }

    private func clearAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
        waveformRevision = UUID()
        waveform.levels = []
        waveform.doubleValue = 0
        displayedDetail = nil
        clearEvidence()
        audioSource = nil
        audioStatus.stringValue = "Recording Bundle unavailable. Check the recording media location."
        playButton.isEnabled = false
        playButton.title = "Play"
        playButton.needsDisplay = true
        playButton.toolTip = "Play Meeting audio"
        playButton.setAccessibilityLabel("Play Meeting audio")
        waveform.isEnabled = false
        waveform.doubleValue = 0
        audioTime.stringValue = "0:00 / 0:00"
        audioTimeWidth?.constant = 116
        waveformWidth?.constant = -(52 + 116 + 2 * GraphiteFocusPresentation.Space.compact)
        updateActiveSegment(at: nil)
    }

    private func bindAudio(_ playback: MeetingPlayback) {
        clearAudio()
        audioSource = playback
        audioStatus.stringValue = playback.message
        guard playback.capability != .unavailable else { return }
        do {
            let player = try MeetingAudioPlayer(playback: playback)
            audioPlayer = player
            loadWaveform(for: playback, duration: player.duration)
            waveform.maxValue = player.duration
            // Hour-long recordings use two HH:MM:SS labels, not the short MM:SS pair.
            let labelWidth: CGFloat = player.duration >= 3600 ? 180 : 116
            audioTimeWidth?.constant = labelWidth
            waveformWidth?.constant = -(52 + labelWidth + 2 * GraphiteFocusPresentation.Space.compact)
            waveform.isEnabled = true
            playButton.isEnabled = true
            audioTime.stringValue = "0:00 / \(timeLabel(player.duration))"
            player.onTimeChange = { [weak self, weak player] seconds, playing in
                guard let self, let player, self.audioPlayer === player else { return }
                self.waveform.doubleValue = seconds
                self.audioTime.stringValue = "\(self.timeLabel(seconds)) / \(self.timeLabel(player.duration))"
                self.updateActiveSegment(at: seconds)
                self.playButton.title = playing ? "Pause" : "Play"
                self.playButton.needsDisplay = true
                self.playButton.toolTip = playing ? "Pause Meeting audio" : "Play Meeting audio"
                self.playButton.setAccessibilityLabel(self.playButton.toolTip)
            }
        } catch {
            audioStatus.stringValue = "Audio cannot be prepared for playback. Inspect the Recording Bundle and its source recordings."
        }
    }

    private func loadWaveform(for playback: MeetingPlayback, duration: Double) {
        let revision = waveformRevision
        let microphone = playback.microphonePath
        let system = playback.systemPath
        let microphoneOffset = playback.microphoneOffsetSeconds
        let systemOffset = playback.systemOffsetSeconds
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let mic = microphone.map { MeetingWaveformView.sample(path: $0, duration: duration, offset: microphoneOffset) } ?? []
            let other = system.map { MeetingWaveformView.sample(path: $0, duration: duration, offset: systemOffset) } ?? []
            let levels = (0..<max(mic.count, other.count)).map { index in
                max(index < mic.count ? mic[index] : 0, index < other.count ? other[index] : 0)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.waveformRevision == revision else { return }
                self.waveform.levels = levels
            }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "unknown" }
        let whole = Int(min(seconds, Double(Int.max / 120)))
        if whole >= 3600 { return String(format: "%02d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60) }
        return "\(whole / 60):\(String(format: "%02d", whole % 60))"
    }

    @objc private func toggleAudio() {
        guard let audioPlayer else { return }
        if audioPlayer.isPlaying { audioPlayer.pause() } else { audioPlayer.play() }
    }

    @objc private func seekAudio(_ sender: NSSlider) { audioPlayer?.seek(to: sender.doubleValue) }

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

    private var presentationColors: GraphiteFocusPresentation.Colors {
        GraphiteFocusPresentation.Colors(environment: .system(window: window))
    }

    private func styleStatusBadge(meaning: GraphiteFocusStatusMeaning) {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        let tint = meaning.color(in: colors)
        let fill = colors.surfacePanel
        // Meeting readiness is a state label, not a green action or panel.
        processingStatus.textColor = meaning == .success ? colors.accent : tint
        statusBadge.layer?.backgroundColor = fill.cgColor
        statusBadge.layer?.borderColor = (meaning == .success ? colors.accent : tint).withAlphaComponent(0.48).cgColor
    }

    private func statusMeaning(for row: MeetingBrowserRow) -> GraphiteFocusStatusMeaning {
        if row.job?.status == .failed { return .destructive }
        switch row.processingState {
        case .ready: return .success
        case .live, .processing, .needsAttention: return .attention
        case .unavailable: return .destructive
        }
    }

    private func statusTitle(for row: MeetingBrowserRow) -> String {
        row.job?.status == .failed ? "Job failed · \(row.processingState.displayName)" : row.processingState.displayName
    }

    private func statusText(for row: MeetingBrowserRow) -> String {
        "\(statusMeaning(for: row).symbol) \(statusTitle(for: row))"
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

    private func renderSummary(_ sections: MeetingSummarySections) -> String {
        ["## Summary", sections.summary, "## Decisions", sections.decisions, "## My action items", sections.myActionItems, "## Other action items", sections.otherActionItems, "## Open questions", sections.openQuestions]
            .joined(separator: "\n\n")
    }

    private func summarySections(from text: String) -> MeetingSummarySections {
        var sections = MeetingSummarySections()
        var heading = ""
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("## ") {
                heading = String(line.dropFirst(3)).lowercased()
                continue
            }
            switch heading {
            case "summary": sections.summary += (sections.summary.isEmpty ? "" : "\n") + line
            case "decisions": sections.decisions += (sections.decisions.isEmpty ? "" : "\n") + line
            case "my action items": sections.myActionItems += (sections.myActionItems.isEmpty ? "" : "\n") + line
            case "other action items": sections.otherActionItems += (sections.otherActionItems.isEmpty ? "" : "\n") + line
            case "open questions": sections.openQuestions += (sections.openQuestions.isEmpty ? "" : "\n") + line
            default: break
            }
        }
        return sections
    }

    @objc private func openTimeline() {
        overviewPage.isHidden = true
        status.isHidden = true
        timelinePage.isHidden = false
        overviewScrollTop?.isActive = false
        pinnedAudio.isHidden = false
        timelineScrollTop?.isActive = true
        window?.makeFirstResponder(backButton)
    }

    @objc private func closeTimeline() {
        timelinePage.isHidden = true
        timelineScrollTop?.isActive = false
        pinnedAudio.isHidden = true
        overviewScrollTop?.isActive = true
        status.isHidden = false
        overviewPage.isHidden = false
        window?.makeFirstResponder(transcriptionButton)
    }

    private func showUnavailableOverviewSections() {
        summaryOverviewSection?.rootView = MeetingOverviewSection(title: "AI summary", content: "", unavailable: "No meeting selected.",
            canEdit: false, expand: {}, edit: {}, copy: {})
        notesOverviewSection?.rootView = MeetingOverviewSection(title: "My notes", content: "", unavailable: "No meeting selected.",
            canEdit: false, expand: {}, edit: {}, copy: {})
    }

    private func updateOverviewSections(_ detail: MeetingBrowserDetail) {
        summaryOverviewSection?.rootView = MeetingOverviewSection(title: "AI summary", content: detail.summary?.summary ?? "",
            unavailable: "Summary unavailable or still being generated.", canEdit: detail.summaryVersion != nil,
            expand: { [weak self] in self?.expandSummary() },
            edit: { [weak self] in self?.summaryEditorRow?.isHidden = false },
            copy: { [weak self] in self?.copySummary() })
        notesOverviewSection?.rootView = MeetingOverviewSection(title: "My notes", content: detail.humanNotes,
            unavailable: "No notes yet.", canEdit: detail.doorwayVersion != nil,
            expand: { [weak self] in self?.expandNotes() },
            edit: { [weak self] in self?.notesEditorRow?.isHidden = false },
            copy: { [weak self] in self?.copyNotes() })
    }

    @objc private func copyOutcome(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let text = outcomeCopy[key] else { return }
        copyToPasteboard(text)
    }
    @objc private func copySummary() { copyToPasteboard(summary.string) }
    @objc private func copyNotes() { copyToPasteboard(notes.string) }
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
        for container in [myActionsContainer, outcomesContainer] {
            container.arrangedSubviews.forEach { container.removeArrangedSubview($0); $0.removeFromSuperview() }
        }
        actionRows = [:]
        evidenceTargets = [:]
        outcomeSourceTargets = [:]
        outcomeCopy = [:]
    }

    private func renderEvidence(_ detail: MeetingBrowserDetail) {
        clearEvidence()
        if detail.transcript.isEmpty {
            transcriptRows.addArrangedSubview(NSTextField(wrappingLabelWithString: "Transcript unavailable or invalid. Open the Transcript source if available."))
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
                label.widthAnchor.constraint(lessThanOrEqualTo: evidenceRows.widthAnchor).isActive = true
                evidenceRows.addArrangedSubview(row)
                for citation in outcome.citations {
                    evidenceRows.addArrangedSubview(NSTextField(wrappingLabelWithString: "Evidence: \(citation.segmentID) (≈\(timeLabel(citation.startSeconds))–\(timeLabel(citation.endSeconds)))"))
                    addEvidenceControl(to: evidenceRows, segmentID: citation.segmentID, seekSeconds: citation.seekSeconds, meetingID: detail.row.id)
                }
            }
        }
        renderTimeline(detail)
        renderOutcomes(detail)
        updateActiveSegment(at: audioPlayer?.elapsed)
    }

    private func renderOutcomes(_ detail: MeetingBrowserDetail) {
        for container in [myActionsContainer, outcomesContainer] {
            container.arrangedSubviews.forEach { container.removeArrangedSubview($0); $0.removeFromSuperview() }
        }
        func makeRow(_ id: String, _ text: String, _ detailText: String, _ citations: [MeetingCitation]) -> MeetingOutcomeRow {
            MeetingOutcomeRow(id: id, text: text, detail: detailText, citations: citations.map { citation in
                (label: timeLabel(citation.startSeconds), segmentID: citation.segmentID,
                 startSeconds: citation.startSeconds, endSeconds: citation.endSeconds,
                 seconds: citation.seekSeconds.flatMap { seconds in
                     audioPlayer.map { seconds <= $0.duration ? seconds : nil } ?? nil
                 })
            })
        }
        var groups: [MeetingOutcomeGroup] = []
        if !detail.myActionItems.isEmpty {
            groups.append(MeetingOutcomeGroup(id: "mine", title: "My actions", note: "Generated · review before adding to Todos",
                rows: detail.myActionItems.map { item in
                    let proposalID = "meeting-action:\(detail.row.id):\(item.id)"
                    let saved = try? serviceProvider()?.actionDraft(id: proposalID)
                    return makeRow(proposalID, saved?.title ?? item.text,
                                   item.reviewState.rawValue, item.citations)
                }))
        }
        if !detail.otherActionItems.isEmpty {
            groups.append(MeetingOutcomeGroup(id: "others", title: "Others’ actions", note: "Reference only",
                rows: detail.otherActionItems.map { makeRow($0.id, $0.text, "Reference only", $0.citations) }))
        }
        if !detail.decisions.isEmpty {
            groups.append(MeetingOutcomeGroup(id: "decisions", title: "Decisions", note: "\(detail.decisions.count) captured",
                rows: detail.decisions.enumerated().map { makeRow("decision-\($0.offset)", $0.element.text, "", $0.element.citations) }))
        }
        if !detail.openQuestions.isEmpty {
            groups.append(MeetingOutcomeGroup(id: "questions", title: "Open questions", note: "\(detail.openQuestions.count) captured",
                rows: detail.openQuestions.enumerated().map { makeRow("question-\($0.offset)", $0.element.text, "", $0.element.citations) }))
        }
        actionRows = Dictionary(uniqueKeysWithValues: groups.filter { $0.id == "mine" }.flatMap(\.rows).map { ($0.id, $0) })
        for group in groups {
            let boundedReviewWorkspace = group.id == "mine"
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
                let comment = group.id == "mine" ? (try? serviceProvider()?.actionDraft(id: row.id))?.comment ?? "" : ""
                let detailLine = (group.id == "mine" ? "Generated from meeting · " : "") + row.detail
                let text = NSTextField(wrappingLabelWithString: row.text + "\n" + detailLine +
                    (comment.isEmpty ? "" : "\nComment: " + comment))
                text.maximumNumberOfLines = 0
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                GraphiteFocusOverflow.configureWrappingText(text, fullText: text.stringValue)
                let controls = NSStackView()
                controls.orientation = .horizontal
                controls.alignment = .centerY
                controls.spacing = GraphiteFocusPresentation.Space.compact
                appendSourceControls(for: row, groupID: group.id, detail: detail, to: controls)
                if group.id == "mine" {
                    for (name, selector) in [("Edit", #selector(editAction(_:))), ("Review", #selector(reviewAction(_:)))] {
                        let button = NSButton(title: name, target: self, action: selector)
                        button.identifier = NSUserInterfaceItemIdentifier(row.id)
                        button.toolTip = "\(name) my action: \(row.text)"
                        button.setAccessibilityLabel(button.toolTip!)
                        button.setAccessibilityIdentifier("meeting-action-\(name.lowercased())-\(row.id)")
                        button.isEnabled = row.detail == "pending"
                        GraphiteFocusOverflow.protectTrailingControl(button)
                        controls.addArrangedSubview(button)
                    }
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
            let container = group.id == "mine" ? myActionsContainer : outcomesContainer
            container.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        }
    }

    private func appendSourceControls(for row: MeetingOutcomeRow, groupID: String, detail: MeetingBrowserDetail, to controls: NSStackView) {
        guard !row.citations.isEmpty else { return }
        let sourceButtons: [(key: String, button: NSButton)] = row.citations.enumerated().map { index, citation in
            let valid = detail.transcript.contains { segment in
                segment.id == citation.segmentID && abs(segment.startSeconds - citation.startSeconds) < 0.001 &&
                abs(segment.endSeconds - citation.endSeconds) < 0.001
            }
            let key = "\(row.id)-\(index)"
            if valid {
                outcomeSourceTargets[key] = OutcomeSourceTarget(meetingID: detail.row.id,
                    segmentID: citation.segmentID, startSeconds: citation.startSeconds,
                    endSeconds: citation.endSeconds, seekSeconds: citation.seconds,
                    kind: groupID == "mine" || groupID == "others" ? .action :
                          groupID == "decisions" ? .decision : .transcript)
            }
            let source = NSButton(title: valid ? "↗ source \(citation.label)" : "Source unavailable",
                                  target: self, action: #selector(seekOutcomeSource(_:)))
            source.identifier = NSUserInterfaceItemIdentifier(key)
            source.setAccessibilityIdentifier("meeting-outcome-source-\(key)")
            source.setAccessibilityLabel(valid ? "Show transcript source at \(citation.label)" : "Transcript source unavailable")
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
        let segmentID: String
        let startSeconds: Double
        let endSeconds: Double
        let seekSeconds: Double?
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
              detail.transcript.contains(where: { $0.id == target.segmentID &&
                  abs($0.startSeconds - target.startSeconds) < 0.001 &&
                  abs($0.endSeconds - target.endSeconds) < 0.001 }) else { return }
        openTimeline()
        timelineNavigation.show(seconds: target.startSeconds, segmentID: target.segmentID, kind: target.kind)
        if let seconds = target.seekSeconds, audioSource == detail.playback { audioPlayer?.seek(to: seconds) }
    }

    @objc private func editAction(_ sender: NSButton) { presentActionEditor(sender, reviewing: false) }
    @objc private func reviewAction(_ sender: NSButton) { presentActionEditor(sender, reviewing: true) }

    private func presentActionEditor(_ sender: NSButton, reviewing: Bool) {
        guard let id = sender.identifier?.rawValue, let row = actionRows[id], row.detail == "pending",
              let meetingID = selectedID, let service = serviceProvider() else { return }
        let draft = try? service.actionDraft(id: id)
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
        title.string = draft?.title ?? row.text
        comment.string = draft?.comment ?? ""
        titleScroll.hasVerticalScroller = true
        commentScroll.hasVerticalScroller = true
        titleScroll.heightAnchor.constraint(equalToConstant: 76).isActive = true
        commentScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let sources = row.citations.map(\.label).joined(separator: ", ")
        let context = NSTextField(wrappingLabelWithString: "Provenance: Generated from meeting · \(row.detail)\nSource: \(sources.isEmpty ? "No transcript citation available" : sources)")
        let fields = NSStackView(views: [context, NSTextField(labelWithString: "Action item text"), titleScroll,
                                         NSTextField(labelWithString: "Comment"), commentScroll])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = GraphiteFocusPresentation.Space.compact
        fields.frame = NSRect(x: 0, y: 0, width: 480, height: 235)
        titleScroll.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        commentScroll.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        let alert = NSAlert()
        alert.icon = NSImage(systemSymbolName: reviewing ? "checklist" : "square.and.pencil",
                             accessibilityDescription: reviewing ? "Review action" : "Edit action")
        alert.messageText = reviewing ? "Review my action" : "Edit my action"
        alert.informativeText = reviewing ? "Accept creates a Todo Item. Decline dismisses this proposal." : "Save updates only the proposal; it does not accept or create a Todo Item."
        alert.accessoryView = fields
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: reviewing ? "Accept" : "Save")
        if reviewing { alert.addButton(withTitle: "Decline") }
        let choice = presentConfirmationAlert(alert)
        guard choice != .alertFirstButtonReturn, selectedID == meetingID else { return }
        do {
            if choice == .alertSecondButtonReturn {
                let newTitle = title.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newTitle.isEmpty else { throw MeetingManagementError.retryRejected("Action text cannot be empty.") }
                try service.saveActionDraft(id: id, title: newTitle, comment: comment.string)
                if reviewing { try service.reviewAction(id: id, accept: true) }
            } else if reviewing && choice == .alertThirdButtonReturn {
                try service.reviewAction(id: id, accept: false)
            }
            displayedDetail = nil
            reload()
        } catch { status.stringValue = "Could not update action: \(error.localizedDescription)" }
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
                          moments.map(\.seconds).max() ?? 0), hasAudio: audioPlayer != nil,
            seek: { [weak self] moment in
                guard let self, self.selectedID == detail.row.id,
                      self.audioSource == detail.playback, let player = self.audioPlayer,
                      let seconds = moment.seekSeconds, seconds <= player.duration,
                      detail.transcript.contains(where: { $0.seekSeconds == seconds && $0.startSeconds <= moment.seconds && $0.endSeconds >= moment.seconds }) else { return }
                player.seek(to: seconds)
            }, navigation: timelineNavigation))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        timelineRows.addArrangedSubview(hosting)
        hosting.widthAnchor.constraint(equalTo: timelineRows.widthAnchor).isActive = true
    }

    private func addEvidenceControl(to group: NSStackView, segmentID: String, seekSeconds: Double?, meetingID: String) {
        guard let seekSeconds, let audioPlayer, seekSeconds <= audioPlayer.duration else {
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

    @objc private func seekEvidence(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue, let target = evidenceTargets[key],
              (transcriptRows.arrangedSubviews.contains(sender) || evidenceRows.arrangedSubviews.contains(sender)),
              let detail = displayedDetail, selectedID == target.meetingID, detail.row.id == target.meetingID,
              let player = audioPlayer, audioSource == detail.playback,
              detail.transcript.contains(where: { $0.id == target.segmentID && $0.seekSeconds == target.seconds }) else { return }
        openTimeline()
        player.seek(to: target.seconds)
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

    private func actionItemText(_ detail: MeetingBrowserDetail) -> String {
        let mine = detail.myActionItems.map { item in
            let citations = item.citations.map { "\($0.segmentID) (\($0.startSeconds)-\($0.endSeconds)s)" }.joined(separator: ", ")
            return "My: \(item.text) — \(item.reviewState.rawValue)\(citations.isEmpty ? "" : " [\(citations)]")"
        }
        let other = detail.otherActionItems.map { item in
            let citations = item.citations.map { "\($0.segmentID) (\($0.startSeconds)-\($0.endSeconds)s)" }.joined(separator: ", ")
            return "Other: \(item.text) — Reference only\(citations.isEmpty ? "" : " [\(citations)]")"
        }
        let stale = detail.staleProposals.map { "Previous Inbox proposal (not supported by current Summary): \($0.title)" }
        return (mine + other + stale).isEmpty ? "No extracted action items yet." : (mine + other + stale).joined(separator: "\n")
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

    @objc private func filtersChanged(_ sender: Any?) { reload() }

    @objc private func dateFilterChanged(_ sender: NSButton) {
        let picker = sender === startDateEnabled ? startDatePicker : endDatePicker
        picker.isEnabled = sender.state == .on
        reload()
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
        reload()
    }

    private func renderRetryActions(_ detail: MeetingBrowserDetail) {
        retryRows.arrangedSubviews.forEach { retryRows.removeArrangedSubview($0); $0.removeFromSuperview() }
        let failedJobs = detail.jobs.filter { $0.status == .failed }
        if failedJobs.isEmpty && detail.row.processingState == .needsAttention {
            let notice = NSTextField(wrappingLabelWithString: "! Needs attention · No failed Job to retry. Check the missing processing artifacts.")
            notice.font = GraphiteFocusPresentation.Typography.body
            notice.textColor = presentationColors.destructive
            notice.alignment = .left
            retryRows.addArrangedSubview(notice)
        }
        for job in failedJobs {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = GraphiteFocusPresentation.Space.compact
            let label = NSTextField(wrappingLabelWithString: "\(job.title) — failed at \(job.stage ?? "unknown stage")\(job.error.map { ": \($0)" } ?? "")")
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
        summaryEditorRow?.isHidden = false
        window?.makeFirstResponder(summary)
    }

    @objc private func editNotesFromToolbar() {
        guard editNotesTool.isEnabled else { return }
        notesEditorRow?.isHidden = false
        window?.makeFirstResponder(notes)
    }

    @objc private func showMeetingMenu(_ sender: NSButton) {
        let menu = NSMenu()
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
        guard let detail = displayedDetail, let service = serviceProvider() else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this Meeting?"
        alert.informativeText = "Move the Meeting folder to Trash. External recording files and already accepted Todos are not removed."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard presentConfirmationAlert(alert) == .alertFirstButtonReturn else { return }
        do {
            try service.remove(meetingID: detail.row.id)
            selectedID = nil
            reload()
            status.stringValue = "Meeting moved to Trash."
        } catch { status.stringValue = "Could not remove Meeting: \(error.localizedDescription)" }
    }

    @objc private func toggleArchive() {
        guard let detail = displayedDetail, let service = serviceProvider() else { return }
        archiveButton.isEnabled = false
        do {
            if detail.row.isArchived {
                try service.restore(meetingID: detail.row.id)
                archiveFilter.selectItem(at: 0)
                selectedID = detail.row.id
            } else {
                try service.archive(meetingID: detail.row.id)
            }
            retryFeedback = (detail.row.id, detail.row.isArchived ? "Meeting restored." : "Meeting archived.")
        } catch {
            retryFeedback = (detail.row.id, "Could not update Meeting archive: \(error.localizedDescription)")
        }
        reload()
    }

    @objc private func confirmRename() {
        guard let detail = displayedDetail, let version = selectedDoorwayVersion,
              let service = serviceProvider() else { return }
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
        do {
            let renamed = try service.rename(meetingID: detail.row.id, title: input.stringValue,
                expectedVersion: version)
            selectedID = renamed.row.id
            retryFeedback = (renamed.row.id, "Meeting renamed.")
        } catch {
            retryFeedback = (detail.row.id, "Could not rename Meeting: \(error.localizedDescription)")
        }
        reload()
    }

    @objc private func confirmReprocess() {
        guard let detail = displayedDetail, let service = serviceProvider() else { return }
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
        do {
            try service.reprocess(meetingID: detail.row.id, language: languages.indexOfSelectedItem == 1 ? .ukrainian : .english)
            retryFeedback = (detail.row.id, "Reprocessing queued for this Meeting.")
        } catch {
            retryFeedback = (detail.row.id, "Could not reprocess: \(error.localizedDescription)")
        }
        reload()
    }

    @objc private func retryFailedJob(_ sender: NSButton) {
        guard let detail = displayedDetail, let service = serviceProvider(), let jobID = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        do {
            try service.retryFailedJob(meetingID: detail.row.id, jobID: jobID)
            retryFeedback = (detail.row.id, "Retry queued for this Meeting.")
            reload()
        } catch {
            retryFeedback = (detail.row.id, "Could not retry processing: \(error.localizedDescription)")
            reload()
        }
    }

    @objc private func saveNotes() {
        guard let selectedID, let selectedDoorwayVersion, let service = serviceProvider() else { return }
        do {
            let saved = try service.saveHumanNotes(notes.string, for: selectedID, expectedVersion: selectedDoorwayVersion)
            loadedNotes = saved.humanNotes
            notes.string = saved.humanNotes
            self.selectedDoorwayVersion = saved.doorwayVersion
            notesEditorRow?.isHidden = true
            reload()
            status.stringValue = "Notes saved."
        } catch {
            status.stringValue = "Could not save notes: \(error.localizedDescription). Reload to review external changes."
        }
    }

    @objc private func saveSummary() {
        guard let selectedID, let selectedSummaryVersion, let service = serviceProvider() else { return }
        do {
            guard var sections = displayedDetail?.summary else { return }
            sections.summary = summary.string
            let saved = try service.saveSummary(sections, for: selectedID, expectedVersion: selectedSummaryVersion)
            let text = saved.summary?.summary ?? ""
            summary.string = text
            loadedSummary = text
            self.selectedSummaryVersion = saved.summaryVersion
            summaryEditorRow?.isHidden = true
            reload()
            status.stringValue = "Summary saved."
        } catch {
            status.stringValue = "Could not save Summary: \(error.localizedDescription). Reload to review external changes."
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
private final class MeetingHeaderButton: NSButton {
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

private final class RetryFixtureExecutor: JobExecuting {
    private var attempts = 0
    private var pending: ((Result<JobStageResult, Error>) -> Void)?
    func execute(job: JobRecord, stage: JobStageDefinition, completion: @escaping (Result<JobStageResult, Error>) -> Void) {
        attempts += 1
        if attempts == 1 { completion(.failure(NSError(domain: "fixture", code: 1))) }
        else { pending = completion }
    }
}

extension MeetingManagementView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        MeetingSelectionRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        let statusName = meeting.job?.status == .failed ? "xmark.octagon.fill" :
            meeting.requiresAttention ? "exclamationmark.circle.fill" :
            meeting.processingState == .ready ? "checkmark.circle.fill" : "clock.arrow.circlepath"
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

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isReloading else { return }
        if rows.indices.contains(table.selectedRow), rows[table.selectedRow].id != selectedID {
            retryFeedback = nil
        }
        show(row: table.selectedRow)
        onOpenSelection()
    }
}
