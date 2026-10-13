import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

private struct ActivityStatusPresentation {
    let name: String
    let symbol: String
    let meaning: GraphiteFocusStatusMeaning

    static func forStatus(_ status: ActivityStatus) -> ActivityStatusPresentation {
        switch status {
        case .active: return ActivityStatusPresentation(name: "Active", symbol: "●", meaning: .informational)
        case .blocked: return ActivityStatusPresentation(name: "Blocked", symbol: "!", meaning: .attention)
        case .completed: return ActivityStatusPresentation(name: "Completed", symbol: "✓", meaning: .success)
        case .canceled: return ActivityStatusPresentation(name: "Canceled", symbol: "×", meaning: .destructive)
        }
    }
}

/// Precision Ledger detail canvas for Activity Items. Its paired browser is hosted by the shell's content/list region.
final class ActivityManagementView: NSView {
    override var isFlipped: Bool { true }

    let browserView = ActivityBrowserView()

    private let settingsStore: SettingsStore
    private let onChange: () -> Void
    private let onOpenSettings: () -> Void
    private var onOpenSelection: () -> Void = {}
    private var activities: [ActivityItem] = []
    private var projects: [ActivityProject] = []
    private var selectedRelativePath: String?
    private var displayedRelativePath: String?
    private var draftsByPath: [String: (output: String, log: String)] = [:]
    private var creationSheetController: ActivityCreationSheetController?

