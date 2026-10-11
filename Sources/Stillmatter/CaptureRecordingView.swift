import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Focused operational workspace for Meeting capture. Capture state and the next safe action stay
/// prominent; supporting diagnostics and artifact details are disclosed only when requested.
final class CaptureRecordingView: NSView {
    override var isFlipped: Bool { true }

    private struct Presentation {
        let state: CaptureState?
        let stateTitle: String
        let stateDetail: String
        let elapsedSeconds: Int
        let meetingPath: String?
        let preflight: AudioCapturePreflightReport?
        let artifactRows: [(title: String, detail: String, meaning: GraphiteFocusStatusMeaning)]
        let failureMessage: String?
        let isConfigured: Bool
        let canRegenerateTranscript: Bool
    }

    private let serviceProvider: () -> MeetingCaptureService?
    private let rootURLProvider: () -> URL?
    private let teamsDetectionProvider: () -> TeamsDetectionSnapshot?
    private let teamsRecordingDiagnosticProvider: () -> String
    private let onManualCapture: () -> Void
    private let jobRecordsProvider: () -> [JobRecord]
    private let onOpenSettings: () -> Void

    private let contentStack = NSStackView()
    private let statePanel = NSView()
    private let stateSymbolLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let stateDetailLabel = NSTextField(wrappingLabelWithString: "")
    private let elapsedLabel = NSTextField(labelWithString: "00:00:00")
    private let meetingPathLabel = NSTextField(wrappingLabelWithString: "")
    private let meetingActions = NSStackView()
    private let startButton = NSButton(title: "Start Capture", target: nil, action: nil)
    private let stopButton = NSButton(title: "Stop Capture", target: nil, action: nil)
    private let openFolderButton = NSButton(title: "Open Meeting Folder", target: nil, action: nil)
    private let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let regenerateButton = NSButton(title: "Regenerate Transcript", target: nil, action: nil)
    private let noteField = NSTextField()
    private let addNoteButton = NSButton(title: "Add Note", target: nil, action: nil)
    private let addActionButton = NSButton(title: "Add Action Checkbox", target: nil, action: nil)
    private let preflightRows = NSStackView()
    private let artifactsRows = NSStackView()
    private let teamsRows = NSStackView()
    private let artifactsDisclosure = NSButton(title: "Show Processing & Artifacts", target: nil, action: nil)
    private let teamsDisclosure = NSButton(title: "Show Teams Detection Signals", target: nil, action: nil)
    private let artifactsContainer = NSStackView()
    private let teamsContainer = NSStackView()
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var liveNotesSection: NSView?
    private var timer: Timer?
    private var renderedPreflightCount = 0
    private var renderedArtifactTitles: [String] = []
    private var operationFailure: String?

