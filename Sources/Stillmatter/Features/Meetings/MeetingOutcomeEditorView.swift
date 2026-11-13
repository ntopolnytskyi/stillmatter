import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

/// Decisions remain in Summary; the same editor serves the dedicated Open Items tab.
final class MeetingOutcomeEditorView: NSStackView, NSTextFieldDelegate {
    private let controls = GraphiteFocusControls()
    private var entries: [MeetingOutcomeEntry] = []
    private var transcript: [MeetingTranscriptSegment] = []
    private var kind: MeetingOutcomeKind = .decision
    private var model: MeetingDetailModel?
    private var editable = false
    private var feedback = ""
    private var meetingID: String?
    private var text: NSTextField?
    private var owner: NSTextField?
    private var type: NSPopUpButton?
    private var source: NSPopUpButton?
    private var resolved: NSButton?
    private var sources: ((MeetingOutcomeEntry, NSStackView) -> Void)?
    private var prefix: String { kind == .decision ? "meeting-decisions" : "meeting-open-items" }

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = GraphiteFocusPresentation.Space.compact
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(detail: MeetingBrowserDetail, kind: MeetingOutcomeKind, model: MeetingDetailModel,
                   sources: @escaping (MeetingOutcomeEntry, NSStackView) -> Void) {
        if meetingID != detail.row.id { feedback = "" }
        meetingID = detail.row.id; self.kind = kind; self.model = model; self.sources = sources
        transcript = detail.transcript
        editable = !detail.row.isArchived
        do {
            entries = try MeetingOutcomeDocument.entries(in: kind == .decision ? detail.summary?.decisions ?? "" : detail.summary?.openQuestions ?? "", defaultKind: kind)
        } catch { entries = []; feedback = error.localizedDescription; editable = false }
        render()
    }

