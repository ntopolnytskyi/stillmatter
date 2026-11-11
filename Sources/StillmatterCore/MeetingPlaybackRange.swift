/// A contiguous range of source audio placed on the shared Meeting timeline.
public struct MeetingPlaybackRange: Equatable, Sendable {
    public let fileStart: Double
    public let fileEnd: Double
    public let timelineStart: Double

    public init(fileStart: Double, fileEnd: Double, timelineStart: Double) {
        self.fileStart = fileStart
        self.fileEnd = fileEnd
        self.timelineStart = timelineStart
    }

    public var timelineEnd: Double { timelineStart + (fileEnd - fileStart) }

    /// Keep capture gaps out of the highlight for a phrase that crosses one.
    static func project(_ source: Range<Double>, through ranges: [Self]) -> [Range<Double>] {
        var first = 0
        var end = ranges.count
        while first < end {
            let middle = first + (end - first) / 2
            if ranges[middle].fileEnd <= source.lowerBound {
                first = middle + 1
            } else {
                end = middle
            }
        }
        if source.isEmpty, let range = first < ranges.count ? ranges[first] : ranges.last {
            let point = range.timelineStart + (source.lowerBound - range.fileStart)
            return [point..<point]
        }
        var projected: [Range<Double>] = []
        for range in ranges[first...] {
            if range.fileStart >= source.upperBound { break }
            let lower = range.timelineStart + (max(source.lowerBound, range.fileStart) - range.fileStart)
            let upper = range.timelineStart + (min(source.upperBound, range.fileEnd) - range.fileStart)
            if lower < upper { projected.append(lower..<upper) }
        }
        return projected
    }

    /// Use the recorded frame lengths for audio and the host clock for gaps.
    /// Small anchor differences are tolerated, as in the capture clock itself.
    static func trackRanges(_ spans: [AudioClockSpan], duration: Double) -> [Self]? {
        guard let first = spans.first else {
            return [Self(fileStart: 0, fileEnd: duration, timelineStart: 0)]
        }
        let tolerance = 0.005
        var ranges: [Self] = []
        var previous: AudioClockSpan?
        for span in spans {
            guard span.sampleRate.isFinite, span.sampleRate > 0, span.sampleRate == first.sampleRate,
                  span.hostStart.isFinite, span.hostEnd.isFinite, span.hostEnd > span.hostStart,
                  span.startFrame >= 0, span.endFrame > span.startFrame,
                  span.fileStart < duration, span.fileEnd <= duration + tolerance,
                  abs((span.hostEnd - span.hostStart) - (span.fileEnd - span.fileStart)) <= tolerance else { return nil }
            let fileEnd = min(span.fileEnd, duration)
            if let previous, let last = ranges.last {
                let gap = span.hostStart - previous.hostEnd
                guard span.startFrame == previous.endFrame, gap >= -tolerance else { return nil }
                if gap > tolerance {
                    ranges.append(Self(fileStart: span.fileStart, fileEnd: fileEnd, timelineStart: last.timelineEnd + gap))
                } else {
                    ranges[ranges.count - 1] = Self(fileStart: last.fileStart, fileEnd: fileEnd, timelineStart: last.timelineStart)
                }
            } else {
                ranges.append(Self(fileStart: 0, fileEnd: fileEnd, timelineStart: 0))
            }
            previous = span
        }
        // Older sidecars may end before the audio file. Preserve its remaining samples
        // on the last known continuous range.
        if let last = ranges.last {
            ranges[ranges.count - 1] = Self(fileStart: last.fileStart, fileEnd: duration, timelineStart: last.timelineStart)
        }
        return ranges
    }

    func shifted(by offset: Double) -> Self {
        Self(fileStart: fileStart, fileEnd: fileEnd, timelineStart: timelineStart + offset)
    }
}
