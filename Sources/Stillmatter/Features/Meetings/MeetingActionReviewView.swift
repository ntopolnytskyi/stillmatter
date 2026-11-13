import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Meeting-scoped approval and canonical checkbox editing. Drafts survive refresh
/// and failed saves; mutations remain owned by the serialized Meeting executor.
final class MeetingActionReviewView: NSStackView, NSTextFieldDelegate, NSMenuDelegate {
    struct Draft {
        var text: String
        var owner: String
        var due: String
        var status: TodoStatus
    }
    private let controls = GraphiteFocusControls()
    private var drafts: [String: Draft] = [:]
    private var draftBases: [String: MeetingReviewItem] = [:]
    private var fields: [String: (NSTextField, NSTextField, NSTextField, NSPopUpButton)] = [:]
    private var items: [MeetingReviewItem] = []
    private var meetingID: String?
    private var busy = false
    private var editable = false
    private var feedback = ""
    private var preferredFocusID: String?
    private var reviewFocusIndex: Int?
    private var review: (([MeetingReviewItem], Bool, @escaping (Result<Void, Error>) -> Void) -> Void)?
    private var save: ((MeetingReviewItem, Draft, @escaping (Result<Void, Error>) -> Void) -> Void)?
    private var tags: ((MeetingReviewItem, NSButton) -> Void)?
    private var sources: ((MeetingReviewItem, NSStackView) -> Void)?

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = GraphiteFocusPresentation.Space.compact
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(meetingID: String, items: [MeetingReviewItem], editable: Bool,
                   review: @escaping ([MeetingReviewItem], Bool, @escaping (Result<Void, Error>) -> Void) -> Void,
                   save: @escaping (MeetingReviewItem, Draft, @escaping (Result<Void, Error>) -> Void) -> Void,
                   tags: ((MeetingReviewItem, NSButton) -> Void)? = nil,
                   sources: @escaping (MeetingReviewItem, NSStackView) -> Void) {
        if self.meetingID != meetingID { drafts = [:]; draftBases = [:]; feedback = ""; busy = false; preferredFocusID = nil; reviewFocusIndex = nil }
        self.meetingID = meetingID
        self.items = items.sorted { left, right in
            func rank(_ item: MeetingReviewItem) -> String { item.owner == "me" ? "0" : item.hasOwner ? "1" + (item.owner ?? "") : "2" }
            return rank(left) < rank(right)
        }
        self.editable = editable
        self.review = review; self.save = save; self.tags = tags; self.sources = sources
        render()
    }

    func controlTextDidChange(_ obj: Notification) { captureDrafts(); updateApprovalAvailability() }