    private var draft: MeetingOutcomeEntry? {
        guard let entry = model?.outcomeDraft?.entry, (entry.kind == .decision) == (kind == .decision) else { return nil }
        return entry
    }
    private func button(_ title: String, _ suffix: String, enabled: Bool = true, action: @escaping () -> Void) -> NSButton {
        let button = controls.actionButton(title, identifier: prefix + "-" + suffix, action: action)
        button.isEnabled = enabled && editable && model?.isMutationInFlight != true
        return button
    }
    private func render() {
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        text = nil; owner = nil; type = nil; source = nil; resolved = nil
        let title = kind == .decision ? "Decisions" : "Open Items"
        let heading = NSTextField(labelWithString: title); heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        addArrangedSubview(heading)
        let message = NSTextField(wrappingLabelWithString: feedback)
        message.setAccessibilityIdentifier(prefix + "-feedback"); addArrangedSubview(message)
        let add = button(kind == .decision ? "Add Decision" : "Add Open Item", "add", enabled: model?.hasDirtyDrafts != true) { [weak self] in
            guard let self else { return }; self.model?.beginOutcome(MeetingOutcomeEntry(kind: self.kind)); self.render(); self.focusEditor()
        }
        addArrangedSubview(add)
        if entries.isEmpty { addArrangedSubview(NSTextField(labelWithString: "No " + title + " yet.")) }
        for entry in entries {
            let label = NSTextField(wrappingLabelWithString: entry.text + "\n" + entry.kind.rawValue.capitalized +
                (entry.kind == .decision ? "" : entry.resolved ? " · Resolved" : " · Open") + " · " + (entry.owner ?? "Unknown owner"))
            label.setAccessibilityIdentifier(prefix + "-row-" + entry.id)
            addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
            let actions = NSStackView()
            actions.addArrangedSubview(button("Edit", "edit-" + entry.id, enabled: model?.hasDirtyDrafts != true) { [weak self] in
                self?.model?.beginOutcome(entry); self?.render(); self?.focusEditor()
            })
            if entry.kind != .decision && !entry.resolved {
                actions.addArrangedSubview(button("Resolve", "resolve-" + entry.id, enabled: model?.hasDirtyDrafts != true) { [weak self] in
                    var updated = entry; updated.resolved = true
                    self?.model?.beginOutcome(updated); self?.save()
                })
            }
            actions.addArrangedSubview(button("Delete", "delete-" + entry.id, enabled: model?.hasDirtyDrafts != true) { [weak self] in
                self?.model?.beginOutcome(entry); self?.save(delete: true)
            })
            sources?(entry, actions)
            addArrangedSubview(actions)
        }
        if let draft { addEditor(draft) }
    }
    private func addEditor(_ draft: MeetingOutcomeEntry) {
        let text = controls.textField(identifier: prefix + "-text"); text.stringValue = draft.text; text.delegate = self
        let owner = controls.textField(identifier: prefix + "-owner"); owner.stringValue = draft.owner ?? ""; owner.delegate = self
        self.text = text; self.owner = owner
        for (label, field) in [("Text", text), ("Owner (empty means unknown)", owner)] {
            addArrangedSubview(NSTextField(labelWithString: label)); addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        if kind != .decision {
            let type = controls.popup(identifier: prefix + "-type"); type.addItems(withTitles: ["Question", "Issue"])
            type.selectItem(at: draft.kind == .issue ? 1 : 0); type.target = self; type.action = #selector(changed)
            self.type = type; addArrangedSubview(type)
            let resolved = button("Resolved", "resolved") { [weak self] in self?.capture() }
            resolved.setButtonType(.switch); resolved.state = draft.resolved ? .on : .off
            resolved.isEnabled = editable && !draft.resolved; self.resolved = resolved; addArrangedSubview(resolved)
        }
        let source = controls.popup(identifier: prefix + "-source")
        source.addItems(withTitles: ["Keep current sources", "No source"] + transcript.map { "\($0.startSeconds)s · \($0.text)" })
        source.target = self; source.action = #selector(changed); self.source = source; addArrangedSubview(source)
        let actions = NSStackView(views: [button("Save", "save") { [weak self] in self?.save() },
            button("Cancel", "cancel") { [weak self] in self?.model?.cancelOutcome(); self?.feedback = "Draft cancelled."; self?.render(); self?.focusAdd() }])
        addArrangedSubview(actions)
        for field in [text, owner] { field.isEnabled = editable && model?.isMutationInFlight != true }
    }
    func controlTextDidChange(_ obj: Notification) { capture() }
    @objc private func changed() { capture() }
    private func capture() {
        guard var draft, let text, let owner else { return }
        draft.text = text.stringValue; draft.owner = owner.stringValue.isEmpty ? nil : owner.stringValue
        if let type { draft.kind = type.indexOfSelectedItem == 1 ? .issue : .question }
        if let resolved { draft.resolved = resolved.state == .on }
        if let source {
            if source.indexOfSelectedItem == 1 { draft.citations = [] }
            if source.indexOfSelectedItem >= 2 {
                let segment = transcript[source.indexOfSelectedItem - 2]
                draft.citations = [.init(segmentID: segment.id, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds)]
            }
        }
        model?.updateOutcome(draft)
    }
    private func save(delete: Bool = false) {
        capture()
        let origin = meetingID
        model?.saveOutcome(delete: delete) { [weak self] result in
            guard let self, self.meetingID == origin else { return }
            switch result {
            case .success:
                self.feedback = "Changes saved."
                if let detail = self.model?.detail { self.configure(detail: detail, kind: self.kind, model: self.model!, sources: self.sources!) }
                self.focusAdd()
            case let .failure(error):
                self.feedback = "Save failed. Your draft is preserved. Cancel to load the latest version, then retry. " + error.localizedDescription
                self.render(); self.focusEditor()
            }
        }
    }
    private func focusEditor() { if let text { window?.makeFirstResponder(text) } }
    private func focusAdd() { if let button = arrangedSubviews.compactMap({ $0 as? NSButton }).first { window?.makeFirstResponder(button) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard draft != nil else { return super.performKeyEquivalent(with: event) }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { save(); return true }
        if event.keyCode == 53 { model?.cancelOutcome(); render(); focusAdd(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