    private let headerLabel = NSTextField(labelWithString: "Activity Item")
    private let statusLabel = GraphiteFocusStatusLabel()
    private let projectLabel = NSTextField(labelWithString: "")
    private let datesLabel = NSTextField(labelWithString: "")
    private let goalLabel = NSTextField(wrappingLabelWithString: "")
    private let locationLabel = NSTextField(labelWithString: "")
    private let statusPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let outputField = NSTextField(string: "")
    private let logField = NSTextField(string: "")
    private let outputList = NSTextField(wrappingLabelWithString: "")
    private let logList = NSTextField(wrappingLabelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let detailStack = NSStackView()
    private let contentStateStack = NSStackView()
    private let outputButton = NSButton(title: "Add Output", target: nil, action: nil)
    private let logButton = NSButton(title: "Add Log Entry", target: nil, action: nil)
    private weak var contentStateMessageLabel: NSTextField?
    private var messageIsFailure = false

    init(
        settingsStore: SettingsStore,
        onChange: @escaping () -> Void,
        onOpenSettings: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.onChange = onChange
        self.onOpenSettings = onOpenSettings
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
        browserView.onSelect = { [weak self] relativePath in
            self?.selectedRelativePath = relativePath
            self?.renderSelection()
        }
        browserView.onActivate = { [weak self] in self?.onOpenSelection() }
        browserView.onCreate = { [weak self] in self?.presentCreationSheet() }
        browserView.onOpenSettings = { [weak self] in self?.onOpenSettings() }
        browserView.onRetry = { [weak self] in self?.reload() }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setOnOpenSelection(_ handler: @escaping () -> Void) {
        onOpenSelection = handler
    }

    func refresh(isVisible: Bool) {
        isHidden = !isVisible
        browserView.isHidden = !isVisible
        guard isVisible else { return }
        reload()
    }

    func applyPresentation() {
        let colors = colors
        [projectLabel, datesLabel, locationLabel].forEach { $0.textColor = colors.textMetadata }
        contentStateMessageLabel?.textColor = colors.textSecondary
        messageLabel.textColor = messageIsFailure ? colors.destructive : colors.textSecondary
        if selectedActivity() != nil { renderSelection() }
        browserView.applyPresentation()
    }

    private func buildLayout() {
        GraphiteFocusPageHeader.configureTitleLabel(headerLabel, font: GraphiteFocusPresentation.Typography.sectionHeading)
        let header = NSStackView(views: [headerLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill

        ActivityStatus.allCases.forEach { status in
            statusPopup.addItem(withTitle: status.rawValue.capitalized)
            statusPopup.lastItem?.representedObject = status.rawValue
        }
        statusPopup.target = self
        statusPopup.action = #selector(statusChanged(_:))
        statusPopup.setAccessibilityLabel("Activity Item status")

        [projectLabel, datesLabel, locationLabel].forEach {
            $0.font = GraphiteFocusPresentation.Typography.metadata
            $0.textColor = colors.textMetadata
            $0.lineBreakMode = .byTruncatingMiddle
        }
        goalLabel.font = GraphiteFocusPresentation.Typography.body
        goalLabel.maximumNumberOfLines = 0
        outputList.font = GraphiteFocusPresentation.Typography.body
        outputList.maximumNumberOfLines = 0
        logList.font = GraphiteFocusPresentation.Typography.body
        logList.maximumNumberOfLines = 0

        outputField.placeholderString = "Output or artifact reference"
        outputField.setAccessibilityLabel("New output for selected Activity Item")
        logField.placeholderString = "What happened?"
        logField.setAccessibilityLabel("New activity log entry")
        outputButton.target = self
        outputButton.action = #selector(addOutput(_:))
        logButton.target = self
        logButton.action = #selector(addLog(_:))

        GraphiteFocusPageHeader.protectActionCluster(statusPopup)
        let statusSpacer = NSView()
        statusSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let statusRow = NSStackView(views: [statusLabel, statusSpacer, statusPopup])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = GraphiteFocusPresentation.Space.compact

        let outputEntry = actionRow(field: outputField, button: outputButton)
        let logEntry = actionRow(field: logField, button: logButton)
        detailStack.orientation = .vertical
        detailStack.alignment = .width
        detailStack.spacing = GraphiteFocusPresentation.Space.dense
        [
            statusRow,
            metadataRow(projectLabel, datesLabel),
            section("Goal", body: goalLabel),
            section("Outputs", body: outputList),
            outputEntry,
            section("Activity log", body: logList),
            logEntry,
            section("Canonical location", body: locationLabel)
        ].forEach(detailStack.addArrangedSubview)

        messageLabel.font = GraphiteFocusPresentation.Typography.metadata
        messageLabel.maximumNumberOfLines = 0
        messageLabel.isHidden = true

        contentStateStack.orientation = .vertical
        contentStateStack.alignment = .leading
        contentStateStack.spacing = GraphiteFocusPresentation.Space.compact
        contentStateStack.isHidden = true

        let layout = NSStackView(views: [header, messageLabel, contentStateStack, detailStack])
        layout.orientation = .vertical
        layout.alignment = .width
        layout.spacing = GraphiteFocusPresentation.Space.panel
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: leadingAnchor),
            layout.trailingAnchor.constraint(equalTo: trailingAnchor),
            layout.topAnchor.constraint(equalTo: topAnchor),
            layout.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
        showContentState(symbol: "○", title: "No Activity Item selected", message: "Select an Activity Item from the browser or create one.")
    }

    private func metadataRow(_ first: NSView, _ second: NSView) -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [first, spacer, second])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = GraphiteFocusPresentation.Space.compact
        return row
    }

    private func section(_ title: String, body: NSView) -> NSView {
        let heading = NSTextField(labelWithString: title)
        heading.font = GraphiteFocusPresentation.Typography.control
        let stack = NSStackView(views: [heading, body])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = GraphiteFocusPresentation.Space.primitive
        return stack
    }

    private func actionRow(field: NSTextField, button: NSButton) -> NSView {
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        GraphiteFocusPageHeader.protectActionCluster(button)
        let row = NSStackView(views: [field, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = GraphiteFocusPresentation.Space.compact
        return row
    }

    private func reload(selecting relativePath: String? = nil) {
        guard let service = service() else {
            activities = []
            projects = []
            selectedRelativePath = nil
            browserView.render(.unavailable("Choose an Stillmatter root in Settings to manage Activity Items."))
            showContentState(
                symbol: "○",
                title: "Workspace unavailable",
                message: "Choose an Stillmatter root in Settings, then return to Activities.",
                actionTitle: "Open Settings",
                action: #selector(openSettings(_:))
            )
            return
        }
        do {
            let previousPath = relativePath ?? selectedRelativePath
            projects = try service.projects()
            activities = try service.all()
            selectedRelativePath = previousPath.flatMap { path in
                activities.contains(where: { $0.relativePath == path }) ? path : nil
            } ?? activities.first?.relativePath
            browserView.render(activities.isEmpty ? .empty : .items(activities), selecting: selectedRelativePath)
            renderSelection()
            clearMessage()
        } catch {
            browserView.render(.failed(String(describing: error)))
            showContentState(
                symbol: "!",
                title: "Activities could not be loaded",
                message: "The workspace could not be read. Correct the problem and try again.\n\(error)",
                actionTitle: "Try Again",
                action: #selector(retry(_:))
            )
        }
    }

    private func renderSelection() {
        guard let activity = selectedActivity() else {
            showContentState(symbol: "○", title: "No Activity Items", message: "Create an Activity Item to track work that spans days or weeks.")
            return
        }
        if displayedRelativePath != activity.relativePath {
            if let previous = displayedRelativePath {
                draftsByPath[previous] = (outputField.stringValue, logField.stringValue)
            }
            let draft = draftsByPath[activity.relativePath]
            outputField.stringValue = draft?.output ?? ""
            logField.stringValue = draft?.log ?? ""
            displayedRelativePath = activity.relativePath
        }
        detailStack.isHidden = false
        contentStateStack.isHidden = true
        GraphiteFocusPageHeader.setTitle(activity.title, on: headerLabel)
        let presentation = ActivityStatusPresentation.forStatus(activity.status)
        statusLabel.setStatus(presentation.name, meaning: presentation.meaning, colors: colors)
        statusPopup.selectItem(withTitle: activity.status.rawValue.capitalized)
        projectLabel.stringValue = "Project: \(activity.project)"
        datesLabel.stringValue = activity.endedAt.map { "Started \(activity.startedAt)  •  Ended \($0)" } ?? "Started \(activity.startedAt)"
        goalLabel.stringValue = activity.goal.isEmpty ? "No goal recorded." : activity.goal
        outputList.stringValue = activity.outputs.isEmpty ? "No outputs recorded." : activity.outputs.map { "• \($0)" }.joined(separator: "\n")
        logList.stringValue = activity.activityLog.isEmpty ? "No activity log entries." : activity.activityLog.map { "• \($0)" }.joined(separator: "\n")
        locationLabel.stringValue = activity.relativePath
        locationLabel.toolTip = activity.relativePath
        detailStack.setAccessibilityLabel("\(presentation.name) Activity Item: \(activity.title), Project \(activity.project)")
        setEditingEnabled(true)
    }

    private func showContentState(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: Selector? = nil
    ) {
        detailStack.isHidden = true
        contentStateStack.arrangedSubviews.forEach {
            contentStateStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let symbolLabel = NSTextField(labelWithString: symbol)
        symbolLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        let messageText = NSTextField(wrappingLabelWithString: message)
        messageText.font = GraphiteFocusPresentation.Typography.body
        messageText.textColor = colors.textSecondary
        messageText.maximumNumberOfLines = 0
        [symbolLabel, titleLabel, messageText].forEach(contentStateStack.addArrangedSubview)
        contentStateMessageLabel = messageText
        if let actionTitle = actionTitle, let action = action {
            contentStateStack.addArrangedSubview(NSButton(title: actionTitle, target: self, action: action))
        }
        contentStateStack.isHidden = false
        contentStateStack.setAccessibilityLabel("\(title). \(message)")
        GraphiteFocusPageHeader.setTitle("Activity Item", on: headerLabel)
        setEditingEnabled(false)
    }

    private func setEditingEnabled(_ enabled: Bool) {
        statusPopup.isEnabled = enabled
        outputField.isEnabled = enabled
        outputButton.isEnabled = enabled
        logField.isEnabled = enabled
        logButton.isEnabled = enabled
    }

    private func selectedActivity() -> ActivityItem? {
        guard let selectedRelativePath = selectedRelativePath else { return nil }
        return activities.first { $0.relativePath == selectedRelativePath }
    }

    private func service() -> ActivityService? {
        guard let root = settingsStore.settings.stillmatterRootURL else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Stillmatter", isDirectory: true)
        return ActivityService(
            workspaceRootURL: root,
            vault: WorkspaceVault(workspaceRootURL: root, appSupportRootURL: support)
        )
    }

    private func presentCreationSheet() {
        guard !projects.isEmpty else {
            let message = "Create or restore a Project before adding an Activity Item."
            browserView.showInlineFailure(message)
            showMessage(message, isFailure: true)
            return
        }
        let controller = ActivityCreationSheetController(projects: projects)
        creationSheetController = controller
        controller.onCreate = { [weak self, weak controller] draft in
            guard let self = self, let controller = controller else { return }
            guard let service = self.service() else {
                controller.showValidation("The configured Stillmatter root is unavailable.")
                return
            }
            do {
                let activity = try service.create(draft)
                self.window?.endSheet(controller.window!)
                self.creationSheetController = nil
                self.changed(activity.relativePath)
            } catch {
                controller.showValidation("Could not create Activity Item: \(error)")
            }
        }
        controller.onCancel = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            self.window?.endSheet(controller.window!)
            self.creationSheetController = nil
        }
        guard let window = window, let sheet = controller.window else { return }
        window.beginSheet(sheet)
    }

    @objc private func openSettings(_ sender: Any?) { onOpenSettings() }
    @objc private func retry(_ sender: Any?) { reload() }

    @objc private func statusChanged(_ sender: NSPopUpButton) {
        guard let service = service(), let activity = selectedActivity(),
              let raw = sender.selectedItem?.representedObject as? String,
              let status = ActivityStatus(rawValue: raw), status != activity.status else { return }
        do {
            changed(try service.updateStatus(activity, status: status).relativePath)
        } catch {
            show(error)
        }
    }

    @objc private func addOutput(_ sender: NSButton) {
        guard let service = service(), let activity = selectedActivity() else { return }
        let value = outputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            showMessage("Enter an output or artifact reference before adding it.", isFailure: true)
            return
        }
        do {
            let updated = try service.appendOutput(value, to: activity)
            outputField.stringValue = ""
            changed(updated.relativePath)
        } catch {
            show(error)
        }
    }

    @objc private func addLog(_ sender: NSButton) {
        guard let service = service(), let activity = selectedActivity() else { return }
        let value = logField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            showMessage("Enter an activity log note before adding it.", isFailure: true)
            return
        }
        do {
            let updated = try service.appendLog(value, to: activity)
            logField.stringValue = ""
            changed(updated.relativePath)
        } catch {
            show(error)
        }
    }

    private func changed(_ relativePath: String) {
        reload(selecting: relativePath)
        onChange()
    }

    private func show(_ error: Error) {
        let selectedPath = selectedRelativePath
        reload(selecting: selectedPath)
        showMessage("Could not update Activity Item: \(error)", isFailure: true)
    }

    private func showMessage(_ message: String, isFailure: Bool) {
        messageIsFailure = isFailure
        messageLabel.stringValue = isFailure ? "! \(message)" : message
        messageLabel.textColor = isFailure ? colors.destructive : colors.textSecondary
        messageLabel.isHidden = false
        messageLabel.setAccessibilityLabel(message)
    }

    private func clearMessage() {
        messageLabel.stringValue = ""
        messageLabel.isHidden = true
        messageIsFailure = false
    }

    private var colors: GraphiteFocusPresentation.Colors {
        GraphiteFocusPresentation.Colors(environment: .system(window: window))
    }

    /// Whole-shell fixture coverage for list/detail anatomy, lifecycle meaning, long content, states, and preserved editing.
    func validateFixtures() {
        let originalActivities = activities
        let originalProjects = projects
        let originalSelection = selectedRelativePath
        let originalOutputDraft = outputField.stringValue
        let originalLogDraft = logField.stringValue
        let originalDisplayedPath = displayedRelativePath
        let originalDrafts = draftsByPath
        let version = WorkspaceFileVersion(contentHash: "fixture", modificationDate: Date(timeIntervalSince1970: 0), byteCount: 1)
        let fixture: (String, String, ActivityStatus, String, [String], [String]) -> ActivityItem = { title, project, status, path, outputs, log in
            ActivityItem(
                title: title,
                project: project,
                status: status,
                startedAt: "2026-09-20T09:00:00Z",
                endedAt: status.isTerminal ? "2026-09-25T17:00:00Z" : nil,
                goal: "Deliver a durable workspace that remains readable at the Minimum Operable Window.",
                notes: "",
                outputs: outputs,
                linkedTodos: [],
                activityLog: log,
                relativePath: path,
                version: version
            )
        }
        activities = [
            fixture("Active launch planning with an intentionally long localized-looking title that must truncate at the tail before it can crowd Activity Item header controls", "Project Aurora", .active, "Activities/2026/09/active-launch-planning.md", ["[[Reports/launch-plan.md|Launch plan]]"], ["2026-09-20T12:00:00Z — Established the rollout sequence"]),
            fixture("Blocked vendor review", "General", .blocked, "Activities/2026/09/blocked-vendor-review.md", [], []),
            fixture("Completed accessibility review", "Accessibility", .completed, "Activities/2026/09/completed-accessibility-review.md", Array(repeating: "A deliberately long output reference that must wrap without covering adjacent controls", count: 8), Array(repeating: "2026-09-24T10:00:00Z — A long activity log entry used to validate readable detail flow", count: 12)),
            fixture("Canceled obsolete migration", "General", .canceled, "Activities/2026/09/canceled-obsolete-migration.md", [], [])
        ]
        projects = [
            ActivityProject(name: "General", relativePath: "Projects/General.md"),
            ActivityProject(name: "Project Aurora", relativePath: "Projects/Aurora.md"),
            ActivityProject(name: "Accessibility", relativePath: "Projects/Accessibility.md")
        ]
        selectedRelativePath = activities[0].relativePath
        browserView.render(.items(activities), selecting: selectedRelativePath)
        renderSelection()
        precondition(browserView.renderedItemCount == 4, "All Activity Item lifecycle states must appear in the browser")
        precondition(browserView.hasLeadingAlignedRowsForValidation(), "Activity row title, status, and Project must share the leading edge")
        var activationCount = 0
        let originalActivation = browserView.onActivate
        browserView.onActivate = { activationCount += 1 }
        browserView.activateSelectedItemForValidation()
        browserView.onActivate = originalActivation
        precondition(activationCount == 1, "Return activation must open the selected Activity Item without changing selection")
        precondition(statusLabel.statusText == "Active" && statusLabel.stringValue.contains("ⓘ"), "Active status must include text and a non-color in-progress cue")
        precondition(headerLabel.maximumNumberOfLines == 1 && headerLabel.lineBreakMode == .byTruncatingTail,
                     "Activity Page Header title must be a single tail-truncated line")
        precondition(headerLabel.toolTip == activities[0].title && headerLabel.accessibilityLabel() == activities[0].title,
                     "Activity Page Header title must expose the complete Activity Item title")
        precondition(projectLabel.stringValue.contains("Project Aurora") && locationLabel.stringValue.contains("Activities/"), "Detail must expose Project ownership and canonical location")

        outputField.stringValue = "Preserved output draft"
        logField.stringValue = "Preserved log draft"
        selectedRelativePath = activities[2].relativePath
        browserView.render(.items(activities), selecting: selectedRelativePath)
        renderSelection()
        frame.size.width = 480 // graphite-focus-native-exception: Minimum Operable Window detail-width fixture
        layoutSubtreeIfNeeded()
        precondition(outputField.stringValue.isEmpty && logField.stringValue.isEmpty, "Switching Activity Items must not apply another item's drafts")
        selectedRelativePath = activities[0].relativePath
        renderSelection()
        precondition(outputField.stringValue == "Preserved output draft" && logField.stringValue == "Preserved log draft", "Returning to an Activity Item must recover its in-progress additions")
        selectedRelativePath = activities[2].relativePath
        renderSelection()
        precondition(statusLabel.statusText == "Completed" && statusLabel.stringValue.contains("✓") && datesLabel.stringValue.contains("Ended"), "Completed lifecycle meaning must remain visibly successful and terminal")

        let creationFixture = ActivityCreationSheetController(projects: projects)
        creationFixture.submitForValidationFixture()
        precondition(creationFixture.hasVisibleValidation, "Creation fixture must reject an empty title with visible validation")

        browserView.render(.empty)
        showContentState(symbol: "○", title: "No Activity Items", message: "Create an Activity Item to begin.")
        precondition(browserView.renderedState == "empty" && !contentStateStack.isHidden, "Empty Activity state must provide guidance")
        browserView.render(.unavailable("Choose an Stillmatter root in Settings."))
        precondition(browserView.renderedState == "unavailable", "Missing-root state must remain explicit")
        browserView.render(.failed("Fixture read failure"))
        showMessage("Could not update Activity Item: fixture write failure", isFailure: true)
        precondition(browserView.renderedState == "failed" && !messageLabel.isHidden, "Read and write failures must remain actionable")

        activities = originalActivities
        projects = originalProjects
        selectedRelativePath = originalSelection
        displayedRelativePath = originalDisplayedPath
        draftsByPath = originalDrafts
        outputField.stringValue = originalOutputDraft
        logField.stringValue = originalLogDraft
        if activities.isEmpty {
            browserView.render(.empty)
            showContentState(symbol: "○", title: "No Activity Items", message: "Create an Activity Item to track work that spans days or weeks.")
        } else {
            browserView.render(.items(activities), selecting: selectedRelativePath)
            renderSelection()
        }
        clearMessage()
    }

    func setDraftsForValidation(output: String, log: String) {
        outputField.stringValue = output
        logField.stringValue = log
    }

    func hasDraftsForValidation(output: String, log: String) -> Bool {
        outputField.stringValue == output && logField.stringValue == log
    }

    func openSelectionForValidation() {
        onOpenSelection()
    }
}

final class ActivityBrowserView: NSView, NSTableViewDataSource, NSTableViewDelegate {
    enum State {
        case items([ActivityItem])
        case empty
        case unavailable(String)
        case failed(String)
    }

