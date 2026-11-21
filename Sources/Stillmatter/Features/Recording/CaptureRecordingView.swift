import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Focused operational workspace for Meeting capture. Capture state and the next safe action stay
/// prominent; supporting diagnostics and artifact details are disclosed only when requested.
final class CaptureRecordingView: NSView, NSTextViewDelegate {
    override var isFlipped: Bool { true }

    struct Presentation {
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
    private let onTranscriptionLanguageChanged: (TranscriptLanguage) -> Void
    private let jobRecordsProvider: () -> [JobRecord]
    private let onOpenSettings: () -> Void
    private let confirmDestructiveAction: @MainActor (String, String, String) -> Bool

    private let importServiceProvider: () -> MeetingImportService?
    private let onImported: () -> Void
    lazy var importControls = MeetingImportControls(controls: controls, serviceProvider: importServiceProvider, onImported: onImported)

    private let controls: GraphiteFocusControls

    let contentStack = NSStackView()
    let statePanel = NSView()
    let stateSymbolLabel = NSTextField(labelWithString: "")
    let statusLabel = NSTextField(labelWithString: "")
    private let stateDetailLabel = NSTextField(wrappingLabelWithString: "")
    let elapsedLabel = NSTextField(labelWithString: "00:00:00")
    private let meetingPathLabel = NSTextField(wrappingLabelWithString: "")
    private let meetingActions = NSStackView()
    let startButton: NSButton
    let stopButton: NSButton
    private let openFolderButton: NSButton
    private let languagePopup: NSPopUpButton
    private let sourcePopup: NSPopUpButton
    private let scopeLabel = NSTextField(wrappingLabelWithString: "")
    private let regenerateButton: NSButton
    let noteTextView = NSTextView()
    private let notesStatus = NSTextField(wrappingLabelWithString: "")
    private let saveNotesButton: NSButton
    private let reloadNotesButton: NSButton
    private let useDraftButton: NSButton
    let stopAnywayButton: NSButton
    private var notesDocument: LiveMeetingNotes?
    private var notesMeetingPath: String?
    private var notesVersion: WorkspaceFileVersion?
    private var notesSavedText = ""
    private var notesHaveConflict = false
    private var notesRecoveryActive = false
    private var notesSaveWork: DispatchWorkItem?
    private let preflightRows = NSStackView()
    private let artifactsRows = NSStackView()
    private let teamsRows = NSStackView()
    let artifactsDisclosure: NSButton
    let teamsDisclosure: NSButton
    let artifactsContainer = NSStackView()
    let teamsContainer = NSStackView()
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var liveNotesSection: NSView?
    private var timer: Timer?
    private(set) var renderedPreflightCount = 0
    private(set) var renderedArtifactTitles: [String] = []
    var operationFailure: String?

