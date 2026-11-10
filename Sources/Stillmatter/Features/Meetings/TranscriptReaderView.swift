import AppKit
import Combine
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

/// Native, paged read-only Transcript. Reading state outlives detail/status refreshes.
final class TranscriptReaderView: NSStackView, NSSearchFieldDelegate {
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
    private let rows = NSStackView()
    private let controls: GraphiteFocusControls
    private let saveView: (TranscriptReadingView) -> Void
    private var seek: (TranscriptReaderPhrase) -> Void = { _ in }
    private var hasAudio = false
    private var keyMonitor: Any?
    private var navigationSubscription: AnyCancellable?
    private var activeID: String?
    private var phraseLabels: [String: NSTextField] = [:]
    private var phraseRows: [String: NSView] = [:]
    private var timeButtons: [NSButton] = []

    init(controls: GraphiteFocusControls, view: TranscriptReadingView = .timestamps,
         saveView: @escaping (TranscriptReadingView) -> Void = { _ in },
         navigation: MeetingTimelineNavigation? = nil) {
        self.controls = controls
        self.state = TranscriptReaderState(view: view)
        self.saveView = saveView
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
        viewPicker.addItems(withTitles: TranscriptReadingView.allCases.map(\.rawValue))
        viewPicker.selectItem(withTitle: view.rawValue)
        viewPicker.target = self; viewPicker.action = #selector(changeView)
        speakersButton.target = self; speakersButton.action = #selector(showSpeakers)
        nextMatch.target = self; nextMatch.action = #selector(moveNextMatch)
        previousMatch.target = self; previousMatch.action = #selector(movePreviousMatch)
        nextPage.target = self; nextPage.action = #selector(moveNextPage)
        previousPage.target = self; previousPage.action = #selector(movePreviousPage)
        let options = NSStackView(views: [viewPicker, speakersButton])
        let find = NSStackView(views: [search, previousMatch, nextMatch])
        let paging = NSStackView(views: [feedback, matchFeedback, previousPage, nextPage])
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = GraphiteFocusPresentation.Space.compact
        for child in [options, find, paging, rows] {
            addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        matchFeedback.setAccessibilityIdentifier("meeting-transcript-match-status")
        matchFeedback.font = GraphiteFocusPresentation.Typography.metadata
        feedback.font = GraphiteFocusPresentation.Typography.metadata
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

    func load(meetingID: String, phrases: [TranscriptReaderPhrase], hasAudio: Bool,
              seek: @escaping (TranscriptReaderPhrase) -> Void) {
        let unchanged = state.phrases == phrases && self.meetingID == meetingID
        self.seek = seek
        self.hasAudio = hasAudio
        self.meetingID = meetingID
        if unchanged { updateAudio(); return }
        state.load(meetingID: meetingID, phrases: phrases)
        search.stringValue = state.query
        render()
    }
    private var meetingID: String?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
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
        state.setQuery(search.stringValue); render()
    }
    @objc func changeView() {
        guard let title = viewPicker.titleOfSelectedItem, let view = TranscriptReadingView(rawValue: title) else { return }
        state.setView(view); saveView(view); render()
    }
    @objc func moveNextMatch() { state.nextMatch(); render(); scrollSelection() }
    @objc func movePreviousMatch() { state.previousMatch(); render(); scrollSelection() }
    @objc func moveNextPage() { state.nextPage(); render(); scrollSelection() }
    @objc func movePreviousPage() { state.previousPage(); render(); scrollSelection() }
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
        timeButtons = []
        phraseRows = [:]
        phraseLabels = [:]
        nextMatch.isEnabled = state.canNextMatch; previousMatch.isEnabled = state.canPreviousMatch
        nextPage.isEnabled = state.canNextPage; previousPage.isEnabled = state.canPreviousPage
        speakersButton.isEnabled = !state.phrases.isEmpty
        speakersButton.title = state.speakers.isEmpty ? "Show speakers · All" : "Show speakers · \(state.speakers.count) selected"
        if state.results.isEmpty {
            feedback.stringValue = state.phrases.isEmpty ? "No Transcript available." : "No matches in this recording."
        } else {
            feedback.stringValue = "Results \(state.pageStart)–\(state.pageEnd) of \(state.results.count)"

        }
        matchFeedback.stringValue = state.matches.isEmpty ? "" : "Match \(state.matchNumber) of \(state.matches.count)"
        var priorSpeaker: String?
        for phrase in state.pageRows {
            if state.view == .speakers && phrase.speaker != priorSpeaker {
                let heading = NSTextField(labelWithString: phrase.speaker)
                heading.font = GraphiteFocusPresentation.Typography.sectionHeading
                rows.addArrangedSubview(heading)
            }
            priorSpeaker = phrase.speaker
            let row = phraseRow(phrase)
            phraseRows[phrase.id] = row
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
    }
    private func phraseRow(_ phrase: TranscriptReaderPhrase) -> NSView {
        let row = NSStackView()
        row.orientation = .vertical; row.alignment = .leading
        row.spacing = GraphiteFocusPresentation.Space.primitive
        row.setAccessibilityIdentifier("transcript-row-\(phrase.id)")
        if state.view != .clearText {
            let initials = phrase.speaker.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            let avatar = NSTextField(labelWithString: initials)
            avatar.font = GraphiteFocusPresentation.Typography.caption
            let name = NSTextField(labelWithString: phrase.speaker)
            name.font = GraphiteFocusPresentation.Typography.rowTitle
            let time = controls.actionButton(Self.time(phrase.seconds), identifier: "transcript-time-\(phrase.id)") { [weak self] in
                self?.seek(phrase)
            }
            time.isBordered = false
            time.isEnabled = hasAudio && phrase.seekSeconds != nil
            time.toolTip = time.isEnabled ? "Jump to source" : "Audio unavailable · reading only"
            timeButtons.append(time)
            row.addArrangedSubview(NSStackView(views: [avatar, name, time]))
        }
        let text = NSTextField(wrappingLabelWithString: phrase.text)
        text.font = phrase.id == activeID ? GraphiteFocusPresentation.Typography.activeTranscriptSegment : GraphiteFocusPresentation.Typography.body
        text.isSelectable = true
        text.setAccessibilityIdentifier("transcript-text-\(phrase.id)")
        let highlighted = NSMutableAttributedString(string: phrase.text, attributes: [.font: text.font!])
        for match in state.matches where match.phraseID == phrase.id {
            highlighted.addAttribute(.backgroundColor, value: state.selectedMatch == match ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor, range: match.range)
            if state.selectedMatch == match { highlighted.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range) }
        }
        text.attributedStringValue = highlighted
        phraseLabels[phrase.id] = text
        updatePhraseStatus(phrase.id)
        text.menu = contextMenu(phrase)
        row.addArrangedSubview(text)
        text.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        row.wantsLayer = true
        row.layer?.borderWidth = phrase.id == state.selectedID ? GraphiteFocusPresentation.Stroke.width : 0
        row.layer?.borderColor = NSColor.controlAccentColor.cgColor
        return row
    }
    private func contextMenu(_ phrase: TranscriptReaderPhrase) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, value) in [("Copy text", phrase.text), ("Copy with timestamp", "\(phrase.speaker) \(Self.time(phrase.seconds)) \(phrase.text)"), ("Copy speaker", phrase.speaker)] {
            let item = NSMenuItem(title: title, action: #selector(copyValue(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = value; menu.addItem(item)
        }
        return menu
    }
    @objc func copyValue(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
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
            row.layer?.borderWidth = phraseID == state.selectedID ? GraphiteFocusPresentation.Stroke.width : 0
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
            status.append("Current match: characters \(match.range.location + 1) through \(NSMaxRange(match.range))")
        }
        phraseLabels[id]?.setAccessibilityHelp(status.joined(separator: ". "))
    }
    private func scrollSelection() {
        guard let id = state.selectedID, let row = rows.arrangedSubviews.first(where: { $0.accessibilityIdentifier() == "transcript-row-\(id)" }) else { return }
        layoutSubtreeIfNeeded(); row.scrollToVisible(row.bounds)
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "Time unavailable" }
        let value = Int(seconds)
        return String(format: "%02d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
    }
}