    override var isFlipped: Bool { true }
    var onSelect: ((String) -> Void)?
    var onActivate: (() -> Void)?
    var onCreate: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRetry: (() -> Void)?
    private let tableView = ActivityBrowserTableView()
    private let scrollView = NSScrollView()
    private let stateStack = NSStackView()
    private let countLabel = NSTextField(labelWithString: "")
    private weak var stateMessageLabel: NSTextField?
    private var items: [ActivityItem] = []
    private(set) var renderedState = "empty"
    var renderedItemCount: Int { items.count }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func applyPresentation() {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        countLabel.textColor = colors.textMetadata
        stateMessageLabel?.textColor = colors.textSecondary
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 64 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ActivityBrowserRow")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? ActivityBrowserCellView)
            ?? ActivityBrowserCellView(identifier: identifier)
        cell.configure(items[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard items.indices.contains(tableView.selectedRow) else { return }
        onSelect?(items[tableView.selectedRow].relativePath)
    }

    private func buildLayout() {
        let heading = NSTextField(labelWithString: "Activity Items")
        heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        let addButton = NSButton(title: "New", target: self, action: #selector(create(_:)))
        addButton.setAccessibilityLabel("Create a new Activity Item")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let headingRow = NSStackView(views: [heading, spacer, addButton])
        headingRow.orientation = .horizontal
        headingRow.alignment = .centerY

        countLabel.font = GraphiteFocusPresentation.Typography.metadata
        countLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textMetadata

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("activity"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowSizeStyle = .custom
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(activateSelection(_:))
        tableView.onReturn = { [weak self] in self?.activateSelection(nil) }
        tableView.setAccessibilityLabel("Activity Items")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        stateStack.orientation = .vertical
        stateStack.alignment = .leading
        stateStack.spacing = GraphiteFocusPresentation.Space.compact

        [headingRow, countLabel, scrollView, stateStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            headingRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphiteFocusPresentation.Space.panel),
            headingRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GraphiteFocusPresentation.Space.panel),
            headingRow.topAnchor.constraint(equalTo: topAnchor, constant: GraphiteFocusPresentation.Space.panel),
            countLabel.leadingAnchor.constraint(equalTo: headingRow.leadingAnchor),
            countLabel.trailingAnchor.constraint(equalTo: headingRow.trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: headingRow.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stateStack.leadingAnchor.constraint(equalTo: headingRow.leadingAnchor),
            stateStack.trailingAnchor.constraint(equalTo: headingRow.trailingAnchor),
            stateStack.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.page)
        ])
    }

    func render(_ state: State, selecting relativePath: String? = nil) {
        stateStack.arrangedSubviews.forEach {
            stateStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        switch state {
        case let .items(newItems):
            items = newItems
            renderedState = "items"
            countLabel.stringValue = "\(items.count) Activity Item\(items.count == 1 ? "" : "s")"
            scrollView.isHidden = false
            stateStack.isHidden = true
            tableView.reloadData()
            let index = relativePath.flatMap { path in items.firstIndex(where: { $0.relativePath == path }) } ?? 0
            if items.indices.contains(index) {
                tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                tableView.scrollRowToVisible(index)
            }
        case .empty:
            items = []
            renderedState = "empty"
            countLabel.stringValue = "No Activity Items"
            showState(symbol: "○", title: "No Activity Items", message: "Create one to track a days- or weeks-scale workstream.")
        case let .unavailable(message):
            items = []
            renderedState = "unavailable"
            countLabel.stringValue = "Workspace unavailable"
            showState(symbol: "○", title: "Workspace unavailable", message: message, actionTitle: "Open Settings", action: #selector(openSettings(_:)))
        case let .failed(message):
            items = []
            renderedState = "failed"
            countLabel.stringValue = "Activities unavailable"
            showState(symbol: "!", title: "Could not load Activities", message: message, actionTitle: "Try Again", action: #selector(retry(_:)))
        }
    }

    func showInlineFailure(_ message: String) {
        renderedState = "project-unavailable"
        countLabel.stringValue = "Project required"
        showState(symbol: "!", title: "A Project is required", message: message)
    }

    private func showState(
        symbol: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: Selector? = nil
    ) {
        scrollView.isHidden = true
        stateStack.isHidden = false
        let symbolLabel = NSTextField(labelWithString: symbol)
        symbolLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = GraphiteFocusPresentation.Typography.control
        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.font = GraphiteFocusPresentation.Typography.body
        messageLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textSecondary
        messageLabel.maximumNumberOfLines = 0
        [symbolLabel, titleLabel, messageLabel].forEach(stateStack.addArrangedSubview)
        stateMessageLabel = messageLabel
        if let actionTitle = actionTitle, let action = action {
            stateStack.addArrangedSubview(NSButton(title: actionTitle, target: self, action: action))
        }
        stateStack.setAccessibilityLabel("\(title). \(message)")
        tableView.reloadData()
    }

    func activateSelectedItemForValidation() {
        activateSelection(nil)
    }

    func hasLeadingAlignedRowsForValidation() -> Bool {
        guard let activity = items.first else { return false }
        let cell = ActivityBrowserCellView(identifier: NSUserInterfaceItemIdentifier("ActivityBrowserAlignmentFixture"))
        cell.frame = NSRect(x: 0, y: 0, width: 300, height: 64)
        cell.configure(activity)
        cell.layoutSubtreeIfNeeded()
        return cell.hasLeadingAlignedTextForValidation()
    }

    @objc private func activateSelection(_ sender: Any?) {
        guard items.indices.contains(tableView.selectedRow) else { return }
        onActivate?()
    }

    @objc private func openSettings(_ sender: Any?) { onOpenSettings?() }
    @objc private func retry(_ sender: Any?) { onRetry?() }
    @objc private func create(_ sender: NSButton) { onCreate?() }
}

private final class ActivityBrowserTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class ActivityBrowserCellView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = GraphiteFocusPresentation.Typography.rowTitle
        titleLabel.lineBreakMode = .byTruncatingTail
        statusLabel.font = GraphiteFocusPresentation.Typography.caption
        metadataLabel.font = GraphiteFocusPresentation.Typography.metadata
        [titleLabel, statusLabel, metadataLabel].forEach { $0.alignment = .left }
        metadataLabel.lineBreakMode = .byTruncatingMiddle
        metadataLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).textMetadata
        let detail = NSStackView(views: [titleLabel, statusLabel, metadataLabel])
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = GraphiteFocusPresentation.Space.primitive
        detail.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detail)
        NSLayoutConstraint.activate([
            detail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: GraphiteFocusPresentation.Space.dense),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -GraphiteFocusPresentation.Space.dense),
            detail.topAnchor.constraint(equalTo: topAnchor, constant: GraphiteFocusPresentation.Space.primitive),
            detail.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -GraphiteFocusPresentation.Space.primitive)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(_ activity: ActivityItem) {
        let presentation = ActivityStatusPresentation.forStatus(activity.status)
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        let statusColor = presentation.meaning.color(in: colors)
        statusLabel.stringValue = "\(presentation.symbol) \(presentation.name.uppercased())"
        statusLabel.textColor = statusColor
        titleLabel.stringValue = activity.title
        metadataLabel.textColor = colors.textMetadata
        metadataLabel.stringValue = activity.project
        setAccessibilityLabel("\(presentation.name) Activity Item: \(activity.title), Project \(activity.project)")
    }

