import Foundation
import StillmatterCore

/// Presents saved citations alongside speech, retaining the source segment and mapped playback time.
public enum TranscriptTimelineProjection {
    public static func phrases(for detail: MeetingBrowserDetail) -> [TranscriptReaderPhrase] {
        var rows = detail.transcript.map {
            TranscriptReaderPhrase(id: $0.id, seconds: $0.startSeconds, speaker: $0.speaker,
                                   text: $0.text, seekSeconds: $0.seekSeconds)
        }
        func append(kind: TranscriptReaderPhrase.Kind, id: String, text: String, context: String, citations: [MeetingCitation]) {
            for (index, citation) in citations.enumerated() where citation.startSeconds.isFinite && citation.startSeconds >= 0 {
                let source = detail.transcript.first(where: citation.matches)
                rows.append(TranscriptReaderPhrase(id: "\(kind.rawValue)-\(id)-\(index)-\(citation.segmentID)",
                    seconds: citation.startSeconds, speaker: source?.speaker ?? "", text: text,
                    seekSeconds: source == nil ? nil : citation.validatedSeekSeconds(playbackDuration: detail.playback.durationSeconds),
                    kind: kind, sourceSegmentID: citation.segmentID,
                    context: source == nil ? "\(context) · Source unavailable" : context))
            }
        }
        for (index, decision) in detail.decisions.enumerated() {
            append(kind: .decision, id: "decision-\(index)", text: decision.text, context: "Cited decision", citations: decision.citations)
        }
        for action in detail.myActionItems {
            append(kind: .action, id: action.id, text: detail.actionDrafts[action.id]?.title ?? action.text,
                   context: "My action · \(action.reviewState.rawValue)", citations: action.citations)
        }
        for action in detail.otherActionItems {
            append(kind: .action, id: action.id, text: action.text, context: "Others’ action · reference only", citations: action.citations)
        }
        for (index, question) in detail.openQuestions.enumerated() {
            append(kind: .question, id: "question-\(index)", text: question.text, context: "Cited Open Item", citations: question.citations)
        }
        return rows
    }
}