    init(
        controls: GraphiteFocusControls = GraphiteFocusControls(),
        serviceProvider: @escaping () -> MeetingCaptureService?,
        rootURLProvider: @escaping () -> URL?,
        teamsDetectionProvider: @escaping () -> TeamsDetectionSnapshot?,
        teamsRecordingDiagnosticProvider: @escaping () -> String = { "Capture policy unavailable" },
        onManualCapture: @escaping () -> Void = {},
        onTranscriptionLanguageChanged: @escaping (TranscriptLanguage) -> Void = { _ in },
        jobRecordsProvider: @escaping () -> [JobRecord],
        onOpenSettings: @escaping () -> Void,
        importServiceProvider: @escaping () -> MeetingImportService? = { nil },
        onImported: @escaping () -> Void = {},
        confirmDestructiveAction: @escaping @MainActor (String, String, String) -> Bool = { title, detail, action in
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = detail
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Cancel").setAccessibilityIdentifier("recording-confirm-cancel")
            alert.addButton(withTitle: action).setAccessibilityIdentifier("recording-confirm-destructive")
            return alert.runModal() == .alertSecondButtonReturn
        }
    ) {
        self.importServiceProvider = importServiceProvider
        self.onImported = onImported
        self.controls = controls
        startButton = controls.button("Start Capture", identifier: "recording-start")
        stopButton = controls.button("Stop Capture", identifier: "recording-stop")
        openFolderButton = controls.button("Open Meeting Folder", identifier: "recording-open-folder")
        regenerateButton = controls.button("Regenerate Transcript", identifier: "recording-regenerate")
        saveNotesButton = controls.button("Save Notes", identifier: "recording-save-notes")
        reloadNotesButton = controls.button("Reload Latest", identifier: "recording-reload-notes")
        useDraftButton = controls.button("Use My Draft", identifier: "recording-use-notes-draft")
        stopAnywayButton = controls.button("Stop Capture Anyway", identifier: "recording-stop-anyway")
        artifactsDisclosure = controls.disclosure("Show Processing & Artifacts", identifier: "recording-artifacts")
        teamsDisclosure = controls.disclosure("Show Teams Detection Signals", identifier: "recording-teams")
        languagePopup = controls.popup(identifier: "recording-language")
        sourcePopup = controls.popup(identifier: "recording-source")
        self.serviceProvider = serviceProvider
        self.rootURLProvider = rootURLProvider
        self.teamsDetectionProvider = teamsDetectionProvider
        self.teamsRecordingDiagnosticProvider = teamsRecordingDiagnosticProvider
        self.onManualCapture = onManualCapture
        self.onTranscriptionLanguageChanged = onTranscriptionLanguageChanged
        self.jobRecordsProvider = jobRecordsProvider
        self.onOpenSettings = onOpenSettings
        self.confirmDestructiveAction = confirmDestructiveAction
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
        notesSaveWork?.cancel()
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

        let snapshot = service.snapshot
        refreshLiveNotes(service: service, snapshot: snapshot)
        render(presentation(for: snapshot))
        if snapshot.state == .recording, let source = snapshot.source {
            sourcePopup.selectItem(withTag: source == .teams ? 0 : (source == .zoom ? 1 : 2))
        }
        updateScopeLabel(
            active: snapshot.state == .recording,
            warning: snapshot.systemAudioRecording?.status == .failed || snapshot.systemAudioRecording?.status == .partial
                ? snapshot.systemAudioRecording?.diagnostics.last
                : nil
        )
        languagePopup.selectItem(withTag: languageTag(service.transcriptionLanguage))
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
        for prior in snapshot.priorCaptureFinalizations {
            switch prior.state {
            case .finalizing:
                artifacts.append(("Prior Meeting — Finalizing audio", prior.meetingTitle, .attention))
            case let .failed(message):
                artifacts.append(("Prior Meeting — Finalization failed", message, .destructive))
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
            stateDetail: stateDetail(
                snapshot.state,
                hasMeeting: snapshot.meetingRelativePath != nil,
                isPreviousSessionFinalizing: snapshot.priorCaptureFinalizations.contains { if case .finalizing = $0.state { true } else { false } },
                isPreviousSessionFinalizationFailed: snapshot.priorCaptureFinalizations.contains { if case .failed = $0.state { true } else { false } }
            ),
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
        if let workflow = records.last(where: { $0.manifest.type == MeetingWorkflowJob.type && $0.manifest.metadata["capture_session_id"] == captureSessionID }) { return [workflow] }
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
        if let workflow = jobs.first(where: { $0.manifest.type == MeetingWorkflowJob.type }) { return [jobRow(title: "Meeting", job: workflow)] }
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
        addFullWidth(importControls, to: contentStack)
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
        stateDetailLabel.setAccessibilityIdentifier("capture-state-detail")
        stateDetailLabel.maximumNumberOfLines = 0
        let labels = NSStackView(views: [statusLabel, stateDetailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = GraphiteFocusPresentation.Space.primitive
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        startButton.target = self
        startButton.action = #selector(startCapture(_:))
        startButton.keyEquivalent = "\r"
        startButton.setAccessibilityHelp("Runs Capture Preflight and starts a new Capture Session when every blocking check passes.")

        stopButton.target = self
        stopButton.action = #selector(stopCapture(_:))
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
        for (title, tag, symbol) in [("Microsoft Teams", 0, "person.2.fill"),
                                     ("Zoom", 1, "video.fill"),
                                     ("Google Meet", 2, "video")] {
            sourcePopup.addItem(withTitle: title)
            sourcePopup.lastItem?.tag = tag
            sourcePopup.lastItem?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        }
        sourcePopup.selectItem(withTag: 0)
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged(_:))
        sourcePopup.setAccessibilityLabel("Meeting source")
        scopeLabel.font = GraphiteFocusPresentation.Typography.metadata
        scopeLabel.maximumNumberOfLines = 0
        scopeLabel.setAccessibilityIdentifier("recording-audio-scope")
        updateScopeLabel(active: false)
        openFolderButton.target = self
        openFolderButton.action = #selector(openMeetingFolder(_:))

        languagePopup.addItem(withTitle: "Auto (mixed-language quality unverified)")
        languagePopup.lastItem?.tag = 0
        languagePopup.addItem(withTitle: "English")
        languagePopup.lastItem?.tag = 1
        languagePopup.addItem(withTitle: "Ukrainian")
        languagePopup.lastItem?.tag = 2
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
        let sourceLabel = NSTextField(labelWithString: "Meeting source")
        sourceLabel.font = GraphiteFocusPresentation.Typography.control
        let sourceRow = NSStackView(views: [sourceLabel, sourcePopup])
        sourceRow.orientation = .horizontal
        sourceRow.alignment = .centerY
        sourceRow.spacing = GraphiteFocusPresentation.Space.compact
        stack.addArrangedSubview(sourceRow)
        addFullWidth(scopeLabel, to: stack)
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
        noteTextView.isRichText = false
        noteTextView.isAutomaticQuoteSubstitutionEnabled = false
        noteTextView.frame = NSRect(x: 0, y: 0, width: 800, height: 180)
        noteTextView.minSize = NSSize(width: 0, height: 180)
        noteTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        noteTextView.isVerticallyResizable = true
        noteTextView.isHorizontallyResizable = false
        noteTextView.autoresizingMask = [.width]
        noteTextView.textContainer?.widthTracksTextView = true
        noteTextView.font = GraphiteFocusPresentation.Typography.body
        noteTextView.delegate = self
        noteTextView.setAccessibilityIdentifier("recording-my-notes-editor")
        noteTextView.setAccessibilityLabel("My Notes Markdown")
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = noteTextView
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        saveNotesButton.target = self
        saveNotesButton.action = #selector(saveNotesNow(_:))
        saveNotesButton.keyEquivalent = "s"
        saveNotesButton.keyEquivalentModifierMask = [.command]
        reloadNotesButton.target = self
        reloadNotesButton.action = #selector(reloadLiveNotes(_:))
        reloadNotesButton.keyEquivalent = "\u{1b}"
        useDraftButton.target = self
        useDraftButton.action = #selector(useLiveNotesDraft(_:))
        useDraftButton.isEnabled = false
        stopAnywayButton.target = self
        stopAnywayButton.action = #selector(stopCaptureAnyway(_:))
        stopAnywayButton.isEnabled = false
        stopAnywayButton.isHidden = true
        notesStatus.font = GraphiteFocusPresentation.Typography.body
        notesStatus.maximumNumberOfLines = 0
        notesStatus.setAccessibilityIdentifier("recording-my-notes-status")
        let actions = NSStackView(views: [saveNotesButton, useDraftButton])
        actions.orientation = .horizontal
        actions.spacing = GraphiteFocusPresentation.Space.compact
        let destructiveActions = NSStackView(views: [reloadNotesButton, stopAnywayButton])
        destructiveActions.orientation = .horizontal
        destructiveActions.spacing = GraphiteFocusPresentation.Space.compact
        reloadNotesButton.bezelColor = colors.destructive
        stopAnywayButton.bezelColor = colors.destructive
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = GraphiteFocusPresentation.Space.compact
        addFullWidth(scroll, to: content)
        content.addArrangedSubview(actions)
        addFullWidth(notesStatus, to: content)
        content.addArrangedSubview(destructiveActions)
        return makeSection(
            title: "My Notes",
            caption: "Markdown saves automatically in this Meeting's my-notes.md. Use - [ ] for an Action Item.",
            content: content
        )
    }

    private func makeDisclosureSection(button: NSButton, container: NSStackView, action: Selector) -> NSView {
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

    func render(_ presentation: Presentation) {
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

        let canStart = presentation.isConfigured && (serviceProvider()?.canStartCapture ?? false) &&
            (state == .idle || state == .detecting || state == .failed || state == .recovered)
        let isRecording = state == .recording
        startButton.isHidden = !canStart
        startButton.isEnabled = canStart
        elapsedLabel.isHidden = canStart || presentation.elapsedSeconds == 0
        controls.applyCaptureColors(start: startButton, stop: stopButton, colors: palette)
        stopButton.isHidden = !isRecording
        stopButton.isEnabled = isRecording
        meetingPathLabel.isHidden = presentation.meetingPath == nil
        meetingActions.isHidden = presentation.meetingPath == nil
        openFolderButton.isEnabled = presentation.meetingPath != nil
        languagePopup.isEnabled = presentation.isConfigured && !isRecording
        sourcePopup.isEnabled = presentation.isConfigured && !isRecording
        regenerateButton.isEnabled = presentation.canRegenerateTranscript && !isRecording
        noteTextView.isEditable = isRecording
        saveNotesButton.isEnabled = isRecording || notesRecoveryActive
        reloadNotesButton.isEnabled = isRecording || notesRecoveryActive
        useDraftButton.isEnabled = (isRecording || notesRecoveryActive) && notesHaveConflict
        stopAnywayButton.isHidden = !isRecording || !stopAnywayButton.isEnabled
        liveNotesSection?.isHidden = !isRecording && !notesRecoveryActive
        startButton.title = presentation.meetingPath == nil ? "Start Capture" : "Start New Capture"

        renderPreflight(presentation.preflight, isConfigured: presentation.isConfigured)
        renderArtifacts(presentation.artifactRows)
        let recoveryWarning = serviceProvider()?.snapshot.notesRecoveryWarning
        let failures = [operationFailure, presentation.failureMessage, recoveryWarning].compactMap { $0 }
        errorLabel.stringValue = failures.map { "!  \($0)" }.joined(separator: "\n")
        errorLabel.isHidden = failures.isEmpty
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
            let settings = controls.actionButton(settingsActionTitle(item.settingsAction), identifier: "recording-preflight-\(item.id)", action: { [weak self] in
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
                meaning: row.meaning,
                accessibilityIdentifier: row.title == "Prior Meeting — Finalization failed"
                    ? "recording-prior-finalization-failure"
                    : nil
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
        meaning: GraphiteFocusStatusMeaning,
        accessibilityIdentifier: String? = nil
    ) -> NSView {
        let marker = NSTextField(labelWithString: symbol)
        marker.font = GraphiteFocusPresentation.Typography.control
        marker.textColor = meaning.color(in: colors)
        marker.alignment = .center
        marker.widthAnchor.constraint(equalToConstant: 22).isActive = true
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = GraphiteFocusPresentation.Typography.rowTitle
        titleLabel.textColor = colors.textPrimary
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.setAccessibilityLabel(title)
        if let accessibilityIdentifier = accessibilityIdentifier {
            titleLabel.setAccessibilityIdentifier(accessibilityIdentifier)
        }
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

    @objc func toggleArtifacts(_ sender: NSButton) {
        artifactsContainer.isHidden = sender.state != .on
        sender.title = sender.state == .on ? "▾  Processing & Artifacts" : "▸  Processing & Artifacts"
    }

    @objc func toggleTeams(_ sender: NSButton) {
        teamsContainer.isHidden = sender.state != .on
        sender.title = sender.state == .on ? "▾  Teams Detection Signals" : "▸  Teams Detection Signals"
    }

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        updateScopeLabel(active: false)
    }

    private func updateScopeLabel(active: Bool, warning: String? = nil) {
        let teams = sourcePopup.selectedTag() == 0
        let scope = teams
            ? "\(active ? "Recording" : "Will record") Microsoft Teams application audio only; microphone remains separate."
            : "\(active ? "Recording" : "Will record") ALL SYSTEM AUDIO (not Zoom-only or Meet-tab-only); microphone remains separate."
        if let warning {
            scopeLabel.stringValue = "⚠ System audio degraded; microphone capture continues. \(scope) \(warning)"
            scopeLabel.textColor = colors.attention
        } else {
            scopeLabel.stringValue = scope
            scopeLabel.textColor = teams ? colors.textSecondary : colors.attention
        }
    }

    @objc private func startCapture(_ sender: NSButton) {
        perform { service in
            onManualCapture()
            let source: CaptureAudioSource = sourcePopup.selectedTag() == 1 ? .zoom
                : (sourcePopup.selectedTag() == 2 ? .meet : .teams)
            _ = try service.startManual(source: source)
        }
    }

    @objc private func stopCapture(_ sender: NSButton) {
        guard let service = serviceProvider() else { return }
        if notesDocument == nil && !noteTextView.string.isEmpty {
            setNotesStatus("Could not save My Notes. Retry Save or copy your text before choosing Stop Capture Anyway.", .destructive)
            stopAnywayButton.isEnabled = true
            stopAnywayButton.isHidden = false
            return
        }
        if notesDocument != nil && noteTextView.string != notesSavedText && !saveNotes() {
            setNotesStatus(String(notesStatus.stringValue.dropFirst(2)) + " Retry Save or copy your text before choosing Stop Capture Anyway.", .destructive)
            stopAnywayButton.isEnabled = true
            stopAnywayButton.isHidden = false
            return
        }
        stopCaptureSession(service)
    }

    @objc private func stopCaptureAnyway(_ sender: NSButton) {
        guard let service = serviceProvider(), service.snapshot.state == .recording else { return }
        guard confirmDestructiveAction("Stop Capture with unsaved notes?",
            "The current My Notes text may not be recoverable. Copy it before continuing if draft recovery failed.",
            "Stop Capture Anyway") else { return }
        stopCaptureSession(service)
    }

    private func stopCaptureSession(_ service: MeetingCaptureService) {
        stopAnywayButton.isEnabled = false
        stopAnywayButton.isHidden = true
        onManualCapture()
        let stoppedMeetingRelativePath = service.snapshot.meetingRelativePath
        service.stopManualAsync { [weak self] result in
            guard let self else { return }
            guard service.snapshot.meetingRelativePath == stoppedMeetingRelativePath else { return }
            if case let .failure(error) = result {
                self.operationFailure = service.snapshot.state == .failed
                    ? "Could not stop capture: \(error)"
                    : nil
            } else {
                self.operationFailure = nil
            }
            self.refresh(isVisible: !self.isHidden)
        }
        refresh(isVisible: !isHidden)
    }

    @objc private func languageChanged(_ sender: NSPopUpButton) {
        let selectedLanguage = language(for: sender.selectedTag())
        serviceProvider()?.setTranscriptionLanguage(selectedLanguage)
        onTranscriptionLanguageChanged(selectedLanguage)
    }

    @objc private func regenerateTranscript(_ sender: NSButton) {
        let language = selectedTranscriptionLanguage
        perform { service in _ = try service.regenerateTranscript(language: language) }
    }

    private var selectedTranscriptionLanguage: TranscriptLanguage {
        language(for: languagePopup.selectedTag())
    }

    private func language(for tag: Int) -> TranscriptLanguage {
        switch tag {
        case 0: return .automatic
        case 2: return .ukrainian
        default: return .english
        }
    }

    private func languageTag(_ language: TranscriptLanguage) -> Int {
        switch language {
        case .automatic: return 0
        case .english: return 1
        case .ukrainian: return 2
        }
    }

    private func refreshLiveNotes(service: MeetingCaptureService, snapshot: CaptureSnapshot) {
        guard snapshot.state == .recording else {
            guard let pending = service.pendingLiveNotesDocuments().first else {
                if snapshot.notesRecoveryWarning != nil { service.refreshNotesRecoveryWarning() }
                notesRecoveryActive = false
                notesMeetingPath = nil
                notesDocument = nil
                return
            }
            do {
                let state = try pending.load()
                notesRecoveryActive = state.hasDraft
                notesMeetingPath = pending.meetingRelativePath
                notesDocument = pending
                notesVersion = state.version
                notesSavedText = state.savedText
                noteTextView.string = state.text
                notesHaveConflict = state.conflictsWithFile
                if state.conflictsWithFile { showNotesConflict() }
                else { setNotesStatus("Recovered draft from \(pending.meetingRelativePath). Save to finish recovery.", .attention) }
            } catch {
                setNotesStatus("Could not load a preserved My Notes draft: \(error.localizedDescription)", .destructive)
            }
            return
        }
        notesRecoveryActive = false
        guard snapshot.state == .recording, let path = snapshot.meetingRelativePath,
              let document = service.liveNotesDocument() else { return }
        if notesMeetingPath != path {
            notesSaveWork?.cancel()
            notesMeetingPath = nil
            notesDocument = nil
            noteTextView.string = ""
            do {
                let state = try document.load()
                notesMeetingPath = path
                notesDocument = document
                notesVersion = state.version
                notesSavedText = state.savedText
                noteTextView.string = state.text
                notesHaveConflict = state.conflictsWithFile
                if state.conflictsWithFile { showNotesConflict() }
                else { setNotesStatus(state.hasDraft ? "Recovered unsaved draft. Save to retry." : "Saved", state.hasDraft ? .attention : .success) }
            } catch {
                setNotesStatus("Could not load My Notes: \(error.localizedDescription)", .destructive)
            }
            return
        }
        do {
            let state = try document.load()
            if state.conflictsWithFile {
                showNotesConflict()
            } else if !state.hasDraft && noteTextView.string == notesSavedText && state.savedText != notesSavedText {
                noteTextView.string = state.savedText
                notesSavedText = state.savedText
                notesVersion = state.version
                notesHaveConflict = false
                useDraftButton.isEnabled = false
                setNotesStatus("Updated from my-notes.md", .success)
            }
        } catch {
            setNotesStatus("Could not read My Notes: \(error.localizedDescription)", .destructive)
        }
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as? NSTextView === noteTextView, let document = notesDocument else { return }
        notesSaveWork?.cancel()
        do {
            try document.stage(noteTextView.string, baseVersion: notesVersion)
            setNotesStatus("Saving…", .attention)
            let work = DispatchWorkItem { [weak self] in self?.saveNotesNow(nil) }
            notesSaveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        } catch {
            setNotesStatus("Draft recovery failed: \(error.localizedDescription). Keep this window open.", .destructive)
        }
    }

    @objc private func saveNotesNow(_ sender: Any?) {
        _ = saveNotes()
    }

    @discardableResult
    private func saveNotes() -> Bool {
        notesSaveWork?.cancel()
        guard let document = notesDocument else { return false }
        do {
            let text = noteTextView.string
            let version = try document.save(text, expectedVersion: notesVersion)
            notesVersion = version
            notesSavedText = text
            notesHaveConflict = false
            useDraftButton.isEnabled = false
            stopAnywayButton.isEnabled = false
            stopAnywayButton.isHidden = true
            setNotesStatus("Saved", .success)
            if notesRecoveryActive {
                serviceProvider()?.refreshNotesRecoveryWarning()
                refresh(isVisible: !isHidden)
            }
            return true
        } catch let error as LiveMeetingNotesError {
            setNotesStatus("Could not save My Notes: \(error.localizedDescription). Keep this window open; draft recovery is unavailable.", .destructive)
        } catch let error as WorkspaceVaultError {
            if case .conflict = error {
                showNotesConflict()
            } else {
                setNotesStatus("Could not save My Notes: \(error.localizedDescription). Draft retained.", .destructive)
            }
        } catch {
            setNotesStatus("Could not save My Notes: \(error.localizedDescription). Draft retained.", .destructive)
        }
        return false
    }

    @objc private func reloadLiveNotes(_ sender: NSButton) {
        guard let document = notesDocument else { return }
        if noteTextView.string != notesSavedText || notesHaveConflict {
            guard confirmDestructiveAction("Discard the current My Notes draft?",
                "Reload Latest replaces the text in this editor with the Meeting file.", "Discard Draft") else { return }
        }
        notesSaveWork?.cancel()
        do {
            let state = try document.reloadLatest()
            noteTextView.string = state.text
            notesSavedText = state.savedText
            notesVersion = state.version
            notesHaveConflict = false
            useDraftButton.isEnabled = false
            setNotesStatus("Reloaded latest My Notes", .success)
            if notesRecoveryActive {
                serviceProvider()?.refreshNotesRecoveryWarning()
                refresh(isVisible: !isHidden)
            }
        } catch {
            setNotesStatus("Could not reload My Notes: \(error.localizedDescription). Draft retained.", .destructive)
        }
    }

    @objc private func useLiveNotesDraft(_ sender: NSButton) {
        guard let document = notesDocument else { return }
        notesSaveWork?.cancel()
        do {
            let result = try document.useDraftPreservingExternal(noteTextView.string, expectedBaseVersion: notesVersion)
            notesVersion = result.version
            notesSavedText = noteTextView.string
            notesHaveConflict = false
            useDraftButton.isEnabled = false
            setNotesStatus("Saved your draft. Previous external notes are preserved at \(result.preservedCopy.path).", .success)
            if notesRecoveryActive {
                serviceProvider()?.refreshNotesRecoveryWarning()
                refresh(isVisible: !isHidden)
            }
        } catch let error as LiveMeetingNotesError {
            setNotesStatus("Could not save the current draft: \(error.localizedDescription). Keep this window open.", .destructive)
        } catch {
            setNotesStatus("Could not resolve My Notes conflict: \(error.localizedDescription). Your current text remains in this editor.", .destructive)
        }
    }

    private func showNotesConflict() {
        notesHaveConflict = true
        useDraftButton.isEnabled = true
        setNotesStatus("Conflict: external changes and your draft are preserved. Use My Draft saves your text and keeps a copy of the external file; Reload Latest discards the draft.", .attention)
    }

    private func setNotesStatus(_ message: String, _ meaning: GraphiteFocusStatusMeaning) {
        notesStatus.stringValue = "\(meaning.symbol) \(message)"
        notesStatus.textColor = meaning.color(in: colors)
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
            if !snapshot.priorCaptureFinalizations.isEmpty {
                return "Ready for the next capture"
            }
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

    func stateDetail(
        _ state: CaptureState,
        hasMeeting: Bool = false,
        isPreviousSessionFinalizing: Bool = false,
        isPreviousSessionFinalizationFailed: Bool = false
    ) -> String {
        switch state {
        case .idle:
            if isPreviousSessionFinalizing {
                return "The prior audio source has stopped. Its audio is still being finalized while you can start the next Capture Session."
            }
            if isPreviousSessionFinalizationFailed {
                return "The prior Meeting's audio finalization failed; its retained evidence and failure stay with that Meeting. You can start the next Capture Session."
            }
            return hasMeeting
                ? "The last Capture Session was finalized. Its Meeting and processing artifacts remain available below."
                : "Run Capture Preflight, then create a Meeting and begin recording."
        case .detecting: return "Teams detection is active. Manual Start Capture remains available."
        case .starting: return "Checking prerequisites and preparing durable recording artifacts."
        case .recording:
            if isPreviousSessionFinalizing {
                return "Capture is live. A prior Meeting's audio is finalizing separately. Add notes or Action Item checkboxes, then stop deliberately when the Meeting ends."
            }
            if isPreviousSessionFinalizationFailed {
                return "Capture is live. A prior Meeting's audio finalization failed; its retained evidence and failure stay with that Meeting. Add notes or Action Item checkboxes, then stop deliberately when the Meeting ends."
            }
            return "Capture is live. Add notes or Action Item checkboxes, then stop deliberately when the Meeting ends."
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


}
