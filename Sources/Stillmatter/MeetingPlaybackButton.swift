import AppKit

/// A native button with an explicitly sized circular face and centered playback symbol.
final class MeetingPlaybackButton: NSButton {
    private var isHovered = false
    private var isPressed = false
    private var hoverArea: NSTrackingArea?

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title = "Play" // Kept for native button state; draw(_:) renders only the icon.
        isBordered = false
        focusRingType = .default
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: focusRingMaskBounds).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let colors = GraphiteFocusPresentation.Colors(environment: .system(window: window))
        let fill = isEnabled
            ? (isPressed ? colors.accentPressed : isHovered ? colors.accentHover : colors.accent)
            : colors.surfaceRaised
        fill.setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let symbolName = title == "Pause" ? "pause.fill" : "play.fill"
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(paletteColors: [isEnabled ? colors.accentOn : colors.textDisabled])) else { return }
        let side: CGFloat = 20
        let icon = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                          width: side, height: side)
        symbol.draw(in: icon)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
            options: [.inVisibleRect, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
        super.mouseDown(with: event)
        isPressed = false
        needsDisplay = true
    }

    func updateAppearance() { needsDisplay = true }
}
