import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Focused, editable Weekly Report review surface with inline validation and retry.
final class WeeklyReportPromptWindowController: NSWindowController, NSWindowDelegate {
    private let editor = NSTextView()
    private let contextLabel = NSTextField(wrappingLabelWithString: "")
    private let guidanceLabel = NSTextField(wrappingLabelWithString: "Edit the report before accepting it. Acceptance saves this durable report and moves terminal Todo Items transactionally. Remind next time leaves the draft pending.")
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let acceptButton = NSButton(title: "Accept", target: nil, action: nil)
    private let remindButton = NSButton(title: "Remind next time", target: nil, action: nil)
    private var draft: WeeklyReportDraft?
    private weak var returnFocusWindow: NSWindow?
    private weak var returnFocusResponder: NSResponder?
    private var isProgrammaticDismissal = false
    var onAccept: ((String) throws -> Void)?
    var onRemind: (() -> Void)?

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Weekly Report"
        panel.minSize = NSSize(width: 560, height: 420)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present(_ draft: WeeklyReportDraft) {
        if self.draft?.id != draft.id {
            editor.string = draft.text
        }
        self.draft = draft
        contextLabel.stringValue = "Weekly Report • \(draft.relativePath)"
        contextLabel.toolTip = draft.relativePath
        feedbackLabel.isHidden = true
        feedbackLabel.stringValue = ""
        guard let window = window else { return }
        if NSApp.keyWindow !== window {
            returnFocusWindow = NSApp.keyWindow
            returnFocusResponder = NSApp.keyWindow?.firstResponder
        }
        window.center()
        showWindow(nil)
        if #available(macOS 14.0, *) {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        } else {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        window.makeKeyAndOrderFront(nil)
        applyPresentation()
        window.makeFirstResponder(editor)
        DispatchQueue.main.async { [weak window, weak editor] in
            guard let window = window, let editor = editor, window.isVisible else { return }
            window.makeFirstResponder(editor)
        }
    }

    func dismiss() {
        isProgrammaticDismissal = true
        window?.orderOut(nil)
        isProgrammaticDismissal = false
        restoreInvokingFocus()
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        GraphiteFocusPresentation.applyDarkAppearance(to: contentView)
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = colors.surfaceTransient.cgColor

        let heading = NSTextField(labelWithString: "Review your Weekly Report")
        heading.font = GraphiteFocusPresentation.Typography.pageTitle
        heading.translatesAutoresizingMaskIntoConstraints = false

        contextLabel.identifier = NSUserInterfaceItemIdentifier("WeeklyReport.Context")
        contextLabel.font = GraphiteFocusPresentation.Typography.metadata
        contextLabel.textColor = colors.textMetadata
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.translatesAutoresizingMaskIntoConstraints = false

        guidanceLabel.font = GraphiteFocusPresentation.Typography.body
        guidanceLabel.textColor = colors.textSecondary
        guidanceLabel.maximumNumberOfLines = 0
        guidanceLabel.translatesAutoresizingMaskIntoConstraints = false

        feedbackLabel.identifier = NSUserInterfaceItemIdentifier("WeeklyReport.Feedback")
        feedbackLabel.font = GraphiteFocusPresentation.Typography.metadata
        feedbackLabel.textColor = colors.destructive
        feedbackLabel.maximumNumberOfLines = 0
        feedbackLabel.isHidden = true
        feedbackLabel.setAccessibilityLabel("Weekly Report validation")
        feedbackLabel.translatesAutoresizingMaskIntoConstraints = false

        editor.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.font = GraphiteFocusPresentation.Typography.longForm
        editor.textColor = colors.textPrimary
        editor.backgroundColor = colors.surfaceBase
        editor.textContainerInset = NSSize(width: GraphiteFocusPresentation.Space.dense, height: GraphiteFocusPresentation.Space.dense)
        editor.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityLabel("Editable Weekly Report content")

        let scrollView = NSScrollView()
        scrollView.documentView = editor
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        remindButton.target = self
        remindButton.action = #selector(remind)
        remindButton.keyEquivalent = "\u{1b}"
        remindButton.keyEquivalentModifierMask = []
        remindButton.setAccessibilityLabel("Remind next time about this Weekly Report")
        acceptButton.target = self
        acceptButton.action = #selector(accept)
        acceptButton.keyEquivalent = "\r"
        acceptButton.keyEquivalentModifierMask = .command
        acceptButton.contentTintColor = colors.accent
        acceptButton.setAccessibilityLabel("Accept Weekly Report")
        let actions = NSStackView(views: [remindButton, acceptButton])
        actions.orientation = .horizontal
        actions.spacing = GraphiteFocusPresentation.Space.compact
        actions.translatesAutoresizingMaskIntoConstraints = false

        [heading, contextLabel, guidanceLabel, feedbackLabel, scrollView, actions].forEach(contentView.addSubview)

        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: GraphiteFocusPresentation.Space.page),
            heading.topAnchor.constraint(equalTo: contentView.topAnchor, constant: GraphiteFocusPresentation.Space.page),
            heading.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -GraphiteFocusPresentation.Space.page),
            contextLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            contextLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            contextLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: GraphiteFocusPresentation.Space.primitive),
            guidanceLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            guidanceLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            guidanceLabel.topAnchor.constraint(equalTo: contextLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            feedbackLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            feedbackLabel.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            feedbackLabel.topAnchor.constraint(equalTo: guidanceLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            scrollView.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: feedbackLabel.bottomAnchor, constant: GraphiteFocusPresentation.Space.compact),
            scrollView.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -GraphiteFocusPresentation.Space.panel),
            actions.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            actions.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -GraphiteFocusPresentation.Space.page)
        ])
    }

    @objc private func remind() {
        dismiss()
        onRemind?()
    }

    @objc private func accept() {
        let editedText = editor.string
        guard !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showFailure("Enter Weekly Report content before accepting it.")
            window?.makeFirstResponder(editor)
            return
        }
        acceptButton.isEnabled = false
        remindButton.isEnabled = false
        do {
            try onAccept?(editedText)
            acceptButton.isEnabled = true
            remindButton.isEnabled = true
            dismiss()
        } catch {
            acceptButton.isEnabled = true
            remindButton.isEnabled = true
            showFailure("Could not save Weekly Report edits: \(error)")
            window?.makeFirstResponder(editor)
        }
    }

    private func showFailure(_ message: String) {
        feedbackLabel.stringValue = "! \(message)"
        feedbackLabel.isHidden = false
        feedbackLabel.setAccessibilityValue(message)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        applyPresentation()
    }

    func windowDidResignKey(_ notification: Notification) {
        applyPresentation()
    }

    private func applyPresentation() {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        window?.contentView?.layer?.backgroundColor = colors.surfaceTransient.cgColor
        contextLabel.textColor = colors.textMetadata
        guidanceLabel.textColor = colors.textSecondary
        feedbackLabel.textColor = colors.destructive
        editor.textColor = colors.textPrimary
        editor.backgroundColor = colors.surfaceBase
        acceptButton.contentTintColor = colors.accent
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        remind()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isProgrammaticDismissal else { return }
        restoreInvokingFocus()
    }

    private func restoreInvokingFocus() {
        guard let returnFocusWindow = returnFocusWindow else { return }
        returnFocusWindow.makeKeyAndOrderFront(nil)
        if let returnFocusResponder = returnFocusResponder {
            returnFocusWindow.makeFirstResponder(returnFocusResponder)
        }
        self.returnFocusWindow = nil
        returnFocusResponder = nil
    }
}
