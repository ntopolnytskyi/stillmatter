import AppKit
import Combine
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

/// Native, paged read-only Transcript. Reading state outlives detail/status refreshes.
final class TranscriptReaderView: NSStackView, NSSearchFieldDelegate {
    let speakerEditor: TranscriptSpeakerEditor
    let analysisNotice = NSTextField(wrappingLabelWithString: "")
    private let reprocess: NSButton
    private var canCorrect = false
    private var isSavingCorrection = false
    private var speakerPanel: NSPanel?
    private var editingPhrase: TranscriptReaderPhrase?
    private var correctionButtons: [NSButton] = []
    private var correct: (String, String, @escaping (Result<Void, Error>) -> Void) -> Void = { _, _, _ in }
    private var requestReprocess: () -> Void = {}
    private var playSource: () -> Void = {}
    let heading = NSTextField(labelWithString: "Transcript timeline")
    private let jumpControls = NSStackView()
    let windowFeedback = NSTextField(labelWithString: "")
    let hourPicker: NSPopUpButton
    private(set) var kindButtons: [TranscriptReaderPhrase.Kind: NSButton] = [:]
    let state: TranscriptReaderState
    let search: NSSearchField
    let viewPicker: NSPopUpButton
    let speakersButton: NSButton
    let nextMatch: NSButton
    let previousMatch: NSButton
    let nextPage: NSButton
    let previousPage: NSButton
    let matchFeedback = NSTextField(labelWithString: "")
    let feedback = NSTextField(labelWithString: "")
    private let rows = TranscriptRowsDocumentView()
    let itemsScroll = NSScrollView()
    private let matchControls = NSStackView()
    private let controls: GraphiteFocusControls
    private let saveView: (TranscriptReadingView) -> Void
    private var seek: (TranscriptReaderPhrase) -> Void = { _ in }
    private var hasAudio = false
    private var keyMonitor: Any?
    private var navigationSubscription: AnyCancellable?
    private var activeID: String?
    private var phraseLabels: [String: NSTextField] = [:]
    private var phraseRows: [String: NSView] = [:]
    private var phraseKinds: [String: TranscriptReaderPhrase.Kind] = [:]
    private var timeButtons: [NSButton] = []

