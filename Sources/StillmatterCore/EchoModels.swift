import Foundation

struct SpeakerTurnAnchor: Codable, Equatable, Sendable {
    var start: Double
    var end: Double
    var duration: Double { max(0, end - start) }
    var isValid: Bool { start.isFinite && end.isFinite && start >= 0 && end > start }
    func overlap(_ other: Self) -> Double {
        max(0, min(end, other.end) - max(start, other.start))
    }
}
