import AppKit
import Combine
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
    private var draftSubscription: AnyCancellable?
    private var editable = false
    private var feedback = ""
    private var failed = false
    private var busy = false
    private var retryDelete = false
    var confirmDelete: ((MeetingOutcomeEntry) -> Bool)?
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
        if meetingID != detail.row.id { feedback = ""; failed = false; busy = false }
        meetingID = detail.row.id; self.kind = kind
        if self.model !== model {
            self.model = model
            draftSubscription = model.$outcomeDraft.map { $0 != nil }.removeDuplicates().dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.render() }
            }
        }
        self.sources = sources
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
        button.isEnabled = enabled && editable && !busy && model?.isMutationInFlight != true
        return button
    }
    private func render() {
        let responder = window?.firstResponder
        let field = (responder as? NSTextView)?.delegate as? NSTextField ?? responder as? NSTextField
        let focusID = field?.isDescendant(of: self) == true ? field?.accessibilityIdentifier() : nil
        let selection = (responder as? NSTextView)?.selectedRange()
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        text = nil; owner = nil; type = nil; source = nil; resolved = nil
        let title = kind == .decision ? "Decisions" : "Open Items"
        let heading = NSTextField(labelWithString: title); heading.font = GraphiteFocusPresentation.Typography.sectionHeading
        addArrangedSubview(heading)
        let message = NSTextField(wrappingLabelWithString: feedback)
        message.setAccessibilityIdentifier(prefix + "-feedback"); addArrangedSubview(message)
        let add = button(kind == .decision ? "Add Decision" : "Add Open Item", "add", enabled: model?.hasDirtyDrafts != true) { [weak self] in
            guard let self else { return }; self.failed = false; self.model?.beginOutcome(MeetingOutcomeEntry(kind: self.kind)); self.render(); self.focusEditor()
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
                self?.failed = false; self?.model?.beginOutcome(entry); self?.render(); self?.focusEditor()
            })
            if entry.kind != .decision && !entry.resolved {
                actions.addArrangedSubview(button("Resolve", "resolve-" + entry.id, enabled: model?.hasDirtyDrafts != true) { [weak self] in
                    var updated = entry; updated.resolved = true
                    self?.model?.beginOutcome(updated); self?.save()
                })
            }
            actions.addArrangedSubview(NSView())
            actions.addArrangedSubview(button("Delete…", "delete-" + entry.id, enabled: model?.hasDirtyDrafts != true) { [weak self] in
                guard let self, self.askToDelete(entry) else { return }
                self.model?.beginOutcome(entry); self.save(delete: true)
            })
            sources?(entry, actions)
            addArrangedSubview(actions)
        }
        if let draft { addEditor(draft) }
        if !busy, let target = [text, owner].compactMap({ $0 }).first(where: { $0.accessibilityIdentifier() == focusID }) {
            window?.makeFirstResponder(target)
            if let selection, let editor = window?.firstResponder as? NSTextView {
                editor.setSelectedRange(NSIntersectionRange(selection, NSRange(location: 0, length: target.stringValue.utf16.count)))
            }
        }
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
            resolved.isEnabled = editable && !busy && !draft.resolved; self.resolved = resolved; addArrangedSubview(resolved)
        }
        let source = controls.popup(identifier: prefix + "-source")
        source.addItems(withTitles: ["Keep current sources", "No source"] + transcript.map { "\($0.startSeconds)s · \($0.text)" })
        source.target = self; source.action = #selector(changed); self.source = source; addArrangedSubview(source)
        let actions = NSStackView(views: [button("Save", "save") { [weak self] in self?.save() },
            button("Cancel", "cancel") { [weak self] in self?.model?.cancelOutcome(); self?.failed = false; self?.feedback = "Draft cancelled."; self?.render(); self?.focusAdd() }])
        if failed {
            actions.addArrangedSubview(button("Save my draft over latest item", "retry") { [weak self] in self?.save(retry: true) })
        }
        addArrangedSubview(actions)
        for control in [type, source].compactMap({ $0 }) { control.isEnabled = editable && !busy }
        for field in [text, owner] { field.isEnabled = editable && !busy && model?.isMutationInFlight != true }
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
    private func askToDelete(_ entry: MeetingOutcomeEntry) -> Bool {
        if let confirmDelete { return confirmDelete(entry) }
        let alert = NSAlert()
        alert.messageText = "Delete this " + (entry.kind == .decision ? "Decision?" : "Open Item?")
        alert.informativeText = "This removes the item from its canonical Markdown file. This action cannot be undone."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func save(delete: Bool = false, retry: Bool = false) {
        guard !busy else { return }
        capture()
        let origin = meetingID
        if !retry { retryDelete = delete }
        busy = true; render()
        let completion: (Result<Void, Error>) -> Void = { [weak self] result in
            guard let self, self.meetingID == origin else { return }
            self.busy = false
            switch result {
            case .success:
                self.failed = false; self.feedback = "Changes saved."
                if let detail = self.model?.detail, let model = self.model, let sources = self.sources {
                    self.configure(detail: detail, kind: self.kind, model: model, sources: sources)
                }
                self.focusAdd()
            case let .failure(error):
                self.failed = true
                self.feedback = "Save failed. Your draft is preserved. Cancel discards it. Save my draft over latest item replaces only this item, keeping other external changes. " + error.localizedDescription
                self.render(); self.focusEditor()
            }
        }
        if retry { model?.retryOutcomeWithLatest(delete: retryDelete, completion: completion) }
        else { model?.saveOutcome(delete: delete, completion: completion) }
    }
    private func focusEditor() { if let text { window?.makeFirstResponder(text) } }
    private func focusAdd() { if let button = arrangedSubviews.compactMap({ $0 as? NSButton }).first { window?.makeFirstResponder(button) } }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !busy, draft != nil else { return super.performKeyEquivalent(with: event) }
        if event.keyCode == 36 && event.modifierFlags.contains(.command) { save(); return true }
        if event.keyCode == 53 { model?.cancelOutcome(); render(); focusAdd(); return true }
        return super.performKeyEquivalent(with: event)
    }
}
