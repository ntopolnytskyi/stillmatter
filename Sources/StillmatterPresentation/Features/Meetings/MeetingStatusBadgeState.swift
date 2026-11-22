import StillmatterCore

/// A single-line Meeting status, independent of native view styling.
public struct MeetingStatusBadgeState: Equatable {
    public enum Meaning: Equatable {
        case ready, attention, failure, informational
    }

    public let title: String
    public let meaning: Meaning

    public init(row: MeetingBrowserRow) {
        if row.isArchived {
            title = "Archived"
            meaning = .informational
        } else if row.job?.status == .failed {
            switch row.job?.stageID {
            case TranscriptionJob.stageID: title = "Transcription failed"
            case MeetingSummaryJob.stageID: title = "Summarization failed"
            default: title = "Processing failed"
            }
            meaning = .failure
        } else if row.processingState == .processing {
            let stageTitle: String
            switch (row.job?.stageID, row.job?.status == .queued) {
            case (TranscriptionJob.stageID, true): stageTitle = "Transcription queued"
            case (MeetingSummaryJob.stageID, true): stageTitle = "Summarization queued"
            case (TranscriptionJob.stageID, false): stageTitle = "Transcribing"
            case (MeetingSummaryJob.stageID, false): stageTitle = "Summarizing"
            case (_, true): stageTitle = "Queued"
            default: stageTitle = "Processing"
            }
            if row.job?.status == .running,
               let fraction = row.job?.progressFraction,
               fraction.isFinite, (0...1).contains(fraction) {
                title = "\(stageTitle) · \(Int((fraction * 100).rounded()))%"
            } else {
                title = stageTitle
            }
            meaning = .informational
        } else {
            title = row.processingState.displayName
            switch row.processingState {
            case .ready: meaning = .ready
            case .live, .needsAttention: meaning = .attention
            case .processing, .unavailable: meaning = .informational
            }
        }
    }
}