    func hasLeadingAlignedTextForValidation() -> Bool {
        layoutSubtreeIfNeeded()
        let labels = [titleLabel, statusLabel, metadataLabel]
        let origins = labels.map { $0.convert(.zero, to: self).x }
        guard let firstOrigin = origins.first else { return false }
        return labels.allSatisfy { $0.alignment == .left }
            && origins.allSatisfy { abs($0 - firstOrigin) < 1 }
            && firstOrigin <= GraphiteFocusPresentation.Space.dense
    }
}

private final class ActivityCreationSheetController: NSWindowController {
    let titleField = NSTextField(string: "")
    let projectPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let goalField = NSTextField(string: "")
    private let validationLabel = NSTextField(wrappingLabelWithString: "")
    var onCreate: ((ActivityDraft) -> Void)?
    var onCancel: (() -> Void)?
    var hasVisibleValidation: Bool { !validationLabel.isHidden }

    init(projects: [ActivityProject]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.title = "New Activity Item"
        GraphiteFocusPresentation.applyDarkAppearance(to: window.contentView!)
        projects.forEach {
            projectPopup.addItem(withTitle: $0.name)
            projectPopup.lastItem?.representedObject = $0.name
        }
        projectPopup.selectItem(withTitle: "General")
        buildLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }
        titleField.placeholderString = "Activity title"
        titleField.setAccessibilityLabel("Activity Item title")
        projectPopup.setAccessibilityLabel("Project owner")
        goalField.placeholderString = "Goal (optional)"
        goalField.setAccessibilityLabel("Activity Item goal")
        validationLabel.textColor = GraphiteFocusPresentation.Colors(environment: .system(window: window)).destructive
        validationLabel.maximumNumberOfLines = 0
        validationLabel.isHidden = true
        let create = NSButton(title: "Create Activity", target: self, action: #selector(create(_:)))
        create.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, create])
        buttons.orientation = .horizontal
        buttons.spacing = GraphiteFocusPresentation.Space.compact
        let stack = NSStackView(views: [formRow("Title", titleField), formRow("Project", projectPopup), formRow("Goal", goalField), validationLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = GraphiteFocusPresentation.Space.dense
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: GraphiteFocusPresentation.Space.page),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -GraphiteFocusPresentation.Space.page),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: GraphiteFocusPresentation.Space.page),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -GraphiteFocusPresentation.Space.page)
        ])
    }

    private func formRow(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = GraphiteFocusPresentation.Typography.control
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 70).isActive = true // graphite-focus-native-exception: stable native form alignment
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = GraphiteFocusPresentation.Space.dense
        return row
    }

    func showValidation(_ message: String) {
        validationLabel.stringValue = "! \(message)"
        validationLabel.isHidden = false
        validationLabel.setAccessibilityLabel(message)
        window?.makeFirstResponder(titleField)
    }

    func submitForValidationFixture() {
        submit()
    }

    private func submit() {
        let draft = ActivityDraft(
            title: titleField.stringValue,
            project: projectPopup.selectedItem?.representedObject as? String ?? "General",
            goal: goalField.stringValue
        )
        guard !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showValidation("Enter an Activity Item title.")
            return
        }
        onCreate?(draft)
    }

    @objc private func create(_ sender: NSButton) { submit() }

    @objc private func cancel(_ sender: NSButton) { onCancel?() }
}
