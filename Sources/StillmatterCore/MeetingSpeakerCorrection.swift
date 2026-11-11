import Foundation

/// A manual identity belongs to evidence, never to a generated speaker ordinal or name.
public struct MeetingSpeakerCorrectionReview: Equatable {
    public let name: String
    public let track: TranscriptTrack
    public let startSeconds: Double
    public let endSeconds: Double
}

struct MeetingSpeakerCorrection: Codable, Equatable {
    struct Source: Codable, Hashable {
        let track: TranscriptTrack
        let start: Double
        let end: Double
        init(_ segment: TranscriptSegment) {
            track = segment.track; start = segment.startSeconds; end = segment.endSeconds
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(track.rawValue); hasher.combine(start); hasher.combine(end)
        }
        func matches(_ segment: TranscriptSegment) -> Bool {
            track == segment.track && start == segment.startSeconds && end == segment.endSeconds
        }
    }
    static func sources(for segment: TranscriptSegment, in document: TranscriptDocument) -> [Source] {
        func cluster(_ candidate: TranscriptSegment) -> Int? {
            let overlaps = (document.speakerTurns ?? []).filter {
                $0.track == candidate.track && $0.startSeconds < candidate.endSeconds && $0.endSeconds > candidate.startSeconds
            }
            let clusters = Set(overlaps.map(\.clusterID))
            return clusters.count == 1 ? clusters.first : nil
        }
        guard let identity = cluster(segment) else { return [.init(segment)] }
        return document.segments.filter { $0.track == segment.track && cluster($0) == identity }.map(Source.init)
    }

    static func acceptingExternalNames(_ corrections: [Self], from document: TranscriptDocument) -> [Self] {
        let segments = Dictionary(grouping: document.segments, by: Source.init)
        return corrections.flatMap { correction in
            var groups: [Self] = []
            for source in correction.sources {
                let matches = segments[source] ?? []
                let name = matches.count == 1 ? matches[0].speaker : correction.name
                if let index = groups.firstIndex(where: { $0.name == name }) {
                    groups[index].sources.append(source)
                } else {
                    groups.append(Self(name: name, sources: [source]))
                }
            }
            return groups
        }
    }

    var name: String
    var sources: [Source]
}
