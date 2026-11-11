import AppKit

/// Edits attribution only. Audition uses the reader's existing validated source seek.
final class TranscriptSpeakerEditor: NSStackView, NSTextFieldDelegate {
    let name: NSTextField
    let apply: NSButton
    let cancel: NSButton
    let audition: NSButton
    let feedback = NSTextField(wrappingLabelWithString: "")
    private var onApply: (String) -> Void = { _ in }
    private var onCancel: () -> Void = {}
    private var onAudition: () -> Void = {}

    init(controls: GraphiteFocusControls) {
        name = controls.textField(identifier: "meeting-speaker-name")
        apply = controls.button("Apply name", identifier: "meeting-speaker-apply")
        cancel = controls.button("Cancel", identifier: "meeting-speaker-cancel")
        audition = controls.button("Audition source", identifier: "meeting-speaker-audition")
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = GraphiteFocusPresentation.Space.compact
        let label = NSTextField(wrappingLabelWithString: "Speaker name · changes attribution only")
        label.font = GraphiteFocusPresentation.Typography.metadata
        name.placeholderString = "Enter a name"; name.setAccessibilityLabel("Speaker name")
        name.delegate = self
        feedback.font = GraphiteFocusPresentation.Typography.metadata
        feedback.setAccessibilityIdentifier("meeting-speaker-feedback")
        for view in [label, name, NSStackView(views: [audition, apply, cancel]), feedback] {
            addArrangedSubview(view)
            view.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor).isActive = true
        }
        name.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        apply.target = self; apply.action = #selector(applyName)
        cancel.target = self; cancel.action = #selector(cancelEdit)
        audition.target = self; audition.action = #selector(auditionSource)
        isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func edit(name: String, hasAudio: Bool, apply: @escaping (String) -> Void,
              cancel: @escaping () -> Void, audition: @escaping () -> Void) {
        self.name.stringValue = name; feedback.stringValue = ""
        onApply = apply; onCancel = cancel; onAudition = audition
        self.apply.isEnabled = true; self.cancel.isEnabled = true
        self.audition.isEnabled = hasAudio
        self.audition.toolTip = hasAudio ? "Seek and play this source" : "Retained source audio is unavailable"
        isHidden = false
        window?.makeFirstResponder(self.name)
    }
    @objc func applyName() {
        let value = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { feedback.stringValue = "Enter a speaker name."; return }
        apply.isEnabled = false; cancel.isEnabled = false
        feedback.stringValue = "Saving name…"
        onApply(value)
    }
    func finish(error: Error?) {
        apply.isEnabled = true; cancel.isEnabled = true
        if let error { feedback.stringValue = error.localizedDescription; window?.makeFirstResponder(name) }
        else { isHidden = true }
    }
    @objc func cancelEdit() { isHidden = true; onCancel() }
    @objc func auditionSource() { onAudition() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) { if cancel.isEnabled { cancelEdit() }; return true }
        if selector == #selector(NSResponder.insertNewline(_:)) { if apply.isEnabled { applyName() }; return true }
        return false
    }
}
