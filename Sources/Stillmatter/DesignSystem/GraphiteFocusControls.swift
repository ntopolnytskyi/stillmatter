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

    private func configure(_ control: NSControl, identifier: String) {
        control.font = style.font
        control.controlSize = style.controlSize
        control.setAccessibilityIdentifier(identifier)
    }
}
