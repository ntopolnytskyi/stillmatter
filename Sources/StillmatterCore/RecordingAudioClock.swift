import AudioToolbox
import Foundation

public struct AudioClockSpan: Codable, Equatable, Sendable {
    public var hostStart: Double
    public var hostEnd: Double
    public var startFrame: Int64
    public var endFrame: Int64
    public var sampleRate: Double
    public var generation: Int

    var fileStart: Double { Double(startFrame) / sampleRate }
    var fileEnd: Double { Double(endFrame) / sampleRate }
}

/// Receives anchors on the audio writer queue, only AFTER successful writes.
/// No locks, allocations, conversion or I/O are added to the real-time callback.
public final class RecordingAudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var spans: [AudioClockSpan] = []
    private var liveStartIndex = 0
    private var generation = 0
    private var invalidated = false
    private var fileSampleRate: Double?
    public init() {}

    public static func hostSeconds(_ ticks: UInt64) -> Double {
        Double(AudioConvertHostTimeToNanos(ticks)) / 1_000_000_000
    }
    public static var now: Double { hostSeconds(AudioGetCurrentHostTime()) }

    public func record(hostTime: UInt64, valid: Bool, startFrame: Int64, frames: Int64, sampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated, valid, frames > 0, sampleRate.isFinite, sampleRate > 0 else {
            generation += 1
            return
        }
        let start = Self.hostSeconds(hostTime)
        let end = start + Double(frames) / sampleRate
        guard start.isFinite, end > start else { generation += 1; return }
        if let fileSampleRate, fileSampleRate != sampleRate {
            // The recorder rejects incompatible reattachments. If a caller
            // nevertheless supplies one, never reinterpret old file frames.
            generation += 1
            return
        }
        fileSampleRate = sampleRate
        if let last = spans.last, start < last.hostEnd - 0.002 {
            // Retain historical file anchors for offline alignment, but a
            // backwards clock must never reuse them for a live observation.
            liveStartIndex = spans.count
            generation += 1
            return
        }
        if let last = spans.last, last.generation == generation,
           last.sampleRate == sampleRate, last.endFrame == startFrame,
           abs(last.hostEnd - start) <= 0.002,
           abs(last.hostStart + Double(startFrame - last.startFrame) / sampleRate - start) <= 0.005 {
            spans[spans.count - 1].hostEnd = end
            spans[spans.count - 1].endFrame = startFrame + frames
        } else {
            generation += 1
            // Retain the compact map for post-recording alignment. On an
            // excessively fragmented capture, missing coverage fails closed.
            guard spans.count < 65_536 else { return }
            spans.append(AudioClockSpan(hostStart: start, hostEnd: end, startFrame: startFrame,
                                        endFrame: startFrame + frames, sampleRate: sampleRate, generation: generation))
        }
    }

    public func discontinuity() {
        lock.lock()
        generation += 1
        lock.unlock()
    }

    public func invalidate() {
        lock.lock()
        invalidated = true
        lock.unlock()
    }

    public func snapshot() -> [AudioClockSpan] {
        lock.lock()
        defer { lock.unlock() }
        return Array(spans.dropFirst(liveStartIndex).suffix(64))
    }

    public func archive() -> [AudioClockSpan] {
        lock.lock()
        defer { lock.unlock() }
        return spans
    }

    /// Both bounds must lie within a single contiguous span. Never extrapolate.
    func map(hostStart: Double, hostEnd: Double) -> SpeakerTurnAnchor? {
        lock.lock()
        defer { lock.unlock() }
        guard hostStart.isFinite, hostEnd.isFinite, hostEnd > hostStart,
              let span = spans.dropFirst(liveStartIndex).last(where: {
                  $0.hostStart <= hostStart && $0.hostEnd >= hostEnd
              }) else { return nil }
        return SpeakerTurnAnchor(start: Double(span.startFrame) / span.sampleRate + hostStart - span.hostStart,
                                 end: Double(span.startFrame) / span.sampleRate + hostEnd - span.hostStart)
    }
}

public struct RecordingAudioTiming: Codable, Sendable {
    public static let fileName = "audio-timing.json"
    public var version = 1
    public var microphone: [AudioClockSpan]
    public var system: [AudioClockSpan]

    public init(microphone: [AudioClockSpan], system: [AudioClockSpan]) {
        self.microphone = microphone
        self.system = system
    }

    func nextBoundary(after position: Double) -> Double? {
        var boundary = Double.infinity
        var containing: AudioClockSpan?
        for span in microphone where span.sampleRate > 0 {
            let start = span.fileStart
            let end = span.fileEnd
            for value in [start, end] where value.isFinite && value > position + 0.000_01 {
                boundary = min(boundary, value)
            }
            if start <= position + 0.000_01 && end > position + 0.000_01 { containing = span }
        }
        if let mic = containing, mic.hostEnd > mic.hostStart {
            let origin = mic.fileStart
            let duration = mic.fileEnd - origin
            for remote in system {
                for host in [remote.hostStart, remote.hostEnd] where host >= mic.hostStart && host <= mic.hostEnd {
                    let value = origin + (host - mic.hostStart) / (mic.hostEnd - mic.hostStart) * duration
                    if value > position + 0.000_01 { boundary = min(boundary, value) }
                }
            }
        }
        return boundary.isFinite ? boundary : nil
    }

    /// Map both bounds through one continuous span on each track. Padding and
    /// device gaps have no anchors, so this never extrapolates across them.
    func referenceRange(start: Double, end: Double) -> SpeakerTurnAnchor? {
        guard start.isFinite, end.isFinite, end > start,
              let mic = microphone.first(where: { Self.covers($0, start: start, end: end) }) else { return nil }
        let micStart = mic.fileStart
        let micDuration = mic.fileEnd - micStart
        guard micDuration > 0, mic.hostEnd > mic.hostStart else { return nil }
        let hostStart = mic.hostStart + (start - micStart) / micDuration * (mic.hostEnd - mic.hostStart)
        let hostEnd = mic.hostStart + (end - micStart) / micDuration * (mic.hostEnd - mic.hostStart)
        guard let remote = system.first(where: { $0.hostStart <= hostStart && $0.hostEnd >= hostEnd
            && $0.sampleRate > 0 && $0.hostEnd > $0.hostStart }) else { return nil }
        let scale = (remote.fileEnd - remote.fileStart) / (remote.hostEnd - remote.hostStart)
        let origin = remote.fileStart
        let range = SpeakerTurnAnchor(start: origin + (hostStart - remote.hostStart) * scale,
                                      end: origin + (hostEnd - remote.hostStart) * scale)
        guard range.isValid, abs(range.duration / (end - start) - 1) < 0.002 else { return nil }
        return range
    }

    private static func covers(_ span: AudioClockSpan, start: Double, end: Double) -> Bool {
        span.sampleRate > 0 && span.sampleRate.isFinite && span.hostStart.isFinite && span.hostEnd.isFinite
            && span.fileStart <= start && span.fileEnd >= end
    }
}
