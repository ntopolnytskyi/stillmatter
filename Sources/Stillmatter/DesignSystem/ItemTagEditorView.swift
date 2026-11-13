import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Native, descriptive tag capsules. Ownership is displayed separately by callers.
final class ItemTagChipsView: NSTokenField {
    init(tags: [String], identifier: String) {
        super.init(frame: .zero)
        tokenStyle = .rounded
        isEditable = false; isSelectable = false; isBordered = false; drawsBackground = false
        font = GraphiteFocusPresentation.Typography.metadata
        objectValue = tags.map { "#" + $0 }
        toolTip = tags.isEmpty ? "No tags" : tags.map { "#" + $0 }.joined(separator: " ")
        setAccessibilityIdentifier(identifier); setAccessibilityLabel("Tags")
        setAccessibilityValue(toolTip)
        lineBreakMode = .byTruncatingTail
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Reused by Meeting and Todo. Persistence belongs to the supplied mutation boundary.
final class ItemTagEditorView: NSStackView {
    typealias Mutation = (ItemTagMutation, @escaping (Result<ItemTagSelection, Error>) -> Void) -> Void
    private let controls = GraphiteFocusControls()
    private let name = GraphiteFocusControls().textField(identifier: "tag-name")
    private let catalog = GraphiteFocusControls().popup(identifier: "tag-catalog")
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private let selected = NSStackView()
    private var selection: ItemTagSelection
    private let editable: Bool
    private let mutate: Mutation
    private var busy = false
    private var actions: [NSButton] = []

    init(selection: ItemTagSelection, editable: Bool, mutate: @escaping Mutation) {
        self.selection = selection; self.editable = editable; self.mutate = mutate
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = GraphiteFocusPresentation.Space.compact
        name.placeholderString = "Tag name, without #"; name.setAccessibilityLabel("Tag name")
        catalog.setAccessibilityLabel("Global tags"); catalog.target = self; catalog.action = #selector(catalogChanged)
        selected.orientation = .vertical; selected.alignment = .leading
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        scroll.documentView = selected
        selected.translatesAutoresizingMaskIntoConstraints = false
        selected.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        // graphite-focus-native-exception: bounded sheet preview scrolls long tag selections.
        scroll.heightAnchor.constraint(equalToConstant: 96).isActive = true
        addArrangedSubview(NSTextField(wrappingLabelWithString: "Tags describe the item; they do not assign an owner. Reserved AI tags are managed by approval."))
        addArrangedSubview(scroll)
        addArrangedSubview(NSTextField(labelWithString: "Choose a global tag")); addArrangedSubview(catalog)
        addAction("Add selected tag", id: "tag-add") { [weak self] in
            guard let self, let tag = self.catalog.titleOfSelectedItem else { return }
            self.run(.set(itemID: self.selection.itemID, expected: self.selection.tags,
                          tags: self.selection.tags.filter { !ItemTags.reserved.contains($0) } + [tag]))
        }
        addArrangedSubview(NSTextField(labelWithString: "Create or rename a global tag")); addArrangedSubview(name)
        let create = addAction("Create tag", id: "tag-create") { [weak self] in
            guard let self else { return }; self.run(.create(self.name.stringValue))
        }
        create.keyEquivalent = "\r"; create.keyEquivalentModifierMask = [.command]
        create.toolTip = "Create a reusable tag (Command-Return)"
        addAction("Rename selected tag globally", id: "tag-rename") { [weak self] in
            guard let self, let tag = self.catalog.titleOfSelectedItem else { return }
            self.run(.rename(tag, to: self.name.stringValue))
        }
        addAction("Delete selected tag globally", id: "tag-delete") { [weak self] in
            guard let self, let tag = self.catalog.titleOfSelectedItem else { return }; self.run(.delete(tag))
        }
        feedback.setAccessibilityIdentifier("tag-feedback"); addArrangedSubview(feedback)
        for view in arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            if !(view is NSButton) { view.widthAnchor.constraint(equalTo: widthAnchor).isActive = true }
        }
        render(preferredTag: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @discardableResult
    private func addAction(_ title: String, id: String, action: @escaping () -> Void) -> NSButton {
        let button = controls.actionButton(title, identifier: id, action: action)
        actions.append(button); addArrangedSubview(button); return button
    }
    @objc private func catalogChanged() { updateAvailability() }
    private func updateAvailability() {
        name.isEnabled = editable && !busy
        catalog.isEnabled = editable && !busy && !selection.catalog.isEmpty
        for button in selected.arrangedSubviews.compactMap({ $0 as? NSButton }) { button.isEnabled = editable && !busy }
        for button in actions {
            let id = button.accessibilityIdentifier()
            button.isEnabled = editable && !busy && (id == "tag-create" || !selection.catalog.isEmpty)
            if id == "tag-add", let tag = catalog.titleOfSelectedItem, selection.tags.contains(tag) { button.isEnabled = false }
        }
    }
    private func render(preferredTag: String?) {
        selected.arrangedSubviews.forEach { selected.removeArrangedSubview($0); $0.removeFromSuperview() }
        selected.addArrangedSubview(ItemTagChipsView(tags: selection.tags, identifier: "tag-selected-chips"))
        if selection.tags.isEmpty { selected.addArrangedSubview(NSTextField(labelWithString: "No tags on this item.")) }
        for tag in selection.tags where !ItemTags.reserved.contains(tag) {
            let remove = controls.actionButton("Remove #" + tag, identifier: "tag-remove-" + tag) { [weak self] in
                guard let self else { return }
                self.run(.set(itemID: self.selection.itemID, expected: self.selection.tags,
                    tags: self.selection.tags.filter { $0 != tag && !ItemTags.reserved.contains($0) }))
            }
            remove.isEnabled = editable && !busy; selected.addArrangedSubview(remove)
        }
        catalog.removeAllItems(); catalog.addItems(withTitles: selection.catalog)
        if let preferredTag { catalog.selectItem(withTitle: preferredTag) }
        updateAvailability()
    }
    private func run(_ mutation: ItemTagMutation) {
        guard editable, !busy else { return }
        let focused = window?.firstResponder
        let field = (focused as? NSTextView)?.delegate as? NSView ?? focused as? NSView
        var preferred = catalog.titleOfSelectedItem
        if case let .rename(_, new) = mutation { preferred = new }
        busy = true; updateAvailability()
        mutate(mutation) { [weak self] result in
            guard let self else { return }
            self.busy = false
            switch result {
            case let .success(updated): self.selection = updated; self.feedback.stringValue = "Tags saved."
            case let .failure(error): self.feedback.stringValue = "Tags not saved. Your input is preserved. " + error.localizedDescription
            }
            self.render(preferredTag: preferred)
            if let field, field.isDescendant(of: self) { self.window?.makeFirstResponder(field) }
            else { self.window?.makeFirstResponder(self.catalog) }
            NSAccessibility.post(element: self, notification: .announcementRequested,
                userInfo: [.announcement: self.feedback.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
    static func present(selection: ItemTagSelection, in window: NSWindow, source: NSView, mutate: @escaping Mutation) {
        let editor = ItemTagEditorView(selection: selection, editable: true, mutate: mutate)
        // graphite-focus-native-exception: native alert accessory needs an explicit form measure.
        editor.frame = NSRect(x: 0, y: 0, width: 420, height: 420)
        let alert = NSAlert(); alert.messageText = "Edit tags"; alert.informativeText = "Rename and delete apply across the workspace."
        alert.addButton(withTitle: "Done"); alert.accessoryView = editor
        let sourceID = source.accessibilityIdentifier()
        alert.beginSheetModal(for: window) { _ in
            DispatchQueue.main.async {
                func find(_ view: NSView) -> NSView? {
                    if view.accessibilityIdentifier() == sourceID { return view }
                    return view.subviews.compactMap(find).first
                }
                if let root = window.contentView, let target = find(root) { window.makeFirstResponder(target) }
            }
        }
    }
}
