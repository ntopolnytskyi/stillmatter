import Foundation

/// A manual identity belongs to evidence, never to a generated speaker ordinal or name.
struct MeetingSpeakerCorrection: Codable, Equatable {
    struct Source: Codable, Equatable {
        let track: TranscriptTrack
        let start: Double
        let end: Double
        init(_ segment: TranscriptSegment) {
            track = segment.track; start = segment.startSeconds; end = segment.endSeconds
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
        corrections.flatMap { correction in
            var groups: [Self] = []
            for source in correction.sources {
                let matches = document.segments.filter { source.matches($0) }
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
