import AppKit
import AVFoundation

/// A native seek slider whose track displays sampled levels from the selected recording.
final class MeetingWaveformView: NSSlider {
    private var waveformCell: MeetingWaveformCell { cell as! MeetingWaveformCell }

    var levels: [CGFloat] {
        get { waveformCell.levels }
        set { waveformCell.levels = newValue }
    }
    var colors: GraphiteFocusPresentation.Colors {
        get { waveformCell.colors }
        set { waveformCell.colors = newValue }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cell = MeetingWaveformCell()
        minValue = 0
        maxValue = 1
        isContinuous = true
        focusRingType = .default
        setAccessibilityRole(.slider)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        seek(at: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        seek(at: event)
    }

    private func seek(at event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let fraction = min(1, max(0, (location.x - 10) / max(1, bounds.width - 20)))
        doubleValue = minValue + Double(fraction) * (maxValue - minValue)
        sendAction(action, to: target)
    }

    /// Sample only small windows across a track, never load a complete recording into memory.
    static func sample(path: String, duration: Double, offset: Double = 0, count: Int = 96) -> [CGFloat] {
        guard duration > 0, let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)),
              file.processingFormat.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 512) else { return [] }
        let sampleRate = file.processingFormat.sampleRate
        let channels = Int(file.processingFormat.channelCount)
        var result = [CGFloat](repeating: 0, count: count)
        for index in result.indices {
            let seconds = duration * (Double(index) + 0.5) / Double(count) - offset
            guard seconds >= 0, seconds * sampleRate < Double(file.length) else { continue }
            let frame = AVAudioFramePosition(seconds * sampleRate)
            file.framePosition = frame
            guard (try? file.read(into: buffer, frameCount: 512)) != nil, buffer.frameLength > 0 else { continue }
            let frames = Int(buffer.frameLength)
            var peak: Float = 0
            if let data = buffer.floatChannelData {
                for channel in 0..<channels {
                    for offset in 0..<frames { peak = max(peak, abs(data[channel][offset])) }
                }
            } else if let data = buffer.int16ChannelData {
                for channel in 0..<channels {
                    for offset in 0..<frames { peak = max(peak, Float(abs(Int(data[channel][offset]))) / 32768) }
                }
            }
            result[index] = CGFloat(min(1, sqrt(Double(peak)) * 1.5))
        }
        return result
    }
}
