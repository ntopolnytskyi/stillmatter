import AppKit
import EventKit
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterTranscriptionRuntime
#endif

private final class DiagnosticRowViews {
    let statusLabel: GraphiteFocusStatusLabel
    let detailLabel: NSTextField
    let actionButton: NSButton?

    init(statusLabel: GraphiteFocusStatusLabel, detailLabel: NSTextField, actionButton: NSButton?) {
        self.statusLabel = statusLabel
        self.detailLabel = detailLabel
        self.actionButton = actionButton
    }
}

final class SettingsFormView: NSView, NSTextFieldDelegate {
    private let settingsStore: SettingsStore
    private let diagnosticsProvider: PermissionDiagnosticsProvider
    private let transcriptionComponentInstaller: TranscriptionComponentInstaller
    private let hardwareModel: String
    private let onRebuildIndex: ((@escaping (Result<Void, Error>) -> Void) -> Void)?
    private var transcriptionComponentObserver: UUID?

    private let rootPathLabel = NSTextField(labelWithString: "Not selected")
    private let mediaPathLabel = NSTextField(labelWithString: "Not selected")
    private let calendarSourcesButton = NSButton(title: "All readable calendars", target: nil, action: nil)
    private let calendarEventStore = EKEventStore()
    private let launchAtLoginCheckbox = NSButton(checkboxWithTitle: "Launch Stillmatter at login", target: nil, action: nil)
    private let workdayStartField = NSTextField(string: "")
    private let workdayEndField = NSTextField(string: "")
    private let endOfWeekDayPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let endOfWeekTimeField = NSTextField(string: "")
    private let searchExcludesField = NSTextField(string: "")
    private let transcriptionModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let teamsRecordingPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    private let searchFeedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let workingTimeFeedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let diagnosticsSummaryLabel = NSTextField(wrappingLabelWithString: "Checking diagnostics…")
    private let diagnosticsActionLabel = NSTextField(wrappingLabelWithString: "")
    private var diagnosticRows: [String: DiagnosticRowViews] = [:]
    private var adaptiveRows: [(row: NSStackView, wideAlignment: NSLayoutConstraint.Attribute)] = []

    override func layout() {
        super.layout()
        applyAdaptiveRowLayout(forWidth: bounds.width)
    }

    private func applyAdaptiveRowLayout(forWidth width: CGFloat) {
        let usesNarrowRows = width > 0 && width < 680
        adaptiveRows.forEach { entry in
            entry.row.orientation = usesNarrowRows ? .vertical : .horizontal
            entry.row.alignment = usesNarrowRows ? .leading : entry.wideAlignment
            entry.row.spacing = usesNarrowRows
                ? GraphiteFocusPresentation.Space.compact
                : GraphiteFocusPresentation.Space.dense
        }
    }