    init(controls: GraphiteFocusControls, view: TranscriptReadingView = .timestamps,
         saveView: @escaping (TranscriptReadingView) -> Void = { _ in },
         navigation: MeetingTimelineNavigation? = nil) {
        self.controls = controls
        speakerEditor = TranscriptSpeakerEditor(controls: controls)
        reprocess = controls.button("Reprocess…", identifier: "meeting-speaker-reprocess")
        self.state = TranscriptReaderState(view: view)
        self.saveView = saveView
        hourPicker = controls.popup(identifier: "meeting-transcript-hour")
        search = controls.searchField(identifier: "meeting-transcript-search")
        viewPicker = controls.popup(identifier: "meeting-transcript-view")
        speakersButton = controls.button("Show speakers", identifier: "meeting-transcript-speakers")
        nextMatch = controls.button("Next match", identifier: "meeting-transcript-next-match")
        previousMatch = controls.button("Previous match", identifier: "meeting-transcript-previous-match")
        nextPage = controls.button("Next", identifier: "meeting-transcript-next")
        previousPage = controls.button("Previous", identifier: "meeting-transcript-previous")
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = GraphiteFocusPresentation.Space.compact
        search.placeholderString = "Search entire recording…"
        search.setAccessibilityLabel("Search entire recording")
        search.delegate = self
        viewPicker.addItems(withTitles: TranscriptReadingView.allCases.map(\.title))
        viewPicker.selectItem(withTitle: view.title)
        viewPicker.target = self; viewPicker.action = #selector(changeView)
        speakersButton.target = self; speakersButton.action = #selector(showSpeakers)
        nextMatch.target = self; nextMatch.action = #selector(moveNextMatch)
        previousMatch.target = self; previousMatch.action = #selector(movePreviousMatch)
        nextPage.target = self; nextPage.action = #selector(moveNextPage)
        previousPage.target = self; previousPage.action = #selector(movePreviousPage)
        edgeInsets = NSEdgeInsets(top: GraphiteFocusPresentation.Space.panel, left: GraphiteFocusPresentation.Space.panel,
                                  bottom: GraphiteFocusPresentation.Space.panel, right: GraphiteFocusPresentation.Space.panel)
        spacing = GraphiteFocusPresentation.Space.panel
        wantsLayer = true
        setAccessibilityIdentifier("meeting-transcript-panel")
        setAccessibilityRole(.group)
        setAccessibilityElement(true)
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        heading.setAccessibilityIdentifier("meeting-transcript-heading")
        let header = NSStackView(views: [heading, NSView(), jumpControls])
        header.distribution = .fill
        let kinds = NSStackView()
        for kind in TranscriptReaderPhrase.Kind.allCases {
            let button = controls.button(kind.rawValue, identifier: "meeting-transcript-kind-\(kind.rawValue.lowercased())")
            button.setButtonType(.pushOnPushOff)
            button.isBordered = false
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: button.intrinsicContentSize.width + 2 * GraphiteFocusPresentation.Space.compact).isActive = true
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: button.intrinsicContentSize.height + 2 * GraphiteFocusPresentation.Space.primitive).isActive = true
            button.target = self; button.action = #selector(changeKinds)
            kindButtons[kind] = button
            kinds.addArrangedSubview(button)
        }
        analysisNotice.font = GraphiteFocusPresentation.Typography.metadata
        analysisNotice.setAccessibilityIdentifier("meeting-analysis-outdated")
        analysisNotice.isHidden = true; reprocess.isHidden = true
        reprocess.target = self; reprocess.action = #selector(reprocessAnalysis)
        let filterBar = NSStackView(views: [kinds, NSView(), viewPicker, speakersButton])
        filterBar.alignment = .centerY
        let jumpLabel = NSTextField(labelWithString: "Jump to")
        jumpLabel.font = GraphiteFocusPresentation.Typography.metadata
        hourPicker.target = self; hourPicker.action = #selector(changeHour)
        jumpControls.addArrangedSubview(jumpLabel)
        jumpControls.addArrangedSubview(hourPicker)
        jumpControls.alignment = .centerY
        jumpControls.spacing = GraphiteFocusPresentation.Space.compact
        jumpControls.setAccessibilityIdentifier("meeting-transcript-jump")
        let find = NSStackView(views: [windowFeedback, NSView(), previousPage, nextPage])
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hourPicker.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        for control in [matchFeedback, previousMatch, nextMatch] { matchControls.addArrangedSubview(control) }
        windowFeedback.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        windowFeedback.lineBreakMode = .byTruncatingTail
        feedback.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        windowFeedback.font = GraphiteFocusPresentation.Typography.metadata
        windowFeedback.setAccessibilityIdentifier("meeting-transcript-window")
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = GraphiteFocusPresentation.Space.flush
        rows.translatesAutoresizingMaskIntoConstraints = false
        itemsScroll.hasVerticalScroller = true
        itemsScroll.hasHorizontalScroller = false
        itemsScroll.drawsBackground = false
        itemsScroll.documentView = rows
        itemsScroll.setAccessibilityIdentifier("meeting-transcript-items-scroll")
        itemsScroll.setAccessibilityLabel("Transcript items")
        itemsScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        rows.widthAnchor.constraint(equalTo: itemsScroll.contentView.widthAnchor).isActive = true
        let divider = NSBox(); divider.boxType = .separator
        for child in [header, filterBar, search, find, matchControls, feedback, analysisNotice, reprocess, divider, itemsScroll] {
            addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: widthAnchor, constant: -2 * GraphiteFocusPresentation.Space.panel).isActive = true
        }
        matchFeedback.setAccessibilityIdentifier("meeting-transcript-match-status")
        matchFeedback.font = GraphiteFocusPresentation.Typography.metadata
        feedback.font = GraphiteFocusPresentation.Typography.metadata
        applyPanelColors()
        navigationSubscription = navigation?.$jump.compactMap { $0 }.sink { [weak self] jump in
            guard let self else { return }
            self.state.reveal(id: jump.segmentID)
            self.search.stringValue = self.state.query
            self.render()
            self.scrollSelection()
        }
        render()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }

    func load(meetingID: String, phrases: [TranscriptReaderPhrase], hasAudio: Bool, duration: Double? = nil,
              seek: @escaping (TranscriptReaderPhrase) -> Void) {
        let meetingChanged = self.meetingID != meetingID
        let unchanged = state.phrases == phrases && self.meetingID == meetingID && self.hasAudio == hasAudio && (duration == nil || state.duration == duration)
        self.seek = seek
        self.hasAudio = hasAudio
        if let editingPhrase {
            speakerEditor.audition.isEnabled = hasAudio && editingPhrase.seekSeconds != nil && phrases.contains {
                $0.id == editingPhrase.id && $0.seconds == editingPhrase.seconds && $0.seekSeconds == editingPhrase.seekSeconds
            }
        }
        if self.meetingID != meetingID { closeSpeakerEditor(); isSavingCorrection = false }
        self.meetingID = meetingID
        if unchanged { updateAudio(); return }
        state.load(meetingID: meetingID, phrases: phrases, duration: duration)
        search.stringValue = state.query
        render()
        if meetingChanged { scrollSelection() }
    }
    func configureCorrection(enabled: Bool, outdated: Bool, reviewRequired: Bool, review: [MeetingSpeakerCorrectionReview] = [],
        correct: @escaping (String, String, @escaping (Result<Void, Error>) -> Void) -> Void,
        reprocess: @escaping () -> Void, playSource: @escaping () -> Void = {}) {
        canCorrect = enabled; self.correct = correct; requestReprocess = reprocess; self.playSource = playSource
        for button in correctionButtons { button.isEnabled = enabled && !isSavingCorrection }
        let savedChoices = review.map { "\($0.name) · \($0.track.speakerLabel) \(Self.time($0.startSeconds))–\(Self.time($0.endSeconds))" }.joined(separator: "; ")
        analysisNotice.stringValue = reviewRequired
            ? "Analysis outdated · source timing changed; speaker corrections need review. Saved choices: \(savedChoices). Audition the source and correct again."
            : "Analysis outdated · speaker names changed. Reprocess explicitly to update analysis. Approved Action Items are preserved."
        analysisNotice.isHidden = !outdated && !reviewRequired; self.reprocess.isHidden = !outdated
        self.reprocess.isEnabled = enabled
        if !enabled { closeSpeakerEditor() }
    }
    @objc private func reprocessAnalysis() { requestReprocess() }
    private func editSpeaker(_ phrase: TranscriptReaderPhrase) {
        guard canCorrect, !isSavingCorrection else { return }
        let origin = meetingID
        let operation = correct
        let seekSource = seek
        let playSource = playSource
        editingPhrase = phrase
        speakerEditor.edit(name: phrase.speaker, hasAudio: hasAudio && phrase.seekSeconds != nil,
            apply: { [weak self] name in
                guard let self else { return }
                self.isSavingCorrection = true
                self.correctionButtons.forEach { $0.isEnabled = false }
                operation(phrase.sourceSegmentID, name) { [weak self] result in
                    guard let self, self.meetingID == origin else { return }
                    self.isSavingCorrection = false
                    self.correctionButtons.forEach { $0.isEnabled = self.canCorrect }
                    switch result {
                    case .success:
                        self.speakerEditor.finish(error: nil)
                        self.closeSpeakerEditor()
                        self.focusCorrection(phrase.id)
                    case let .failure(error): self.speakerEditor.finish(error: error)
                    }
                }
            }, cancel: { [weak self] in self?.closeSpeakerEditor(); self?.focusCorrection(phrase.id) },
            audition: { seekSource(phrase); playSource() })
        if let window, speakerPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            panel.title = "Correct speaker"
            let content = NSView()
            panel.contentView = content
            speakerEditor.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(speakerEditor)
            NSLayoutConstraint.activate([
                speakerEditor.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: GraphiteFocusPresentation.Space.panel),
                speakerEditor.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -GraphiteFocusPresentation.Space.panel),
                speakerEditor.topAnchor.constraint(equalTo: content.topAnchor, constant: GraphiteFocusPresentation.Space.panel),
                speakerEditor.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -GraphiteFocusPresentation.Space.panel)
            ])
            speakerPanel = panel
            window.beginSheet(panel)
            panel.makeFirstResponder(speakerEditor.name)
        }
    }
    private func closeSpeakerEditor() {
        if let panel = speakerPanel { panel.sheetParent?.endSheet(panel); panel.orderOut(nil) }
        speakerPanel = nil; editingPhrase = nil
        speakerEditor.removeFromSuperview()
        speakerEditor.isHidden = true
    }
    private func focusCorrection(_ id: String) {
        let button = correctionButtons.first { $0.accessibilityIdentifier() == "transcript-correct-" + id }
        window?.makeFirstResponder(button ?? search)
    }
    private var meetingID: String?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPanelColors()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        guard window != nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isHiddenOrHasHiddenAncestor, self.window?.isKeyWindow == true else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = event.charactersIgnoringModifiers?.lowercased()
            if flags == .command && key == "f" { self.window?.makeFirstResponder(self.search); return nil }
            if key == "g" && (flags == .command || flags == [.command, .shift]) {
                if flags.contains(.shift) { self.movePreviousMatch() } else { self.moveNextMatch() }
                return nil
            }
            if flags == [.command, .shift], let index = [18: 0, 19: 1, 20: 2][Int(event.keyCode)] {
                self.viewPicker.selectItem(at: index); self.changeView(); return nil
            }
            return event
        }
    }
    func controlTextDidChange(_ notification: Notification) {
        state.setQuery(search.stringValue); render(); scrollSelection()
    }
    @objc func changeKinds() {
        state.setKinds(Set(kindButtons.compactMap { $0.value.state == .on ? $0.key : nil }))
        render(); scrollSelection()
    }
    @objc func changeHour() { state.setWindow(hour: hourPicker.indexOfSelectedItem); search.stringValue = state.query; render(); scrollSelection() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); applyPanelColors() }
    private var colors: GraphiteFocusPresentation.Colors { .init(environment: .system(window: window)) }
    private func applyPanelColors() {
        layer?.backgroundColor = colors.surfacePanel.cgColor
        layer?.cornerRadius = GraphiteFocusPresentation.Radius.panel
        layer?.borderWidth = GraphiteFocusPresentation.Stroke.width
        layer?.borderColor = colors.structuralStroke.cgColor
        heading.textColor = colors.textPrimary
        for label in [feedback, matchFeedback, windowFeedback] { label.textColor = colors.textMetadata }
        for (kind, button) in kindButtons {
            let selected = state.kinds.contains(kind)
            button.isBordered = false; button.wantsLayer = true
            button.image = nil
            button.imagePosition = .noImage
            button.contentTintColor = selected ? colors.accent : colors.textMetadata
            button.layer?.cornerRadius = GraphiteFocusPresentation.Radius.compact
            button.layer?.backgroundColor = (selected ? colors.accent.withAlphaComponent(0.15) : colors.surfaceRaised).cgColor
            button.layer?.borderWidth = GraphiteFocusPresentation.Stroke.width
            button.layer?.borderColor = (selected ? colors.accent : colors.structuralStroke).cgColor
        }
    }
    @objc func changeView() {
        guard let title = viewPicker.titleOfSelectedItem, let view = TranscriptReadingView.allCases.first(where: { $0.title == title }) else { return }
        state.setView(view); saveView(view); render(); scrollSelection()
    }
    @objc func moveNextMatch() { state.nextMatch(); render(); scrollSelection() }
    @objc func movePreviousMatch() { state.previousMatch(); render(); scrollSelection() }
    @objc func moveNextPage() { state.nextPage(); search.stringValue = state.query; render(); scrollSelection() }
    @objc func movePreviousPage() { state.previousPage(); search.stringValue = state.query; render(); scrollSelection() }
    @objc func showSpeakers() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let all = NSMenuItem(title: "All speakers", action: #selector(selectSpeaker(_:)), keyEquivalent: "")
        all.target = self; all.state = state.speakers.isEmpty ? .on : .off
        menu.addItem(all)
        for speaker in state.availableSpeakers {
            let item = NSMenuItem(title: speaker, action: #selector(selectSpeaker(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = speaker
            item.state = state.speakers.contains(speaker) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: speakersButton.bounds.maxY), in: speakersButton)
    }
    @objc func selectSpeaker(_ sender: NSMenuItem) {
        var selected = state.speakers
        if let speaker = sender.representedObject as? String {
            if selected.contains(speaker) { selected.remove(speaker) } else { selected.insert(speaker) }
        } else { selected = [] }
        state.setSpeakers(selected); render()
    }
    private func render() {
        rows.arrangedSubviews.forEach { rows.removeArrangedSubview($0); $0.removeFromSuperview() }
        timeButtons = []; correctionButtons = []
        phraseRows = [:]
        phraseKinds = [:]
        phraseLabels = [:]
        for (kind, button) in kindButtons { button.state = state.kinds.contains(kind) ? .on : .off }
        applyPanelColors()
        hourPicker.removeAllItems()
        for hour in 0..<state.hourCount {
            hourPicker.addItem(withTitle: "Hour \(hour + 1) · \(Self.time(Double(hour * 3600)))–\(Self.time(min(state.duration, Double((hour + 1) * 3600))))")
        }
        hourPicker.selectItem(at: Int(state.windowStart / 3600))
        jumpControls.isHidden = state.duration <= 3600
        hourPicker.isEnabled = !state.phrases.isEmpty
        windowFeedback.stringValue = state.isSearching ? "Search results across entire recording" :
            "\(Self.time(state.windowStart))–\(Self.time(state.windowEnd))"
        matchControls.isHidden = !state.isSearching
        nextMatch.isEnabled = state.canNextMatch; previousMatch.isEnabled = state.canPreviousMatch
        nextPage.isEnabled = state.canNextPage; previousPage.isEnabled = state.canPreviousPage
        nextPage.title = state.isSearching || (state.page + 1) * state.pageSize < state.results.count ? "Next results" : "Next 15 min"
        previousPage.title = state.isSearching || state.page > 0 ? "Previous results" : "Previous 15 min"
        speakersButton.isEnabled = !state.phrases.isEmpty
        speakersButton.title = state.speakers.isEmpty ? "Speakers: All" : "Speakers: " + (state.speakers.count == 1 ? state.speakers.sorted().first ?? "All" : "\(state.speakers.count) selected")
        if state.results.isEmpty {
            feedback.stringValue = state.phrases.isEmpty ? "No Transcript available." : state.isSearching ? "No matches in this recording." : "No moments in this window or selected filters."
        } else {
            feedback.stringValue = ""
        }
        feedback.isHidden = !state.results.isEmpty
        matchFeedback.stringValue = state.matches.isEmpty ? "" : "Match \(state.matchNumber) of \(state.matches.count)"
        var priorSpeaker: String?
        for phrase in state.pageRows {
            if state.view == .speakers && phrase.kind == .transcript && phrase.speaker != priorSpeaker {
                let speaker = NSTextField(labelWithString: phrase.speaker.isEmpty ? "Unknown speaker" : phrase.speaker)
                speaker.font = GraphiteFocusPresentation.Typography.sectionHeading
                speaker.textColor = colors.textPrimary
                rows.addArrangedSubview(speaker)
            }
            priorSpeaker = phrase.kind == .transcript ? phrase.speaker : nil
            let row = phraseRow(phrase)
            phraseRows[phrase.id] = row
            phraseKinds[phrase.id] = phrase.kind
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
    private func phraseRow(_ phrase: TranscriptReaderPhrase) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal; row.alignment = .top; row.distribution = .fill
        row.spacing = GraphiteFocusPresentation.Space.panel
        row.edgeInsets = NSEdgeInsets(top: GraphiteFocusPresentation.Space.dense, left: GraphiteFocusPresentation.Space.dense,
                                     bottom: GraphiteFocusPresentation.Space.dense, right: GraphiteFocusPresentation.Space.dense)
        row.setAccessibilityIdentifier("transcript-row-\(phrase.id)")
        let body = NSStackView()
        body.orientation = .vertical; body.alignment = .leading; body.spacing = GraphiteFocusPresentation.Space.compact
        if state.view != .clearText {
            let time = controls.actionButton(Self.time(phrase.seconds), identifier: "transcript-time-\(phrase.id)") { [weak self] in self?.seek(phrase) }
            time.isBordered = false
            time.font = GraphiteFocusPresentation.Typography.numeric
            time.contentTintColor = colors.accent
            time.isEnabled = hasAudio && phrase.seekSeconds != nil
            time.toolTip = time.isEnabled ? "Jump to source" : "Audio unavailable · reading only"
            time.widthAnchor.constraint(equalToConstant: 88).isActive = true // graphite-focus-native-exception: aligned timeline timecode column
            timeButtons.append(time); row.addArrangedSubview(time)
        }
        let rowHeader = NSStackView()
        rowHeader.distribution = .fill
        rowHeader.alignment = .centerY
        rowHeader.spacing = GraphiteFocusPresentation.Space.compact
        if phrase.kind != .transcript {
            let kind = NSTextField(labelWithString: phrase.kind.caption)
            kind.font = GraphiteFocusPresentation.Typography.caption; kind.textColor = colors.accent
            kind.setAccessibilityIdentifier("transcript-kind-\(phrase.id)")
            rowHeader.addArrangedSubview(kind)
        }
        if phrase.kind == .transcript {
            let button = controls.actionButton(phrase.speaker.isEmpty ? "Unknown speaker…" : phrase.speaker, identifier: "transcript-correct-\(phrase.id)") { [weak self] in self?.editSpeaker(phrase) }
            button.isBordered = false
            button.font = GraphiteFocusPresentation.Typography.control
            button.contentTintColor = colors.textSecondary
            button.setAccessibilityLabel("Correct speaker: " + phrase.speaker)
            button.toolTip = "Correct speaker…"
            button.isEnabled = canCorrect && !isSavingCorrection
            correctionButtons.append(button)
            rowHeader.addArrangedSubview(button)
        }
        if phrase.kind != .transcript {
            let speaker = NSTextField(labelWithString: phrase.speaker.isEmpty ? "Unknown speaker" : phrase.speaker)
            speaker.font = GraphiteFocusPresentation.Typography.control
            speaker.textColor = colors.textSecondary
            speaker.setAccessibilityIdentifier("transcript-speaker-\(phrase.id)")
            rowHeader.addArrangedSubview(speaker)
            for (index, value) in phrase.chips.enumerated() {
                let chip = NSTextField(labelWithString: value)
                chip.isBezeled = true
                chip.bezelStyle = .roundedBezel
                chip.drawsBackground = true
                chip.backgroundColor = colors.surfaceRaised
                chip.textColor = colors.textSecondary
                chip.font = GraphiteFocusPresentation.Typography.metadata
                chip.setAccessibilityIdentifier("transcript-chip-\(phrase.id)-\(index)")
                rowHeader.addArrangedSubview(chip)
            }
        }
        rowHeader.addArrangedSubview(NSView())
        body.addArrangedSubview(rowHeader)
        rowHeader.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        let text = NSTextField(wrappingLabelWithString: phrase.text)
        text.font = phrase.id == activeID ? GraphiteFocusPresentation.Typography.activeTranscriptSegment : GraphiteFocusPresentation.Typography.body
        text.textColor = colors.textPrimary; text.isSelectable = true
        text.setAccessibilityIdentifier("transcript-text-\(phrase.id)")
        highlight(text, phraseID: phrase.id, field: .text)
        phraseLabels[phrase.id] = text
        updatePhraseStatus(phrase.id)
        body.addArrangedSubview(text)
        body.setContentHuggingPriority(.defaultLow, for: .horizontal)
        body.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(body)
        let copy = controls.actionButton("Copy", identifier: "transcript-copy-\(phrase.id)") {
            Self.copyToPasteboard(phrase.text)
        }
        let copyTimestamp = controls.actionButton("Copy w Timestamp", identifier: "transcript-copy-timestamp-\(phrase.id)") {
            Self.copyToPasteboard("\(phrase.speaker) \(Self.time(phrase.seconds)) \(phrase.text)")
        }
        let actions = NSStackView(views: [copy, copyTimestamp])
        actions.spacing = GraphiteFocusPresentation.Space.compact
        for button in [copy, copyTimestamp] {
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        rowHeader.addArrangedSubview(actions)
        actions.setContentHuggingPriority(.required, for: .horizontal)
        text.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        if state.matches.contains(where: { $0.phraseID == phrase.id && $0.field == .context }) {
            let context = NSTextField(wrappingLabelWithString: phrase.metadata)
            context.setAccessibilityIdentifier("transcript-context-\(phrase.id)")
            context.font = GraphiteFocusPresentation.Typography.metadata; context.textColor = colors.textMetadata
            highlight(context, phraseID: phrase.id, field: .context)
            body.addArrangedSubview(context)
            context.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true
        }
        row.wantsLayer = true
        row.layer?.backgroundColor = (phrase.id == activeID ? colors.accent.withAlphaComponent(0.12) : phrase.kind == .transcript ? NSColor.clear : colors.surfaceRaised.withAlphaComponent(0.35)).cgColor
        row.layer?.cornerRadius = GraphiteFocusPresentation.Radius.compact
        row.layer?.borderWidth = phrase.id == state.selectedID ? GraphiteFocusPresentation.Stroke.width : 0
        row.layer?.borderColor = (phrase.id == state.selectedID ? colors.accent : colors.structuralStroke).cgColor
        return row
    }
    private func highlight(_ label: NSTextField, phraseID: String, field: TranscriptSearchMatch.Field) {
        let content = NSMutableAttributedString(string: label.stringValue,
            attributes: [.font: label.font ?? GraphiteFocusPresentation.Typography.body, .foregroundColor: label.textColor ?? colors.textPrimary])
        for match in state.matches where match.phraseID == phraseID && match.field == field {
            content.addAttribute(.backgroundColor, value: state.selectedMatch == match ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor, range: match.range)
            if state.selectedMatch == match { content.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range) }
        }
        label.attributedStringValue = content
    }
    private static func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
    private func updateAudio() {
        for button in timeButtons {
            let id = button.accessibilityIdentifier().replacingOccurrences(of: "transcript-time-", with: "")
            button.isEnabled = hasAudio && state.phrases.first(where: { $0.id == id })?.seekSeconds != nil
            button.toolTip = button.isEnabled ? "Jump to source" : "Audio unavailable · reading only"
        }
    }
    func setActivePhrase(_ id: String?) {
        guard activeID != id else { return }
        activeID = id
        for (phraseID, row) in phraseRows {
            row.layer?.backgroundColor = (phraseID == id ? colors.accent.withAlphaComponent(0.12) : phraseKinds[phraseID] == .transcript ? NSColor.clear : colors.surfaceRaised.withAlphaComponent(0.35)).cgColor
            row.layer?.borderColor = (phraseID == state.selectedID ? colors.accent : colors.structuralStroke).cgColor
            if let label = phraseLabels[phraseID] {
                let content = NSMutableAttributedString(attributedString: label.attributedStringValue)
                content.addAttribute(.font, value: phraseID == id ? GraphiteFocusPresentation.Typography.activeTranscriptSegment : GraphiteFocusPresentation.Typography.body,
                                     range: NSRange(location: 0, length: content.length))
                label.attributedStringValue = content
                updatePhraseStatus(phraseID)
            }
        }
    }
    private func updatePhraseStatus(_ id: String) {
        var status: [String] = []
        if id == activeID { status.append("Current playback phrase") }
        if id == state.selectedID { status.append("Selected source phrase") }
        if let match = state.selectedMatch, match.phraseID == id {
            status.append("Current match\(match.field == .context ? " in context" : ""): characters \(match.range.location + 1) through \(NSMaxRange(match.range))")
        }
        phraseLabels[id]?.setAccessibilityHelp(status.joined(separator: ". "))
    }
    private func scrollSelection() {
        layoutSubtreeIfNeeded()
        if let id = state.selectedID, let row = phraseRows[id] {
            row.scrollToVisible(row.bounds)
        } else {
            itemsScroll.contentView.scroll(to: .zero)
            itemsScroll.reflectScrolledClipView(itemsScroll.contentView)
        }
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "Time unavailable" }
        let value = Int(seconds)
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}

/// Top-origin document keeps the first transcript item at the top of its viewport.
private final class TranscriptRowsDocumentView: NSStackView {
    override var isFlipped: Bool { true }
}
