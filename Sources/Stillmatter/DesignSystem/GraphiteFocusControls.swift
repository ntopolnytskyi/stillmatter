import AppKit

/// Shared construction and semantic styling. AppKit owns activation, focus,
/// disabled controls, popup selection and checkbox state; pages own their actions.
struct GraphiteFocusControls {
    let style: GraphiteFocusControlStyle

    init(style: GraphiteFocusControlStyle = GraphiteFocusControlStyle()) {
        self.style = style
    }

    func button(_ title: String, identifier: String, target: AnyObject? = nil, action: Selector? = nil) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        configure(button, identifier: identifier)
        return button
    }

    func navigationButton(symbol: String, title: String, identifier: String, target: AnyObject, action: Selector) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            ?? NSImage(size: NSSize(width: 20, height: 20))
        let button = NSButton(image: image, target: target, action: action)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = title
        button.setAccessibilityLabel(title)
        configure(button, identifier: identifier)
        button.wantsLayer = true
        button.layer?.cornerRadius = GraphiteFocusPresentation.Radius.control
        return button
    }

    func checkbox(_ title: String, identifier: String) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        configure(button, identifier: identifier)
        return button
    }

    func textField(identifier: String) -> NSTextField {
        let field = NSTextField(string: "")
        configure(field, identifier: identifier)
        return field
    }

    func popup(identifier: String) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        configure(popup, identifier: identifier)
        return popup
    }

    func disclosure(_ title: String, identifier: String) -> NSButton {
        let button = self.button(title, identifier: identifier)
        button.setButtonType(.pushOnPushOff)
        button.isBordered = false
        button.alignment = .left
        button.font = GraphiteFocusPresentation.Typography.sectionHeading
        return button
    }

    func actionButton(_ title: String, identifier: String, action: @escaping () -> Void) -> NSButton {
        let button = GraphiteFocusActionButton(title: title, action: action)
        configure(button, identifier: identifier)
        return button
    }

    func applyCaptureColors(start: NSButton, stop: NSButton, colors: GraphiteFocusPresentation.Colors) {
        start.bezelColor = colors.accent
        start.contentTintColor = colors.accentOn
        stop.bezelColor = colors.destructive
        stop.contentTintColor = nil
    }

    func searchField(identifier: String) -> NSSearchField {
        let field = NSSearchField()
        configure(field, identifier: identifier)
        return field
    }

    func segments(_ labels: [String], identifier: String) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        configure(control, identifier: identifier)
        return control
    }

    func collectionRow(symbol: String, title: String, metadata: String,
                       emphasis: GraphiteFocusCollectionRow.Emphasis = .standard,
                       actionTitle: String = "Open", action: @escaping () -> Void) -> GraphiteFocusCollectionRow {
        let row = GraphiteFocusCollectionRow(style: style, symbol: symbol, title: title, metadata: metadata,
                                            emphasis: emphasis, actionTitle: actionTitle, action: action)
        configure(row, identifier: "collection-row")
        return row
    }

    func configure(_ control: NSControl, identifier: String) {
        control.font = style.font
        control.controlSize = style.controlSize
        control.setAccessibilityIdentifier(identifier)
    }
}
