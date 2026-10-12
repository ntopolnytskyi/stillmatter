#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// AppKit rendering model for one Meeting outcome. The shipped renderer lives in
/// `MeetingManagementView`; keeping this model separate avoids coupling domain
/// citations and review state to view-control bookkeeping.
struct MeetingOutcomeRow: Identifiable {
    let id: String
    let text: String
    let provenance: String
    let reviewState: ProposalReviewState?
    let citations: [MeetingCitation]

    var isPendingReview: Bool { reviewState == .pending }

    var detailText: String {
        [provenance, reviewState?.rawValue].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }
}

struct MeetingOutcomeGroup: Identifiable {
    enum Kind: String {
        case mine
        case others
        case decisions
        case questions

        var isReviewWorkspace: Bool { self == .mine }

        var timelineKind: MeetingTimelineMoment.Kind {
            switch self {
            case .mine, .others: return .action
            case .decisions: return .decision
            case .questions: return .transcript
            }
        }
    }

    let kind: Kind
    let title: String
    let note: String
    let rows: [MeetingOutcomeRow]
    var id: String { kind.rawValue }
}