    private func captureDrafts() {
        for (id, row) in fields {
            let status: TodoStatus = [.open, .blocked, .done][row.3.indexOfSelectedItem]
            let draft = Draft(text: row.0.stringValue, owner: row.1.stringValue, due: row.2.stringValue, status: status)
            guard let item = items.first(where: { $0.id == id }) else { continue }
            if draft.text == ItemTags.removingTags(from: item.text) && draft.owner == (item.owner ?? "") && draft.due == (item.dueDate ?? "") && draft.status == item.status {
                drafts.removeValue(forKey: id); draftBases.removeValue(forKey: id)
            } else {
                if draftBases[id] == nil { draftBases[id] = item }
                drafts[id] = draft
            }
        }
    }
    private func isDirty(_ item: MeetingReviewItem) -> Bool {
        guard let draft = drafts[item.id] else { return false }
        return draft.text != ItemTags.removingTags(from: item.text) || draft.owner != (item.owner ?? "") || draft.due != (item.dueDate ?? "") || draft.status != item.status
    }
    private func updateApprovalAvailability() {
        for button in allButtons() {
            if let item = items.first(where: { button.accessibilityIdentifier() == "meeting-item-edit-tags-" + $0.id }) {
                button.isEnabled = editable && !busy && !isDirty(item)
            }
            if let id = button.identifier?.rawValue, id.hasPrefix("reload:"),
               let item = items.first(where: { "reload:" + $0.id == id }) {
                button.isEnabled = editable && !busy && isDirty(item)
            }
            if button.identifier?.rawValue == "accept", let id = button.toolTip,
               let item = items.first(where: { $0.id == id }) {
                button.isEnabled = editable && !busy && item.hasOwner && !isDirty(item)
            }
            if button.identifier?.rawValue == "batch", let group = button.toolTip {
                button.isEnabled = editable && !busy && !pending(group).isEmpty && !items.contains(where: isDirty)
            }
        }
    }
    private func allButtons() -> [NSButton] {
        func walk(_ view: NSView) -> [NSButton] { (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(walk) }
        return subviews.flatMap(walk)
    }
    private func pending(_ group: String) -> [MeetingReviewItem] {
        items.filter { $0.isPending && $0.hasOwner && (group == "mine" ? $0.owner == "me" : $0.owner != "me") }
    }
    private func render() {
        preferredFocusID = focusedIdentifier() ?? preferredFocusID
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }; fields = [:]
        let message = FocusableMeetingEmptyState(wrappingLabelWithString: feedback.isEmpty ? "Save edits before approval. Assign unknown owners explicitly. Use Tab and Space to reach and activate actions." : feedback)
        message.setAccessibilityIdentifier("meeting-actions-feedback")
        addArrangedSubview(message)
        let batches = NSStackView()
        for (group, title) in [("mine", "Accept all mine"), ("others", "Accept all others")] {
            let button = controls.actionButton(title, identifier: "meeting-actions-accept-" + group) { [weak self] in
                guard let self else { return }; self.runReview(self.pending(group), accept: true)
            }
            button.identifier = NSUserInterfaceItemIdentifier("batch"); button.toolTip = group
            batches.addArrangedSubview(button)
        }
        batches.menu = actionMenu(batches)
        addArrangedSubview(batches)
        if items.isEmpty { addArrangedSubview(NSTextField(labelWithString: "No Action Items yet.")) }
        let owners = ["me"] + Set(items.compactMap(\.owner).filter { $0 != "me" && !$0.isEmpty && $0 != "unknown" }).sorted() + [""]
        for owner in owners {
            let group = items.filter { owner.isEmpty ? !$0.hasOwner : $0.owner == owner }
            guard !group.isEmpty else { continue }
            addArrangedSubview(NSTextField(labelWithString: owner == "me" ? "My actions" : owner.isEmpty ? "Unknown owner — assign before approval" : owner))
            for item in group { addItem(item) }
        }
        updateApprovalAvailability()
        restoreFocus()
    }
    private func addItem(_ item: MeetingReviewItem) {
        let draft = drafts[item.id] ?? Draft(text: ItemTags.removingTags(from: item.text), owner: item.owner ?? "", due: item.dueDate ?? "", status: item.status)
        let text = controls.textField(identifier: "meeting-item-text-" + item.id); text.stringValue = draft.text
        let owner = controls.textField(identifier: "meeting-item-owner-" + item.id); owner.stringValue = draft.owner; owner.placeholderString = "me or a person's name"
        let due = controls.textField(identifier: "meeting-item-due-" + item.id); due.stringValue = draft.due; due.placeholderString = "YYYY-MM-DD or empty"
        for field in [text, owner, due] { field.delegate = self; field.isEnabled = editable && !busy }
        let status = controls.popup(identifier: "meeting-item-status-" + item.id)
        status.addItems(withTitles: ["Open", "Postponed", "Completed"])
        status.selectItem(at: draft.status == .done ? 2 : draft.status == .blocked ? 1 : 0)
        status.isEnabled = editable && !busy && item.review == "approved" && item.status != .done
        status.target = self; status.action = #selector(statusChanged)
        fields[item.id] = (text, owner, due, status)
        text.setAccessibilityLabel("Action Item text")
        owner.setAccessibilityLabel("Action Item owner")
        due.setAccessibilityLabel("Action Item due date")
        status.setAccessibilityLabel("Action Item status")
        let label = NSTextField(wrappingLabelWithString: item.review + " · " + item.origin + (item.dueDate == nil ? " · No confirmed due date" : ""))
        let stack = NSStackView(views: [label, NSTextField(labelWithString: "Task"), text, NSTextField(labelWithString: "Owner"), owner,
            NSTextField(labelWithString: "Due"), due, NSTextField(labelWithString: "Status"), status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = GraphiteFocusPresentation.Space.compact
        let chips = ItemTagChipsView(tags: item.tags, identifier: "meeting-item-tags-" + item.id)
        stack.addArrangedSubview(chips)
        chips.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        let actions = NSStackView()
        if tags != nil {
            let button = controls.actionButton("Edit tags", identifier: "meeting-item-edit-tags-" + item.id) { [weak self] in
                guard let self, let button = self.allButtons().first(where: { $0.accessibilityIdentifier() == "meeting-item-edit-tags-" + item.id }) else { return }
                self.tags?(item, button)
            }
            button.isEnabled = editable && !busy && !isDirty(item)
            actions.addArrangedSubview(button)
        }
        let saveButton = controls.actionButton("Save", identifier: "meeting-item-save-" + item.id) { [weak self] in self?.saveItem(item) }
        saveButton.isEnabled = editable && !busy
        actions.addArrangedSubview(saveButton)
        if item.isPending {
            let accept = controls.actionButton("Accept", identifier: "meeting-item-accept-" + item.id) { [weak self] in self?.runReview([item], accept: true) }
            accept.identifier = NSUserInterfaceItemIdentifier("accept"); accept.toolTip = item.id
            actions.addArrangedSubview(accept)
            let reject = controls.actionButton("Reject", identifier: "meeting-item-reject-" + item.id) { [weak self] in self?.runReview([item], accept: false) }
            reject.isEnabled = editable && !busy; actions.addArrangedSubview(reject)
        }
        let reload = controls.actionButton("Reload saved item", identifier: "meeting-item-reload-" + item.id) { [weak self] in
            self?.drafts.removeValue(forKey: item.id); self?.draftBases.removeValue(forKey: item.id); self?.feedback = "Loaded the saved item."; self?.render()
        }
        reload.identifier = NSUserInterfaceItemIdentifier("reload:" + item.id)
        reload.isEnabled = editable && !busy && isDirty(item); actions.addArrangedSubview(reload)
        sources?(item, actions)
        actions.menu = actionMenu(actions)
        stack.addArrangedSubview(actions); addArrangedSubview(stack)
        stack.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        text.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    @objc private func statusChanged() { captureDrafts(); updateApprovalAvailability() }
    private func saveItem(_ item: MeetingReviewItem) {
        guard !busy, editable else { return }; captureDrafts()
        let draft = drafts[item.id] ?? Draft(text: ItemTags.removingTags(from: item.text), owner: item.owner ?? "", due: item.dueDate ?? "", status: item.status)
        preferredFocusID = focusedIdentifier() ?? "meeting-item-save-" + item.id
        let origin = meetingID
        busy = true; render()
        save?(draftBases[item.id] ?? item, draft) { [weak self] result in
            guard self?.meetingID == origin else { return }
            self?.finish(result, cleared: [item.id])
        }
    }
    private func runReview(_ selected: [MeetingReviewItem], accept: Bool) {
        guard !busy, editable, !selected.isEmpty else { return }
        captureDrafts()
        preferredFocusID = focusedIdentifier() ?? "meeting-item-accept-" + selected[0].id
        reviewFocusIndex = items.firstIndex { $0.id == selected[0].id }
        let origin = meetingID; busy = true; render()
        review?(selected, accept) { [weak self] result in
            guard self?.meetingID == origin else { return }
            self?.finish(result, cleared: [])
        }
    }
    private func actionMenu(_ stack: NSStackView) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false; menu.delegate = self
        for button in stack.arrangedSubviews.compactMap({ $0 as? NSButton }) {
            let item = NSMenuItem(title: button.title, action: #selector(activateMenu(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = button; item.isEnabled = button.isEnabled
            menu.addItem(item)
        }
        return menu
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items { item.isEnabled = (item.representedObject as? NSButton)?.isEnabled == true }
    }
    @objc private func activateMenu(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? NSButton, button.isEnabled else { return }
        button.performClick(nil)
    }
    private func focusedIdentifier() -> String? {
        let responder = window?.firstResponder
        let view = (responder as? NSTextView)?.delegate as? NSView ?? responder as? NSView
        guard let view, view.isDescendant(of: self) else { return nil }
        return view.accessibilityIdentifier()
    }
    private func restoreFocus() {
        guard !busy, let preferredFocusID else { return }
        func find(_ view: NSView) -> NSView? {
            if view.accessibilityIdentifier() == preferredFocusID { return view }
            return view.subviews.compactMap(find).first
        }
        if let target = find(self), (target as? NSControl)?.isEnabled != false {
            window?.makeFirstResponder(target)
        }
    }
    private func finish(_ result: Result<Void, Error>, cleared: [String]) {
        busy = false
        switch result {
        case .success: cleared.forEach { drafts.removeValue(forKey: $0); draftBases.removeValue(forKey: $0) }; feedback = "Changes saved."
        case let .failure(error): feedback = "Save failed. Your edits remain available. " + error.localizedDescription
        }
        render()
        if case .success = result, let index = reviewFocusIndex {
            let pending = items.enumerated().filter { $0.element.isPending && $0.element.hasOwner }
            let next = pending.first { $0.offset >= index } ?? pending.last
            preferredFocusID = next.map { "meeting-item-accept-" + $0.element.id } ?? "meeting-actions-feedback"
        }
        reviewFocusIndex = nil
        restoreFocus()
        NSAccessibility.post(element: self, notification: .announcementRequested,
            userInfo: [.announcement: feedback, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
