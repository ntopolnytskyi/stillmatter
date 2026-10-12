import AppKit

/// Draws the waveform inside a native slider, retaining its mouse, keyboard, focus and accessibility behavior.
final class MeetingWaveformCell: NSSliderCell {
    var levels: [CGFloat] = [] { didSet { controlView?.needsDisplay = true } }
    var colors: GraphiteFocusPresentation.Colors = .init(environment: .system(window: nil)) {
        didSet { controlView?.needsDisplay = true }
    }

    override func drawBar(inside rect: NSRect, flipped: Bool) {
        guard let view = controlView else { return }
        let bounds = view.bounds.insetBy(dx: 10, dy: 5)
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Sampling can fail (or be pending) even when the source is playable. Keep a
        // visible, full-width seek track instead of making the slider appear disabled.
        let samples = levels.isEmpty ? [CGFloat](repeating: 0.08, count: 96) : levels
        let slot = bounds.width / CGFloat(samples.count)
        let barWidth = max(1, min(3, slot - 2))
        let fraction = CGFloat((doubleValue - minValue) / max(maxValue - minValue, 0.01))
        for (index, level) in samples.enumerated() {
            let height = max(3, min(bounds.height, level * bounds.height))
            let bar = NSRect(x: bounds.minX + CGFloat(index) * slot + (slot - barWidth) / 2,
                             y: bounds.midY - height / 2, width: barWidth, height: height)
            (CGFloat(index) / CGFloat(samples.count) < fraction ? colors.accent : colors.textMetadata)
                .withAlphaComponent(isEnabled ? 1 : 0.5).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }

    override func drawKnob(_ knobRect: NSRect) {
        guard isEnabled else { return }
        // Keep a slim playhead when focused, clicked, or playing; focus is shown around the control.
        let bar = NSRect(x: knobRect.midX - 1, y: 4, width: 2,
                         height: max(0, (controlView?.bounds.height ?? 0) - 8))
        colors.textPrimary.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }
}