    init(
        settingsStore: SettingsStore,
        transcriptionComponentInstaller: TranscriptionComponentInstaller,
        onRebuildIndex: ((@escaping (Result<Void, Error>) -> Void) -> Void)? = nil
    ) {
        self.settingsStore = settingsStore
        self.transcriptionComponentInstaller = transcriptionComponentInstaller
        self.hardwareModel = FasterWhisperRuntimeSupport.deviceName()
        self.diagnosticsProvider = PermissionDiagnosticsProvider(
            settingsStore: settingsStore,
            transcriptionComponentInstaller: transcriptionComponentInstaller,
            hardwareModel: FasterWhisperRuntimeSupport.deviceName()
        )
        self.onRebuildIndex = onRebuildIndex
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 720))
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
        settingsStore.observe { [weak self] settings in
            self?.render(settings)
            self?.refreshDiagnostics()
        }
        transcriptionComponentObserver = transcriptionComponentInstaller.observe { [weak self] state in
            self?.renderTranscriptionDiagnostic(state)
        }
    }

    deinit {
        if let observer = transcriptionComponentObserver {
            transcriptionComponentInstaller.removeObserver(observer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = GraphiteFocusPresentation.Space.panel
        stack.translatesAutoresizingMaskIntoConstraints = false

        rootPathLabel.lineBreakMode = .byTruncatingMiddle
        mediaPathLabel.lineBreakMode = .byTruncatingMiddle
        [validationLabel, searchFeedbackLabel, workingTimeFeedbackLabel, diagnosticsSummaryLabel, diagnosticsActionLabel].forEach {
            $0.textColor = .secondaryLabelColor
            $0.maximumNumberOfLines = 0
        }
        diagnosticsSummaryLabel.textColor = .secondaryLabelColor
        diagnosticsActionLabel.textColor = .secondaryLabelColor

        calendarSourcesButton.target = self
        calendarSourcesButton.action = #selector(showCalendarSources(_:))
        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginChanged(_:))

        configureTimeField(workdayStartField, placeholder: "09:00")
        configureTimeField(workdayEndField, placeholder: "19:00")
        configureTimeField(endOfWeekTimeField, placeholder: "19:00")

        Weekday.allCases.forEach { weekday in
            endOfWeekDayPopup.addItem(withTitle: weekday.displayName)
            endOfWeekDayPopup.lastItem?.tag = weekday.rawValue
        }
        endOfWeekDayPopup.target = self
        endOfWeekDayPopup.action = #selector(workingHoursChanged(_:))
        searchExcludesField.placeholderString = "Private/**, Archive/Old/**"
        searchExcludesField.target = self
        searchExcludesField.action = #selector(searchExcludesChanged(_:))
        for choice in TranscriptionModelChoice.allCases {
            transcriptionModelPopup.addItem(withTitle: choice.displayName)
            transcriptionModelPopup.lastItem?.representedObject = choice.rawValue
            if !TranscriptionModelCompatibility.isSupported(choice, hardwareModel: hardwareModel) {
                transcriptionModelPopup.lastItem?.title += " — unavailable on this Mac"
                transcriptionModelPopup.lastItem?.isEnabled = false
            }
        }
        transcriptionModelPopup.target = self
        transcriptionModelPopup.action = #selector(transcriptionModelChanged(_:))
        for mode in TeamsRecordingMode.allCases {
            teamsRecordingPopup.addItem(withTitle: mode.displayName)
            teamsRecordingPopup.lastItem?.representedObject = mode.rawValue
        }
        teamsRecordingPopup.target = self
        teamsRecordingPopup.action = #selector(teamsRecordingChanged(_:))

        stack.addArrangedSubview(sectionHeader("Workspace"))
        stack.addArrangedSubview(pathRow(title: "Stillmatter root", pathLabel: rootPathLabel, buttonTitle: "Choose…", action: #selector(chooseStillmatterRoot(_:))))
        stack.addArrangedSubview(pathRow(title: "Recording media location", pathLabel: mediaPathLabel, buttonTitle: "Choose…", action: #selector(chooseRecordingMediaLocation(_:))))
        stack.addArrangedSubview(sectionHeader("Native Teams capture"))
        stack.addArrangedSubview(teamsRecordingRow())
        stack.addArrangedSubview(sectionHeader("Calendar"))
        stack.addArrangedSubview(calendarSourcesRow())
        stack.addArrangedSubview(sectionHeader("Search Index"))
        stack.addArrangedSubview(searchIndexRow())
        stack.addArrangedSubview(searchFeedbackLabel)
        stack.addArrangedSubview(sectionHeader("Preferences"))
        stack.addArrangedSubview(launchAtLoginCheckbox)
        stack.addArrangedSubview(validationLabel)
        stack.addArrangedSubview(sectionHeader("Working time"))
        stack.addArrangedSubview(workingHoursRow())
        stack.addArrangedSubview(endOfWeekRow())
        stack.addArrangedSubview(workingTimeFeedbackLabel)
        stack.addArrangedSubview(sectionHeader("Permissions & Components"))
        stack.addArrangedSubview(diagnosticsSummaryLabel)
        stack.addArrangedSubview(diagnosticsActionLabel)
        stack.addArrangedSubview(diagnosticsRow(id: "microphone", title: "Microphone", buttonTitle: "Test Mic"))
        stack.addArrangedSubview(diagnosticsRow(id: "calendar", title: "Calendar", buttonTitle: "Test Calendar"))
        stack.addArrangedSubview(diagnosticsRow(id: "notifications", title: "Notifications", buttonTitle: "Test Notifications"))
        stack.addArrangedSubview(diagnosticsRow(id: "vaultAccess", title: "Stillmatter root folder access", buttonTitle: "Test Vault"))
        stack.addArrangedSubview(diagnosticsRow(id: "mediaAccess", title: "Recording media folder access", buttonTitle: "Test Media"))
        stack.addArrangedSubview(diagnosticsRow(id: "launchAtLogin", title: "Launch at login", buttonTitle: nil))
        stack.addArrangedSubview(diagnosticsRow(id: "pi", title: "Pi CLI detection", buttonTitle: "Test Pi"))
        stack.addArrangedSubview(transcriptionModelRow())
        stack.addArrangedSubview(diagnosticsRow(id: "localTranscription", title: "Local transcription", buttonTitle: "Install"))

        stack.arrangedSubviews.forEach { arrangedSubview in
            arrangedSubview.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor)
        ])
    }

    private func configureTimeField(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.target = self
        field.action = #selector(workingHoursChanged(_:))
        field.delegate = self
        field.widthAnchor.constraint(equalToConstant: 72).isActive = true
    }

    private func sectionHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = GraphiteFocusPresentation.Typography.sectionHeading
        return label
    }

    private func pathRow(title: String, pathLabel: NSTextField, buttonTitle: String, action: Selector) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.widthAnchor.constraint(equalToConstant: 180).isActive = true
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: buttonTitle, target: self, action: action)

        button.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [titleLabel, pathLabel, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = GraphiteFocusPresentation.Space.dense
        registerAdaptiveRow(row, wideAlignment: .centerY)
        return row
    }

    private func diagnosticsRow(id: String, title: String, buttonTitle: String?) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.widthAnchor.constraint(equalToConstant: 180).isActive = true

        let statusLabel = GraphiteFocusStatusLabel()
        statusLabel.setStatus("Checking", meaning: .informational, colors: GraphiteFocusPresentation.Colors(environment: .system(window: window)))
        statusLabel.widthAnchor.constraint(equalToConstant: 130).isActive = true

        let detailLabel = NSTextField(wrappingLabelWithString: "")
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var views: [NSView] = [titleLabel, statusLabel, detailLabel]
        var button: NSButton?
        if let buttonTitle = buttonTitle {
            let actionButton = NSButton(title: buttonTitle, target: self, action: #selector(runDiagnosticAction(_:)))
            actionButton.identifier = NSUserInterfaceItemIdentifier(id)
            actionButton.setContentHuggingPriority(.required, for: .horizontal)
            views.append(actionButton)
            button = actionButton
        }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .top
        row.distribution = .fill
        row.spacing = GraphiteFocusPresentation.Space.dense
        diagnosticRows[id] = DiagnosticRowViews(statusLabel: statusLabel, detailLabel: detailLabel, actionButton: button)
        registerAdaptiveRow(row, wideAlignment: .top)
        return row
    }

    private func teamsRecordingRow() -> NSView {
        let label = NSTextField(labelWithString: "When a call is detected")
        label.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let hint = NSTextField(wrappingLabelWithString: "Manual Start/Stop is always available. Automatic capture requires Teams Accessibility detection and capture preflight.")
        hint.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, teamsRecordingPopup, hint])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = GraphiteFocusPresentation.Space.dense
        registerAdaptiveRow(row, wideAlignment: .top)
        return row
    }

    private func transcriptionModelRow() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Transcription model")
        titleLabel.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let guidance = NSTextField(wrappingLabelWithString: "Recommended uses faster-whisper Large v3 Turbo and needs about 4 GB free during setup. Full quality uses Large v3 and needs about 7 GB.")
        guidance.textColor = .secondaryLabelColor
        guidance.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [titleLabel, transcriptionModelPopup, guidance])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = GraphiteFocusPresentation.Space.dense
        registerAdaptiveRow(row, wideAlignment: .top)
        return row
    }

    private func calendarSourcesRow() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Daily Brief sources")
        titleLabel.widthAnchor.constraint(equalToConstant: 180).isActive = true
        calendarSourcesButton.alignment = .left
        calendarSourcesButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [titleLabel, calendarSourcesButton, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = GraphiteFocusPresentation.Space.dense
        registerAdaptiveRow(row, wideAlignment: .centerY)
        return row
    }

    private func searchIndexRow() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Excluded paths")
        titleLabel.widthAnchor.constraint(equalToConstant: 180).isActive = true
        searchExcludesField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let rebuildButton = NSButton(title: "Rebuild Index", target: self, action: #selector(rebuildIndex(_:)))
        rebuildButton.isEnabled = onRebuildIndex != nil
        let row = NSStackView(views: [titleLabel, searchExcludesField, rebuildButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = GraphiteFocusPresentation.Space.dense
        registerAdaptiveRow(row, wideAlignment: .centerY)
        return row
    }

    private func workingHoursRow() -> NSView {
        let titleLabel = NSTextField(labelWithString: "Workdays")
        titleLabel.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let weekdayLabel = NSTextField(labelWithString: "Monday–Friday")
        weekdayLabel.textColor = .secondaryLabelColor
        let fromLabel = NSTextField(labelWithString: "from")
        let toLabel = NSTextField(labelWithString: "to")

        weekdayLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [titleLabel, weekdayLabel, fromLabel, workdayStartField, toLabel, workdayEndField, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = GraphiteFocusPresentation.Space.compact
        registerAdaptiveRow(row, wideAlignment: .centerY)
        return row
    }

    private func endOfWeekRow() -> NSView {
        let titleLabel = NSTextField(labelWithString: "End of week")
        titleLabel.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let atLabel = NSTextField(labelWithString: "at")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [titleLabel, endOfWeekDayPopup, atLabel, endOfWeekTimeField, spacer])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = GraphiteFocusPresentation.Space.compact
        registerAdaptiveRow(row, wideAlignment: .centerY)
        return row
    }

    private func registerAdaptiveRow(_ row: NSStackView, wideAlignment: NSLayoutConstraint.Attribute) {
        adaptiveRows.append((row, wideAlignment))
    }

    private func render(_ settings: AppSettings) {
        rootPathLabel.stringValue = settings.stillmatterRootURL?.path ?? "Not selected"
        mediaPathLabel.stringValue = settings.recordingMediaURL?.path ?? "Not selected"
        calendarSourcesButton.title = calendarSourcesTitle(settings: settings)
        launchAtLoginCheckbox.state = settings.launchAtLoginEnabled ? .on : .off
        teamsRecordingPopup.selectItem(withTitle: settings.teamsRecordingMode.displayName)
        workdayStartField.stringValue = settings.workingHours.startTime.displayValue
        workdayEndField.stringValue = settings.workingHours.endTime.displayValue
        endOfWeekTimeField.stringValue = settings.workingHours.endOfWeekTime.displayValue
        endOfWeekDayPopup.selectItem(withTag: settings.workingHours.endOfWeekDay.rawValue)
        searchExcludesField.stringValue = settings.searchExcludedPatterns.joined(separator: ", ")
        if let index = TranscriptionModelChoice.allCases.firstIndex(of: settings.transcriptionModelChoice) {
            transcriptionModelPopup.selectItem(at: index)
        }
        validationLabel.stringValue = "Settings are saved automatically. Missing permissions fail closed only for affected features listed below."
        validationLabel.textColor = .secondaryLabelColor
    }

    private func refreshDiagnostics() {
        diagnosticsProvider.refresh { [weak self] snapshot in
            self?.renderDiagnostics(snapshot)
        }
    }

    private func renderDiagnostics(_ snapshot: DiagnosticsSnapshot) {
        diagnosticsSummaryLabel.stringValue = snapshot.missingFeatureSummary
        (snapshot.permissions + snapshot.components).forEach(renderDiagnosticItem)
    }

    private func renderTranscriptionDiagnostic(_ state: TranscriptionComponentState) {
        let selectedModel = settingsStore.settings.transcriptionModelChoice
        var item = TranscriptionComponentDiagnostic.item(
            for: state,
            selectedModel: selectedModel,
            installedModel: transcriptionComponentInstaller.installedModelChoice()
        )
        if !TranscriptionModelCompatibility.isSupported(selectedModel, hardwareModel: hardwareModel) {
            item.status = .unavailable
            item.explanation += " Local faster-whisper transcription is unavailable on this Mac."
            item.affectedFeatures = ["automatic meeting transcription"]
            item.actionTitle = nil
        }
        renderDiagnosticItem(item)
    }

    private func renderDiagnosticItem(_ item: DiagnosticItem) {
        guard let row = diagnosticRows[item.id] else { return }
        row.statusLabel.setStatus(statusText(item.status), meaning: statusMeaning(item.status), colors: GraphiteFocusPresentation.Colors(environment: .system(window: window)))
        let affected = item.affectedFeatures.isEmpty
            ? ""
            : " Affects: \(item.affectedFeatures.joined(separator: ", "))."
        row.detailLabel.stringValue = item.explanation + affected
        row.actionButton?.title = item.actionTitle ?? "Ready"
        row.actionButton?.isEnabled = item.actionTitle != nil
    }

    private func statusText(_ status: DiagnosticStatus) -> String {
        switch status {
        case .granted: return "Granted"
        case .missing: return "Missing"
        case .unavailable: return "Unavailable"
        case .notConfigured: return "Not set"
        case .unknown: return "Unknown"
        }
    }

    private func statusMeaning(_ status: DiagnosticStatus) -> GraphiteFocusStatusMeaning {
        switch status {
        case .granted: return .success
        case .missing: return .destructive
        case .unavailable, .notConfigured, .unknown: return .informational
        }
    }

    @objc private func chooseStillmatterRoot(_ sender: NSButton) {
        chooseDirectory(title: "Choose Stillmatter Root") { [weak self] url in
            self?.settingsStore.settings.stillmatterRootURL = url
        }
    }

    @objc private func chooseRecordingMediaLocation(_ sender: NSButton) {
        chooseDirectory(title: "Choose Recording Media Location") { [weak self] url in
            self?.settingsStore.settings.recordingMediaURL = url
        }
    }

    @objc private func showCalendarSources(_ sender: NSButton) {
        let menu = NSMenu(title: "Daily Brief calendar sources")
        let selection = settingsStore.settings.calendarSourceSelection
        let selected = selection.selectedCalendarIdentifiers
        let allItem = NSMenuItem(
            title: "All readable calendars",
            action: #selector(selectAllCalendars(_:)),
            keyEquivalent: ""
        )
        allItem.target = self
        allItem.state = selection.mode == .all ? .on : .off
        menu.addItem(allItem)

        let noneItem = NSMenuItem(
            title: "No calendar sources",
            action: #selector(selectNoCalendars(_:)),
            keyEquivalent: ""
        )
        noneItem.target = self
        noneItem.state = selection.mode == .none ? .on : .off
        menu.addItem(noneItem)
        menu.addItem(.separator())

        let calendars: [EKCalendar]
        if hasReadableCalendarAccess {
            calendars = calendarEventStore.calendars(for: .event).sorted {
                if $0.title == $1.title { return $0.calendarIdentifier < $1.calendarIdentifier }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        } else {
            calendars = []
            let unavailable = NSMenuItem(title: "Grant Calendar access to read sources", action: nil, keyEquivalent: "")
            unavailable.isEnabled = false
            menu.addItem(unavailable)
        }

        for calendar in calendars {
            let item = NSMenuItem(
                title: calendar.title,
                action: #selector(toggleCalendarSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = calendar.calendarIdentifier
            item.state = selected.contains(calendar.calendarIdentifier) ? .on : .off
            menu.addItem(item)
        }

        let availableIdentifiers = Set(calendars.map(\.calendarIdentifier))
        for identifier in selected.subtracting(availableIdentifiers).sorted() {
            let item = NSMenuItem(
                title: "Unavailable calendar (\(identifier.prefix(8))) — click to remove",
                action: #selector(toggleCalendarSource(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = identifier
            item.state = .on
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY + 4), in: sender)
    }

    @objc private func selectAllCalendars(_ sender: NSMenuItem) {
        var settings = settingsStore.settings
        settings.calendarSourceSelection = .all
        settingsStore.settings = settings
    }

    @objc private func selectNoCalendars(_ sender: NSMenuItem) {
        var settings = settingsStore.settings
        settings.calendarSourceSelection = .none
        settingsStore.settings = settings
    }

    @objc private func toggleCalendarSource(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        var settings = settingsStore.settings
        var selected = settings.calendarSourceSelection.selectedCalendarIdentifiers
        if selected.contains(identifier) {
            selected.remove(identifier)
        } else {
            selected.insert(identifier)
        }
        settings.calendarSourceSelection = .selected(Array(selected))
        settingsStore.settings = settings
    }

    private var hasReadableCalendarAccess: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .authorized, .fullAccess: return true
        case .writeOnly, .denied, .restricted, .notDetermined: return false
        @unknown default: return false
        }
    }

    private func calendarSourcesTitle(settings: AppSettings) -> String {
        let selection = settings.calendarSourceSelection
        switch selection.mode {
        case .all:
            return "All readable calendars"
        case .none:
            return "No calendar sources"
        case .selected:
            break
        }

        let selected = selection.selectedCalendarIdentifiers
        guard hasReadableCalendarAccess else {
            return "\(selected.count) selected — Calendar access required"
        }
        let calendars = calendarEventStore.calendars(for: .event)
        if selected.count == 1,
           let calendar = calendars.first(where: { selected.contains($0.calendarIdentifier) }) {
            return calendar.title
        }
        let availableCount = calendars.filter { selected.contains($0.calendarIdentifier) }.count
        let unavailableCount = selected.count - availableCount
        if unavailableCount > 0 {
            return "\(selected.count) selected (\(unavailableCount) unavailable)"
        }
        return "\(selected.count) calendars selected"
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        settingsStore.settings.launchAtLoginEnabled = sender.state == .on
    }

    @objc private func teamsRecordingChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = TeamsRecordingMode(rawValue: raw) else { return }
        var settings = settingsStore.settings
        settings.teamsRecordingMode = mode
        settingsStore.settings = settings
    }

    @objc private func transcriptionModelChanged(_ sender: NSPopUpButton) {
        guard let rawValue = sender.selectedItem?.representedObject as? String,
              let choice = TranscriptionModelChoice(rawValue: rawValue),
              TranscriptionModelCompatibility.isSupported(choice, hardwareModel: hardwareModel) else { return }
        var settings = settingsStore.settings
        settings.transcriptionModelChoice = choice
        settingsStore.settings = settings
        renderTranscriptionDiagnostic(transcriptionComponentInstaller.state())
    }

    @objc private func searchExcludesChanged(_ sender: NSTextField) {
        var settings = settingsStore.settings
        settings.searchExcludedPatterns = sender.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        settingsStore.settings = settings
    }

    @objc private func rebuildIndex(_ sender: NSButton) {
        sender.isEnabled = false
        searchFeedbackLabel.stringValue = "Rebuilding search index…"
        onRebuildIndex? { [weak self, weak sender] result in
            guard let self else { return }
            sender?.isEnabled = true
            switch result {
            case .success:
                self.searchFeedbackLabel.stringValue = "✓ Search index rebuilt from the current workspace."
                self.searchFeedbackLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: self.window)).success
            case let .failure(error):
                self.searchFeedbackLabel.stringValue = "! Could not rebuild search index: \(error)"
                self.searchFeedbackLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: self.window)).destructive
            }
        }
    }

    @objc private func runDiagnosticAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        sender.isEnabled = false
        diagnosticsProvider.performAction(for: id) { [weak self] message in
            guard let self = self else { return }
            self.validationLabel.stringValue = message
            self.validationLabel.textColor = .secondaryLabelColor
            self.diagnosticsActionLabel.stringValue = message
            self.diagnosticsActionLabel.textColor = .secondaryLabelColor
            sender.isEnabled = true
            self.render(self.settingsStore.settings)
            self.refreshDiagnostics()
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        workingHoursChanged(obj)
    }

    @objc private func workingHoursChanged(_ sender: Any) {
        guard let startTime = TimeOfDay.parse(workdayStartField.stringValue),
              let endTime = TimeOfDay.parse(workdayEndField.stringValue),
              let endOfWeekTime = TimeOfDay.parse(endOfWeekTimeField.stringValue),
              let endOfWeekDay = Weekday(rawValue: endOfWeekDayPopup.selectedTag()) else {
            workingTimeFeedbackLabel.stringValue = "! Use 24-hour HH:MM times, for example 09:00 or 19:00."
            workingTimeFeedbackLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).destructive
            return
        }

        var settings = settingsStore.settings
        settings.workingHours = WorkingHoursSettings(
            weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday],
            startTime: startTime,
            endTime: endTime,
            endOfWeekDay: endOfWeekDay,
            endOfWeekTime: endOfWeekTime
        )
        settingsStore.settings = settings
        workingTimeFeedbackLabel.stringValue = "✓ Working time saved automatically."
        workingTimeFeedbackLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).success
    }

    /// Whole-shell fixture coverage for constrained width, adaptive rows, validation, and redundant diagnostic meaning.
    func validateFixtures() {
        let originalStart = workdayStartField.stringValue
        let originalEnd = workdayEndField.stringValue
        let originalEndOfWeek = endOfWeekTimeField.stringValue

        applyAdaptiveRowLayout(forWidth: 520)
        precondition(adaptiveRows.allSatisfy { $0.row.orientation == .vertical }, "Settings Form Rows must stack at narrow widths")
        applyAdaptiveRowLayout(forWidth: 680)
        precondition(adaptiveRows.allSatisfy { $0.row.orientation == .horizontal }, "Settings Form Rows must use aligned columns when space permits")

        workdayStartField.stringValue = "invalid"
        workingHoursChanged(self)
        precondition(workingTimeFeedbackLabel.stringValue.contains("HH:MM"), "Invalid working time must show nearby static validation")
        workdayStartField.stringValue = originalStart
        workdayEndField.stringValue = originalEnd
        endOfWeekTimeField.stringValue = originalEndOfWeek

        let statuses: [DiagnosticStatus] = [.granted, .missing, .unavailable, .notConfigured, .unknown]
        precondition(statuses.allSatisfy { !statusText($0).isEmpty && !statusMeaning($0).symbol.isEmpty }, "Every diagnostic status must include a non-color symbol")
        renderDiagnosticItem(DiagnosticItem(
            id: "pi",
            title: "Pi CLI detection",
            status: .unavailable,
            explanation: "The pi CLI is unavailable.",
            affectedFeatures: ["Contextual Ask"],
            actionTitle: "Test Pi"
        ))
        precondition(diagnosticRows["pi"]?.detailLabel.stringValue.contains("Affects: Contextual Ask") == true, "Diagnostics must name affected capabilities")

        let originalTranscriptionState = transcriptionComponentInstaller.state()
        let transcriptionStates: [TranscriptionComponentState] = [
            .notInstalled,
            .installing(TranscriptionInstallProgress(phase: "Downloading", completedBytes: 50, totalBytes: 100)),
            .ready(URL(fileURLWithPath: "/tmp/stillmatter-ready-model")),
            .failed("Fixture installation failure")
        ]
        transcriptionStates.forEach {
            renderTranscriptionDiagnostic($0)
            precondition(diagnosticRows["localTranscription"]?.statusLabel.stringValue.isEmpty == false, "Transcription fixture state must expose status text")
            precondition(diagnosticRows["localTranscription"]?.detailLabel.stringValue.isEmpty == false, "Transcription fixture state must expose an explanation")
        }
        renderTranscriptionDiagnostic(originalTranscriptionState)
        applyAdaptiveRowLayout(forWidth: bounds.width)
    }

    private func chooseDirectory(title: String, completion: @escaping (URL) -> Void) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            completion(url)
        }
    }
}
