import SwiftUI

/// Source-aligned events in a single chronological, bounded transcription timeline.
struct MeetingTimelineMoment: Identifiable {
    enum Kind: String, CaseIterable { case transcript = "Transcript", decision = "Decisions", action = "Actions" }
    let id: String
    let seconds: Double
    let kind: Kind
    let text: String
    let context: String
    let seekSeconds: Double?
}

/// Bridges a cited outcome in the native detail pane to the same in-pane timeline.
final class MeetingTimelineNavigation: ObservableObject {
    struct Jump {
        let id = UUID()
        let seconds: Double
        let segmentID: String
        let kind: MeetingTimelineMoment.Kind
    }
    @Published var jump: Jump?

    func show(seconds: Double, segmentID: String, kind: MeetingTimelineMoment.Kind) {
        jump = Jump(seconds: seconds, segmentID: segmentID, kind: kind)
    }

    func clear() { jump = nil }
}