    init(
        serviceProvider: @escaping () -> MeetingCaptureService?,
        rootURLProvider: @escaping () -> URL?,
        teamsDetectionProvider: @escaping () -> TeamsDetectionSnapshot?,
        teamsRecordingDiagnosticProvider: @escaping () -> String = { "Capture policy unavailable" },
        onManualCapture: @escaping () -> Void = {},
        jobRecordsProvider: @escaping () -> [JobRecord],
        onOpenSettings: @escaping () -> Void
    ) {
        self.serviceProvider = serviceProvider
        self.rootURLProvider = rootURLProvider
        self.teamsDetectionProvider = teamsDetectionProvider
        self.teamsRecordingDiagnosticProvider = teamsRecordingDiagnosticProvider
        self.onManualCapture = onManualCapture
        self.jobRecordsProvider = jobRecordsProvider
        self.onOpenSettings = onOpenSettings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh(isVisible: !(self?.isHidden ?? true))
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    func refresh(isVisible: Bool) {
        isHidden = !isVisible
        guard isVisible else { return }
        guard let service = serviceProvider() else {
            render(Presentation(
                state: nil,
                stateTitle: "Capture unavailable",
                stateDetail: "Choose an Stillmatter root in Settings before starting a Capture Session.",
                elapsedSeconds: 0,
                meetingPath: nil,
                preflight: nil,
                artifactRows: [],
                failureMessage: nil,
                isConfigured: false,
                canRegenerateTranscript: false
            ))
            renderTeamsDetection()
            return
        }

        render(presentation(for: service.snapshot))
        languagePopup.selectItem(withTag: service.transcriptionLanguage == .english ? 0 : 1)
        renderTeamsDetection()
    }

    private func presentation(for snapshot: CaptureSnapshot) -> Presentation {
        var artifacts: [(String, String, GraphiteFocusStatusMeaning)] = []
        if let mic = snapshot.micRecording {
            artifacts.append((
                "Microphone Track — \(trackDisplayName(mic.status.rawValue))",
                "\(mic.codec), \(Int(mic.sampleRate)) Hz, \(String(format: "%.1f", mic.durationSeconds))s\n\(mic.recoveryFilePath)",
                trackMeaning(mic.status.rawValue)
            ))
        }
        if let system = snapshot.systemAudioRecording {
            let diagnostic = (system.status == .failed || system.status == .partial)
                ? system.diagnostics.last.map { "\n\($0)" } ?? ""
                : ""
            artifacts.append((
                "System Audio Track — \(trackDisplayName(system.status.rawValue))",
                "\(system.codec), \(Int(system.sampleRate)) Hz, \(String(format: "%.1f", system.durationSeconds))s\n\(system.recoveryFilePath)\(diagnostic)",
                trackMeaning(system.status.rawValue)
            ))
        } else if snapshot.state == .recording {
            artifacts.append((
                "System Audio Track — Unavailable",
                "This Capture Session is continuing with microphone audio only.",
                .attention
            ))
        }
        if let bundle = snapshot.recordingBundle {
            artifacts.append((
                "Recording Bundle — \(bundle.state.rawValue.capitalized)",
                bundle.bundleFilePath,
                bundle.state == .ready ? .success : .attention
            ))
        }
        let persistedJobs = captureJobs(for: snapshot)
        for status in snapshot.processingStatus {
            let normalized = status.lowercased()
            if !persistedJobs.isEmpty && normalized.contains("transcription and summary pending") {
                continue
            }
            let meaning: GraphiteFocusStatusMeaning = normalized.contains("fail") || normalized.contains("unavailable")
                ? .destructive
                : (normalized.contains("pending") || normalized.contains("queued") ? .attention : .informational)
            if normalized.contains("transcript") {
                artifacts.append(("Transcript", status, meaning))
            }
            if normalized.contains("summary") {
                artifacts.append(("Summary", status, meaning))
            }
            if !normalized.contains("transcript") && !normalized.contains("summary") {
                artifacts.append(("Processing", status, meaning))
            }
        }
        if persistedJobs.isEmpty {
            if snapshot.state == .stopping || snapshot.state == .finalizing {
                artifacts.append(("Job", "Capture artifacts are being finalized before processing is queued.", .attention))
            }
        } else {
            artifacts.append(contentsOf: processingRows(for: persistedJobs))
        }

        return Presentation(
            state: snapshot.state,
            stateTitle: displayName(snapshot.state, snapshot: snapshot),
            stateDetail: stateDetail(snapshot.state, hasMeeting: snapshot.meetingRelativePath != nil),
            elapsedSeconds: snapshot.elapsedSeconds,
            meetingPath: snapshot.meetingRelativePath,
            preflight: snapshot.preflightReport,
            artifactRows: artifacts,
            failureMessage: snapshot.failureMessage,
            isConfigured: true,
            canRegenerateTranscript: snapshot.recordingBundle != nil
        )
    }

    private func captureJobs(for snapshot: CaptureSnapshot) -> [JobRecord] {
        guard let captureSessionID = snapshot.recordingBundle?.captureSessionID else { return [] }
        let records = jobRecordsProvider()
        let transcriptionJobs = records.filter {
            $0.manifest.type == TranscriptionJob.type &&
                $0.manifest.metadata["capture_session_id"] == captureSessionID
        }
        let summaryIDs = Set(transcriptionJobs.map { "meeting-summary:\($0.id)" })
        let summaryJobs = records.filter {
            $0.manifest.type == MeetingSummaryJob.type && summaryIDs.contains($0.id)
        }
        return transcriptionJobs + summaryJobs
    }

    private func processingRows(for jobs: [JobRecord]) -> [(String, String, GraphiteFocusStatusMeaning)] {
        let transcription = jobs.first { $0.manifest.type == TranscriptionJob.type }
        let summary = jobs.first { $0.manifest.type == MeetingSummaryJob.type }
        var rows: [(String, String, GraphiteFocusStatusMeaning)] = []
        if let transcription = transcription {
            rows.append(jobRow(title: "Transcript", job: transcription))
        }
        if let summary = summary {
            rows.append(jobRow(title: "Summary", job: summary))
        } else if let transcription = transcription {
            let detail = transcription.status == .failed
                ? "Unavailable because Transcript processing failed."
                : "Waiting for Transcript processing to complete."
            rows.append(("Summary — Waiting", detail, transcription.status == .failed ? .destructive : .attention))
        }

        let failed = jobs.filter { $0.status == .failed }.count
        let running = jobs.filter { $0.status == .running }.count
        let queued = jobs.filter { $0.status == .queued }.count
        let detail: String
        let meaning: GraphiteFocusStatusMeaning
        if failed > 0 {
            detail = "\(failed) processing Job\(failed == 1 ? "" : "s") require attention."
            meaning = .destructive
        } else if running > 0 {
            detail = "\(running) processing Job\(running == 1 ? " is" : "s are") running."
            meaning = .attention
        } else if queued > 0 {
            detail = "\(queued) processing Job\(queued == 1 ? " is" : "s are") queued."
            meaning = .attention
        } else {
            detail = "Transcript and Summary processing completed."
            meaning = .success
        }
        rows.append(("Job — \(failed > 0 ? "Failed" : (running > 0 ? "Running" : (queued > 0 ? "Queued" : "Complete")))", detail, meaning))
        return rows
    }

    private func jobRow(title: String, job: JobRecord) -> (String, String, GraphiteFocusStatusMeaning) {
        switch job.status {
        case .queued:
            return ("\(title) — Queued", "Waiting for local processing to begin.", .attention)
        case .running:
            let stage = job.stages.first { $0.status == .running }?.definition.title ?? "Processing"
            return ("\(title) — Running", stage, .attention)
        case .succeeded:
            return ("\(title) — Complete", "Completed successfully at \(job.updatedAt).", .success)
        case .failed:
            return ("\(title) — Failed", job.failureDetails ?? "Processing failed. Open the Jobs Inbox for details and retry actions.", .destructive)
        case .dismissed:
            return ("\(title) — Dismissed", "The processing failure was dismissed.", .informational)
        }
    }

    private func buildLayout() {
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = GraphiteFocusPresentation.Space.page
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentStack)

        configureStatePanel()
        addFullWidth(statePanel, to: contentStack)
        addFullWidth(makeCaptureControls(), to: contentStack)
        addFullWidth(makePreflightSection(), to: contentStack)
        let liveNotes = makeLiveNotesSection()
        liveNotesSection = liveNotes
        addFullWidth(liveNotes, to: contentStack)
        addFullWidth(makeDisclosureSection(
            button: artifactsDisclosure,
            container: artifactsContainer,
            action: #selector(toggleArtifacts(_:))
        ), to: contentStack)
        addFullWidth(makeDisclosureSection(
            button: teamsDisclosure,
            container: teamsContainer,
            action: #selector(toggleTeams(_:))
        ), to: contentStack)
        addFullWidth(errorLabel, to: contentStack)

        addFullWidth(artifactsRows, to: artifactsContainer)
        addFullWidth(teamsRows, to: teamsContainer)
        [artifactsContainer, teamsContainer].forEach {
            $0.orientation = .vertical
            $0.alignment = .leading
            $0.spacing = GraphiteFocusPresentation.Space.dense
            $0.isHidden = true
        }
        artifactsRows.orientation = .vertical
        artifactsRows.alignment = .leading
        artifactsRows.spacing = GraphiteFocusPresentation.Space.flush
        teamsRows.orientation = .vertical
        teamsRows.alignment = .leading
        teamsRows.spacing = GraphiteFocusPresentation.Space.flush

        errorLabel.font = GraphiteFocusPresentation.Typography.body
        errorLabel.textColor = colors.destructive
        errorLabel.maximumNumberOfLines = 0
        errorLabel.setAccessibilityIdentifier("capture-error")

        let preferredWidth = contentStack.widthAnchor.constraint(equalToConstant: 980)
        preferredWidth.priority = .defaultHigh
        let fillAvailableWidth = contentStack.trailingAnchor.constraint(equalTo: trailingAnchor)
        fillAvailableWidth.priority = NSLayoutConstraint.Priority(749)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            preferredWidth,
            fillAvailableWidth
        ])
    }

    private func configureStatePanel() {
        statePanel.wantsLayer = true
        statePanel.setAccessibilityIdentifier("capture-state-panel")
        statePanel.heightAnchor.constraint(equalToConstant: 104).isActive = true

        stateSymbolLabel.font = .systemFont(ofSize: 28, weight: .semibold) // graphite-focus-native-exception: large capture state glyph, not text
        stateSymbolLabel.alignment = .center
        stateSymbolLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        statusLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        statusLabel.setAccessibilityIdentifier("capture-state")
        stateDetailLabel.font = GraphiteFocusPresentation.Typography.body
        stateDetailLabel.maximumNumberOfLines = 0
        let labels = NSStackView(views: [statusLabel, stateDetailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = GraphiteFocusPresentation.Space.primitive
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        startButton.target = self
        startButton.action = #selector(startCapture(_:))
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.setAccessibilityHelp("Runs Capture Preflight and starts a new Capture Session when every blocking check passes.")

        stopButton.target = self
        stopButton.action = #selector(stopCapture(_:))
        stopButton.bezelStyle = .rounded
        stopButton.setAccessibilityHelp("Stops the active Capture Session and begins finalizing its artifacts.")

        elapsedLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .semibold)
        elapsedLabel.alignment = .right
        elapsedLabel.setAccessibilityLabel("Capture elapsed time")
        elapsedLabel.setAccessibilityIdentifier("capture-elapsed")

        let stateRow = NSStackView(views: [stateSymbolLabel, labels, elapsedLabel, startButton, stopButton])
        stateRow.orientation = .horizontal
        stateRow.alignment = .centerY
        stateRow.spacing = GraphiteFocusPresentation.Space.dense
        stateRow.translatesAutoresizingMaskIntoConstraints = false
        statePanel.addSubview(stateRow)
        NSLayoutConstraint.activate([
            stateRow.leadingAnchor.constraint(equalTo: statePanel.leadingAnchor, constant: GraphiteFocusPresentation.Space.panel),
            stateRow.trailingAnchor.constraint(equalTo: statePanel.trailingAnchor, constant: -GraphiteFocusPresentation.Space.panel),
            stateRow.topAnchor.constraint(equalTo: statePanel.topAnchor, constant: GraphiteFocusPresentation.Space.panel),
            stateRow.bottomAnchor.constraint(equalTo: statePanel.bottomAnchor, constant: -GraphiteFocusPresentation.Space.panel)
        ])
    }

    private func makeCaptureControls() -> NSView {
        openFolderButton.target = self
        openFolderButton.action = #selector(openMeetingFolder(_:))

        languagePopup.addItem(withTitle: "English")
        languagePopup.lastItem?.tag = 0
        languagePopup.addItem(withTitle: "Ukrainian")
        languagePopup.lastItem?.tag = 1
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged(_:))
        languagePopup.setAccessibilityLabel("Transcription language")

        regenerateButton.target = self
        regenerateButton.action = #selector(regenerateTranscript(_:))

        meetingPathLabel.font = GraphiteFocusPresentation.Typography.metadata
        meetingPathLabel.lineBreakMode = .byTruncatingMiddle
        meetingPathLabel.maximumNumberOfLines = 2

        meetingActions.orientation = .horizontal
        meetingActions.alignment = .centerY
        meetingActions.spacing = GraphiteFocusPresentation.Space.compact
        meetingActions.addArrangedSubview(openFolderButton)

        let languageLabel = NSTextField(labelWithString: "Transcription language")
        languageLabel.font = GraphiteFocusPresentation.Typography.control
        let transcription = NSStackView(views: [languageLabel, languagePopup, regenerateButton])
        transcription.orientation = .horizontal
        transcription.alignment = .centerY
        transcription.spacing = GraphiteFocusPresentation.Space.compact
        transcription.distribution = .fillProportionally

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.dense
        stack.addArrangedSubview(transcription)
        addFullWidth(meetingPathLabel, to: stack)
        stack.addArrangedSubview(meetingActions)
        stack.setAccessibilityIdentifier("capture-primary-controls")
        return stack
    }

    private func makePreflightSection() -> NSView {
        preflightRows.orientation = .vertical
        preflightRows.alignment = .width
        preflightRows.spacing = GraphiteFocusPresentation.Space.flush
        preflightRows.setAccessibilityIdentifier("capture-preflight")
        return makeSection(
            title: "Capture Preflight",
            caption: "Each prerequisite is checked before a Meeting is created. Blocking findings prevent capture; degraded findings allow a reduced mode.",
            content: preflightRows
        )
    }

    private func makeLiveNotesSection() -> NSView {
        noteField.placeholderString = "Type a live note or Action Item…"
        noteField.target = self
        noteField.action = #selector(addNote(_:))
        noteField.setAccessibilityLabel("Live note or Action Item text")
        addNoteButton.target = self
        addNoteButton.action = #selector(addNote(_:))
        addActionButton.target = self
        addActionButton.action = #selector(addAction(_:))
        let actions = NSStackView(views: [addNoteButton, addActionButton])
        actions.orientation = .horizontal
        actions.spacing = GraphiteFocusPresentation.Space.compact
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = GraphiteFocusPresentation.Space.compact
        addFullWidth(noteField, to: content)
        content.addArrangedSubview(actions)
        return makeSection(
            title: "Live Notes",
            caption: "Available while recording. Action checkboxes remain proposals in the Meeting doorway; they do not create Todo Items.",
            content: content
        )
    }

    private func makeDisclosureSection(button: NSButton, container: NSStackView, action: Selector) -> NSView {
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.alignment = .left
        button.font = GraphiteFocusPresentation.Typography.sectionHeading
        button.contentTintColor = colors.textPrimary
        button.target = self
        button.action = action
        button.state = .off
        button.title = "▸  \(button.title.replacingOccurrences(of: "Show ", with: ""))"
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.compact
        stack.addArrangedSubview(button)
        addFullWidth(container, to: stack)
        return stack
    }

    private func makeSection(title: String, caption: String, content: NSView) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        heading.textColor = colors.textPrimary
        let help = NSTextField(wrappingLabelWithString: caption)
        help.font = GraphiteFocusPresentation.Typography.metadata
        help.textColor = colors.textMetadata
        help.maximumNumberOfLines = 0
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = GraphiteFocusPresentation.Space.compact
        addFullWidth(heading, to: stack)
        addFullWidth(help, to: stack)
        addFullWidth(content, to: stack)
        return stack
    }

    private func render(_ presentation: Presentation) {
        let state = presentation.state
        let meaning = stateMeaning(state)
        let palette = colors
        statePanel.layer?.borderWidth = GraphiteFocusPresentation.Stroke.width
        statePanel.layer?.borderColor = palette.structuralStroke.cgColor
        statePanel.layer?.backgroundColor = palette.surfacePanel.cgColor
        statePanel.layer?.cornerRadius = GraphiteFocusPresentation.Radius.panel
        stateSymbolLabel.stringValue = stateSymbol(state)
        stateSymbolLabel.textColor = meaning.color(in: palette)
        statusLabel.stringValue = presentation.stateTitle
        statusLabel.textColor = palette.textPrimary
        statusLabel.setAccessibilityLabel("Capture Session: \(presentation.stateTitle)")
        stateDetailLabel.stringValue = presentation.stateDetail
        stateDetailLabel.textColor = palette.textSecondary
        elapsedLabel.stringValue = Self.duration(presentation.elapsedSeconds)
        elapsedLabel.textColor = state == .recording ? palette.attention : palette.textPrimary
        elapsedLabel.setAccessibilityValue(Self.accessibleDuration(presentation.elapsedSeconds))
        meetingPathLabel.stringValue = presentation.meetingPath.map { "Meeting doorway: \($0)" } ?? "No active Meeting folder"
        meetingPathLabel.textColor = palette.textMetadata

        let canStart = presentation.isConfigured && (state == .idle || state == .detecting || state == .failed || state == .recovered)
        let isRecording = state == .recording
        startButton.isHidden = !canStart
        startButton.isEnabled = canStart
        elapsedLabel.isHidden = canStart || presentation.elapsedSeconds == 0
        startButton.bezelColor = palette.accent
        startButton.contentTintColor = palette.accentOn
        stopButton.isHidden = !isRecording
        stopButton.isEnabled = isRecording
        stopButton.bezelColor = palette.destructive
        stopButton.contentTintColor = nil
        meetingPathLabel.isHidden = presentation.meetingPath == nil
        meetingActions.isHidden = presentation.meetingPath == nil
        openFolderButton.isEnabled = presentation.meetingPath != nil
        languagePopup.isEnabled = presentation.isConfigured && !isRecording
        regenerateButton.isEnabled = presentation.canRegenerateTranscript && !isRecording
        noteField.isEnabled = isRecording
        addNoteButton.isEnabled = isRecording
        addActionButton.isEnabled = isRecording
        liveNotesSection?.isHidden = !isRecording
        startButton.title = presentation.meetingPath == nil ? "Start Capture" : "Start New Capture"

        renderPreflight(presentation.preflight, isConfigured: presentation.isConfigured)
        renderArtifacts(presentation.artifactRows)
        let failure = operationFailure ?? presentation.failureMessage
        errorLabel.stringValue = failure.map { "!  Failure details: \($0)" } ?? ""
        errorLabel.isHidden = failure == nil
    }

    private func renderPreflight(_ report: AudioCapturePreflightReport?, isConfigured: Bool) {
        removeAllRows(from: preflightRows)
        guard isConfigured else {
            renderedPreflightCount = 1
            addFullWidth(makePreflightPlaceholder(
                symbol: "!",
                title: "Workspace configuration",
                detail: "Choose an Stillmatter root before Capture Preflight can run.",
                showSettings: true
            ), to: preflightRows)
            return
        }
        guard let report = report else {
            renderedPreflightCount = 1
            addFullWidth(makePreflightPlaceholder(
                symbol: "○",
                title: "Preflight",
                detail: "Start Capture runs microphone, system audio, media output, and free-space checks.",
                showSettings: false,
                statusText: "Not run"
            ), to: preflightRows)
            return
        }
        renderedPreflightCount = report.items.count
        for (index, item) in report.items.enumerated() {
            if index > 0 { addFullWidth(makeDivider(), to: preflightRows) }
            addFullWidth(makePreflightRow(item), to: preflightRows)
        }
    }

    private func makePreflightPlaceholder(
        symbol: String,
        title: String,
        detail: String,
        showSettings: Bool,
        statusText: String? = nil
    ) -> NSView {
        let item = AudioCapturePreflightItem(
            id: "placeholder",
            title: title,
            status: showSettings ? .blocked : .ready,
            detail: detail,
            settingsAction: showSettings ? .chooseMediaFolder : nil
        )
        return makePreflightRow(item, symbolOverride: symbol, statusTextOverride: statusText)
    }

    private func makePreflightRow(
        _ item: AudioCapturePreflightItem,
        symbolOverride: String? = nil,
        statusTextOverride: String? = nil
    ) -> NSView {
        let meaning: GraphiteFocusStatusMeaning
        let statusText: String
        let symbol: String
        switch item.status {
        case .ready:
            meaning = .success
            statusText = "Ready"
            symbol = "✓"
        case .degraded:
            meaning = .attention
            statusText = "Degraded"
            symbol = "△"
        case .blocked:
            meaning = .destructive
            statusText = "Blocking"
            symbol = "✕"
        }
        let marker = NSTextField(labelWithString: symbolOverride ?? symbol)
        marker.font = GraphiteFocusPresentation.Typography.control
        marker.textColor = meaning.color(in: colors)
        marker.alignment = .center
        marker.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let visibleStatus = statusTextOverride ?? statusText
        let title = NSTextField(labelWithString: "\(item.title) — \(visibleStatus)")
        title.font = GraphiteFocusPresentation.Typography.rowTitle
        title.textColor = colors.textPrimary
        let detail = NSTextField(wrappingLabelWithString: item.detail)
        detail.font = GraphiteFocusPresentation.Typography.metadata
        detail.textColor = colors.textMetadata
        detail.maximumNumberOfLines = 0
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = GraphiteFocusPresentation.Space.primitive
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [marker, text]
        if item.settingsAction != nil {
            let settings = ClosureButton(title: settingsActionTitle(item.settingsAction), action: { [weak self] in
                self?.onOpenSettings()
            })
            settings.setAccessibilityLabel("\(settings.title) for \(item.title)")
            views.append(settings)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = GraphiteFocusPresentation.Space.compact
        row.edgeInsets = NSEdgeInsets(
            top: GraphiteFocusPresentation.Space.compact,
            left: 0,
            bottom: GraphiteFocusPresentation.Space.compact,
            right: 0
        )
        row.setAccessibilityLabel("\(item.title), \(visibleStatus). \(item.detail)")
        return row
    }

    private func renderArtifacts(_ rows: [(title: String, detail: String, meaning: GraphiteFocusStatusMeaning)]) {
        removeAllRows(from: artifactsRows)
        renderedArtifactTitles = rows.map(\.title)
        if rows.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "○  Microphone Track, System Audio Track, Recording Bundle, Transcript, Summary, and Job status will appear here as they become available.")
            empty.font = GraphiteFocusPresentation.Typography.body
            empty.textColor = colors.textMetadata
            empty.maximumNumberOfLines = 0
            addFullWidth(empty, to: artifactsRows)
            return
        }
        for (index, row) in rows.enumerated() {
            if index > 0 { addFullWidth(makeDivider(), to: artifactsRows) }
            addFullWidth(makeDiagnosticRow(
                symbol: row.meaning.symbol,
                title: row.title,
                detail: row.detail,
                meaning: row.meaning
            ), to: artifactsRows)
        }
    }

    private func renderTeamsDetection() {
        removeAllRows(from: teamsRows)
        let palette = colors
        guard let snapshot = teamsDetectionProvider() else {
            addFullWidth(makeDiagnosticRow(
                symbol: "?",
                title: "Observation unavailable",
                detail: "Teams signals are unavailable; manual capture remains available.",
                meaning: .informational
            ), to: teamsRows)
            return
        }
        addFullWidth(makeDiagnosticRow(
            symbol: snapshot.isMeetingDetected ? "◉" : "○",
            title: snapshot.isMeetingDetected ? "Native Teams call detected" : "No native Teams call detected",
            detail: "\(snapshot.diagnosticSummary) Capture policy: \(teamsRecordingDiagnosticProvider())",
            meaning: snapshot.isMeetingDetected ? .attention : .informational
        ), to: teamsRows)
        for signal in snapshot.signals {
            addFullWidth(makeDivider(), to: teamsRows)
            let unavailable = signal.availability == .unavailable
            addFullWidth(makeDiagnosticRow(
                symbol: unavailable ? "?" : (signal.isActive ? "+" : "–"),
                title: signal.kind.displayName,
                detail: "\(signal.detail) Confidence contribution \(signal.contribution)/\(signal.kind.maximumContribution).",
                meaning: signal.isActive ? .success : .informational
            ), to: teamsRows)
        }
        teamsDisclosure.contentTintColor = snapshot.isMeetingDetected ? palette.attention : palette.textSecondary
    }

    private func makeDiagnosticRow(
        symbol: String,
        title: String,
        detail: String,
        meaning: GraphiteFocusStatusMeaning
    ) -> NSView {
        let marker = NSTextField(labelWithString: symbol)
        marker.font = GraphiteFocusPresentation.Typography.control
        marker.textColor = meaning.color(in: colors)
        marker.alignment = .center
        marker.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = GraphiteFocusPresentation.Typography.rowTitle
        titleLabel.textColor = colors.textPrimary
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = GraphiteFocusPresentation.Typography.metadata
        detailLabel.textColor = colors.textMetadata
        detailLabel.maximumNumberOfLines = 2
        detailLabel.lineBreakMode = .byTruncatingMiddle
        let labels = NSStackView(views: [titleLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = GraphiteFocusPresentation.Space.primitive
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [marker, labels])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = GraphiteFocusPresentation.Space.compact
        row.edgeInsets = NSEdgeInsets(
            top: GraphiteFocusPresentation.Space.compact,
            left: 0,
            bottom: GraphiteFocusPresentation.Space.compact,
            right: 0
        )
        row.setAccessibilityLabel("\(title). \(detail)")
        return row
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = colors.structuralStroke.cgColor
        divider.heightAnchor.constraint(equalToConstant: GraphiteFocusPresentation.Stroke.width).isActive = true
        return divider
    }

    private func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func removeAllRows(from stack: NSStackView) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    @objc private func toggleArtifacts(_ sender: NSButton) {
        artifactsContainer.isHidden = sender.state != .on
        sender.title = sender.state == .on ? "▾  Processing & Artifacts" : "▸  Processing & Artifacts"
    }

    @objc private func toggleTeams(_ sender: NSButton) {
        teamsContainer.isHidden = sender.state != .on
        sender.title = sender.state == .on ? "▾  Teams Detection Signals" : "▸  Teams Detection Signals"
    }

    @objc private func startCapture(_ sender: NSButton) {
        perform { service in
            onManualCapture()
            _ = try service.startManual()
        }
    }

    @objc private func stopCapture(_ sender: NSButton) {
        guard let service = serviceProvider() else { return }
        onManualCapture()
        service.stopManualAsync { [weak self] result in
            guard let self else { return }
            if case let .failure(error) = result {
                self.operationFailure = "Could not stop capture: \(error)"
            } else {
                self.operationFailure = nil
            }
            self.refresh(isVisible: !self.isHidden)
        }
        refresh(isVisible: !isHidden)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let language: TranscriptLanguage = sender.selectedTag() == 1 ? .ukrainian : .english
        serviceProvider()?.setTranscriptionLanguage(language)
    }

    @objc private func regenerateTranscript(_ sender: NSButton) {
        let language: TranscriptLanguage = languagePopup.selectedTag() == 1 ? .ukrainian : .english
        perform { service in _ = try service.regenerateTranscript(language: language) }
    }

    @objc private func addNote(_ sender: Any?) {
        let text = noteField.stringValue
        perform { service in try service.appendLiveNote(text) }
        if errorLabel.stringValue.isEmpty { noteField.stringValue = "" }
    }

    @objc private func addAction(_ sender: NSButton) {
        let text = noteField.stringValue
        perform { service in try service.appendActionItem(text) }
        if errorLabel.stringValue.isEmpty { noteField.stringValue = "" }
    }

    @objc private func openMeetingFolder(_ sender: NSButton) {
        guard let service = serviceProvider(),
              let relativePath = service.snapshot.meetingRelativePath,
              let root = rootURLProvider() else { return }
        NSWorkspace.shared.open(root.appendingPathComponent(relativePath).deletingLastPathComponent())
    }

    private func perform(_ operation: (MeetingCaptureService) throws -> Void) {
        guard let service = serviceProvider() else { return }
        do {
            try operation(service)
            operationFailure = nil
        } catch {
            operationFailure = "Could not update capture: \(error)"
        }
        refresh(isVisible: true)
    }

    private func displayName(_ state: CaptureState, snapshot: CaptureSnapshot) -> String {
        switch state {
        case .idle:
            return snapshot.meetingRelativePath == nil ? "Ready to capture" : "Capture complete"
        case .detecting: return "Detecting a Meeting signal"
        case .starting: return "Starting Capture Session"
        case .recording:
            return snapshot.systemAudioRecording?.status == .recording
                ? "Recording microphone + system audio"
                : "Recording microphone only"
        case .stopping: return "Stopping Capture Session"
        case .finalizing: return "Finalizing capture artifacts"
        case .failed: return "Capture failed"
        case .recovered: return "Capture recovered"
        }
    }

    private func stateDetail(_ state: CaptureState, hasMeeting: Bool = false) -> String {
        switch state {
        case .idle:
            return hasMeeting
                ? "The last Capture Session was finalized. Its Meeting and processing artifacts remain available below."
                : "Run Capture Preflight, then create a Meeting and begin recording."
        case .detecting: return "Teams detection is active. Manual Start Capture remains available."
        case .starting: return "Checking prerequisites and preparing durable recording artifacts."
        case .recording: return "Capture is live. Add notes or Action Item checkboxes, then stop deliberately when the Meeting ends."
        case .stopping: return "Stopping recording input and finalizing audio in the background. This may take time for long meetings."
        case .finalizing: return "The Recording Bundle is being validated before Transcript and Summary Jobs begin."
        case .failed: return "Review the blocking finding or failure details before trying again."
        case .recovered: return "Durable audio was recovered after an interrupted Capture Session. Review artifacts before starting again."
        }
    }

    private func stateSymbol(_ state: CaptureState?) -> String {
        switch state {
        case .idle: return "✓"
        case .detecting: return "◎"
        case .starting: return "↑"
        case .recording: return "●"
        case .stopping: return "■"
        case .finalizing: return "…"
        case .failed: return "!"
        case .recovered: return "↻"
        case nil: return "!"
        }
    }

    private func stateMeaning(_ state: CaptureState?) -> GraphiteFocusStatusMeaning {
        switch state {
        case .idle, .recovered: return .success
        case .detecting, .starting, .recording, .stopping: return .attention
        case .failed, nil: return .destructive
        case .finalizing: return .informational
        }
    }

    private func trackMeaning(_ rawStatus: String) -> GraphiteFocusStatusMeaning {
        switch rawStatus {
        case "completed", "recovered": return .success
        case "failed": return .destructive
        case "recording", "finalizing", "partial": return .attention
        default: return .informational
        }
    }

    private func trackDisplayName(_ rawStatus: String) -> String {
        rawStatus.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private func settingsActionTitle(_ action: AudioCaptureSettingsAction?) -> String {
        switch action {
        case .openMicrophonePrivacy: return "Open Microphone Settings"
        case .openScreenRecordingPrivacy: return "Open Screen Recording Settings"
        case .chooseMediaFolder: return "Choose Media Folder"
        case .freeDiskSpace: return "Open Settings"
        case nil: return "Open Settings"
        }
    }

    private var colors: GraphiteFocusPresentation.Colors {
        GraphiteFocusPresentation.Colors(environment: GraphiteFocusEnvironment.system(window: window))
    }

    private static func duration(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
    }

    private static func accessibleDuration(_ seconds: Int) -> String {
        "\(seconds / 3600) hours, \((seconds / 60) % 60) minutes, \(seconds % 60) seconds"
    }

    /// Verifies the actual shell embedding rather than only the view's isolated fitting size.
    func validateVisibleLayout() {
        layoutSubtreeIfNeeded()
        guard let parent = superview else { preconditionFailure("Capture workspace must be embedded in the shell") }
        precondition(parent.bounds.maxX - frame.maxX <= 33, "Capture workspace must fill the shell detail width")
        precondition((90...120).contains(statePanel.frame.height), "Capture state panel must keep a compact stable height")
        precondition(statusLabel.frame.width > 0 && statusLabel.frame.height > 0, "Capture state text must have a visible frame")
    }

    /// Exercises all contract states and constrained-width behavior in the whole-window harness.
    func validateFixtures() {
        let previousOperationFailure = operationFailure
        let ready = AudioCapturePreflightItem.ready(
            id: "microphone",
            title: "Microphone permission",
            detail: "Microphone access is granted."
        )
        let degraded = AudioCapturePreflightItem(
            id: "system-audio",
            title: "System audio",
            status: .degraded,
            detail: "Capture may continue with microphone audio only.",
            settingsAction: .openScreenRecordingPrivacy
        )
        let blocked = AudioCapturePreflightItem(
            id: "media-output",
            title: "Media output",
            status: .blocked,
            detail: "Choose a writable recording media location.",
            settingsAction: .chooseMediaFolder
        )

        let states: [(CaptureState, String)] = [
            (.idle, "Ready to capture"),
            (.detecting, "Detecting a Meeting signal"),
            (.starting, "Starting Capture Session"),
            (.recording, "Recording microphone + system audio"),
            (.stopping, "Stopping Capture Session"),
            (.finalizing, "Finalizing capture artifacts"),
            (.failed, "Capture failed"),
            (.recovered, "Capture recovered")
        ]
        precondition(startButton.isDescendant(of: statePanel) && stopButton.isDescendant(of: statePanel),
                     "Capture start and stop must share the status panel")
        for (state, title) in states {
            render(Presentation(
                state: state,
                stateTitle: title,
                stateDetail: stateDetail(state),
                elapsedSeconds: state == .recording ? 3_661 : 0,
                meetingPath: state == .idle || state == .detecting ? nil : "Meetings/2026/09/fixture/meeting.md",
                preflight: AudioCapturePreflightReport(items: [ready]),
                artifactRows: state == .recording
                    ? [
                        ("Microphone Track — Recording", "linear PCM recovery, 48000 Hz", .attention),
                        ("System Audio Track — Recording", "linear PCM recovery, 48000 Hz", .attention)
                    ]
                    : [],
                failureMessage: state == .failed ? "Fixture recorder failure" : nil,
                isConfigured: true,
                canRegenerateTranscript: state == .recovered
            ))
            precondition(statusLabel.stringValue == title, "Capture fixture did not render \(state.rawValue)")
            precondition(!stateSymbolLabel.stringValue.isEmpty, "Capture state requires a non-color cue")
            precondition(startButton.isHidden == ![.idle, .detecting, .failed, .recovered].contains(state),
                         "Start must appear only when a new capture can begin")
            precondition(stopButton.isHidden == (state != .recording),
                         "Stop must replace Start in the status panel while recording")
        }

        render(Presentation(
            state: nil,
            stateTitle: "Capture unavailable",
            stateDetail: "Choose an Stillmatter root in Settings.",
            elapsedSeconds: 0,
            meetingPath: nil,
            preflight: nil,
            artifactRows: [],
            failureMessage: nil,
            isConfigured: false,
            canRegenerateTranscript: false
        ))
        precondition(renderedPreflightCount == 1 && !startButton.isEnabled, "Unconfigured capture must offer a Settings route")

        render(Presentation(
            state: .failed,
            stateTitle: "Capture failed",
            stateDetail: stateDetail(.failed),
            elapsedSeconds: 0,
            meetingPath: nil,
            preflight: AudioCapturePreflightReport(items: [ready, blocked]),
            artifactRows: [],
            failureMessage: "Preflight blocked capture.",
            isConfigured: true,
            canRegenerateTranscript: false
        ))
        precondition(renderedPreflightCount == 2 && !errorLabel.isHidden, "Blocked Preflight must expose findings and failure details")

        render(Presentation(
            state: .recording,
            stateTitle: "Recording microphone only",
            stateDetail: stateDetail(.recording),
            elapsedSeconds: 125,
            meetingPath: "Meetings/2026/09/fixture/meeting.md",
            preflight: AudioCapturePreflightReport(items: [ready, degraded]),
            artifactRows: [
                ("Microphone Track — Recording", "linear PCM recovery, 48000 Hz", .attention),
                ("System Audio Track — Unavailable", "Microphone-only Capture Session.", .attention)
            ],
            failureMessage: nil,
            isConfigured: true,
            canRegenerateTranscript: false
        ))
        precondition(renderedPreflightCount == 2 && stopButton.isEnabled && noteField.isEnabled, "Degraded recording must preserve capture and live notes")
        operationFailure = "Could not update capture: fixture write failure"
        refresh(isVisible: true)
        precondition(!errorLabel.isHidden && errorLabel.stringValue.contains("fixture write failure"), "Operation failures must survive a timed refresh")
        operationFailure = previousOperationFailure

        render(Presentation(
            state: .finalizing,
            stateTitle: "Finalizing capture artifacts",
            stateDetail: stateDetail(.finalizing),
            elapsedSeconds: 125,
            meetingPath: "Meetings/2026/09/fixture/meeting.md",
            preflight: AudioCapturePreflightReport(items: [ready]),
            artifactRows: [
                ("Microphone Track — Completed", "mic.m4a", .success),
                ("System Audio Track — Completed", "system.m4a", .success),
                ("Recording Bundle — Ready", "recording-bundle.json", .success),
                ("Transcript", "Job queued", .informational),
                ("Summary", "Waiting for Transcript", .informational),
                ("Job", "Processing", .attention)
            ],
            failureMessage: nil,
            isConfigured: true,
            canRegenerateTranscript: true
        ))
        precondition(Set(renderedArtifactTitles).isSuperset(of: [
            "Microphone Track — Completed", "System Audio Track — Completed", "Recording Bundle — Ready",
            "Transcript", "Summary", "Job"
        ]), "Processing fixture must expose every artifact role")

        artifactsDisclosure.state = .on
        toggleArtifacts(artifactsDisclosure)
        teamsDisclosure.state = .on
        toggleTeams(teamsDisclosure)
        frame = NSRect(x: 0, y: 0, width: 420, height: fittingSize.height)
        layoutSubtreeIfNeeded()
        precondition(contentStack.frame.width <= bounds.width + 1, "Capture workspace must not force a narrow detail canvas wider")
        precondition(elapsedLabel.stringValue == "00:02:05", "Elapsed time must use stable HH:MM:SS formatting")
        precondition(!artifactsContainer.isHidden && !teamsContainer.isHidden, "Supporting evidence must remain reachable")

        artifactsDisclosure.state = .off
        toggleArtifacts(artifactsDisclosure)
        teamsDisclosure.state = .off
        toggleTeams(teamsDisclosure)
        refresh(isVisible: true)
    }
}

private final class ClosureButton: NSButton {
    private let invoke: () -> Void

    init(title: String, action: @escaping () -> Void) {
        invoke = action
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        target = self
        self.action = #selector(activate)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func activate() {
        invoke()
    }
}
