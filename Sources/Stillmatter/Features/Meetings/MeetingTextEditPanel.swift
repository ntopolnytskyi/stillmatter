import AppKit

/// One sheet for either editable Meeting text field. The owning view handles versioned saves;
/// this module owns the modal keyboard/focus lifecycle and never changes Meeting selection.
@MainActor
final class MeetingTextEditPanel: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let editor = NSTextView(frame: .zero)
    private let titleLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let reloadButton = NSButton(title: "Reload Latest", target: nil, action: nil)
    private var parent: NSWindow?
    private var onChange: ((String) -> Void)?
    private var onSave: ((String) -> Void)?
    private var onCancel: (() -> Void)?
    private var onReload: (() -> Void)?

    var isOpen: Bool { parent != nil }
    var text: String { editor.string }

    override init() {
        super.init()
        panel.title = "Edit Meeting text"
        panel.isReleasedWhenClosed = false
        panel.maxSize = NSSize(width: 640, height: 480)
        let content = NSView()
        panel.contentView = content
        titleLabel.font = GraphiteFocusPresentation.Typography.sectionHeading
        contextLabel.font = GraphiteFocusPresentation.Typography.metadata
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.maximumNumberOfLines = 1
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        editor.font = GraphiteFocusPresentation.Typography.body
        editor.textColor = .labelColor
        editor.backgroundColor = .textBackgroundColor
        editor.isRichText = false
        editor.setAccessibilityIdentifier("meeting-text-editor")
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainerInset = NSSize(width: GraphiteFocusPresentation.Space.dense,
                                           height: GraphiteFocusPresentation.Space.dense)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = editor
        scroll.setAccessibilityIdentifier("meeting-text-modal-editor")
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        saveButton.target = self
        saveButton.setAccessibilityIdentifier("meeting-text-save")
        cancelButton.setAccessibilityIdentifier("meeting-text-cancel")
        reloadButton.setAccessibilityIdentifier("meeting-text-reload")
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.toolTip = "Save (Command-Return)"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        reloadButton.target = self
        reloadButton.action = #selector(reload)
        reloadButton.isHidden = true
        let actions = NSStackView(views: [reloadButton, NSView(), cancelButton, saveButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = GraphiteFocusPresentation.Space.compact
        let layout = NSStackView(views: [titleLabel, contextLabel, scroll, errorLabel, actions])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = GraphiteFocusPresentation.Space.compact
        layout.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: GraphiteFocusPresentation.Space.page),
            layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -GraphiteFocusPresentation.Space.page),
            layout.topAnchor.constraint(equalTo: content.topAnchor, constant: GraphiteFocusPresentation.Space.page),
            layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -GraphiteFocusPresentation.Space.page),
            contextLabel.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: layout.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            actions.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(textChanged(_:)),
                                               name: NSText.didChangeNotification, object: editor)
    }

    func present(over window: NSWindow, field: String, meeting: String, text: String,
                 onChange: @escaping (String) -> Void,
                 onSave: @escaping (String) -> Void,
                 onCancel: @escaping () -> Void,
                 onReload: @escaping () -> Void) {
        guard !isOpen else { return }
        titleLabel.stringValue = "Edit \(field)"
        contextLabel.stringValue = meeting
        editor.setAccessibilityLabel("Edit Meeting \(field)")
        editor.string = text
        errorLabel.isHidden = true
        reloadButton.isHidden = true
        saveButton.isEnabled = true
        cancelButton.isEnabled = true
        self.onChange = onChange
        self.onSave = onSave
        self.onCancel = onCancel
        self.onReload = onReload
        parent = window
        window.beginSheet(panel)
        panel.makeFirstResponder(editor)
    }

    func finish() {
        guard let parent else { return }
        parent.endSheet(panel)
        panel.orderOut(nil)
        self.parent = nil
        onChange = nil
        onSave = nil
        onCancel = nil
        onReload = nil
    }

    func setSaving(_ saving: Bool) {
        saveButton.isEnabled = !saving
        cancelButton.isEnabled = !saving
        reloadButton.isEnabled = !saving
    }

    func showError(_ message: String, conflict: Bool) {
        setSaving(false)
        errorLabel.stringValue = message
        errorLabel.isHidden = false
        reloadButton.isHidden = !conflict
        panel.makeFirstResponder(editor)
    }

    func showLatest(_ text: String) {
        editor.string = text
        errorLabel.isHidden = true
        reloadButton.isHidden = true
        panel.makeFirstResponder(editor)
    }

    @objc private func textChanged(_ notification: Notification) { onChange?(editor.string) }
    @objc private func save() { onSave?(editor.string) }
    @objc private func cancel() { onCancel?() }
    @objc private func reload() { onReload?() }
}
