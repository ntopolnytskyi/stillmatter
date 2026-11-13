import Foundation

/// A user-confirmed addition retaining the selected utterance's original identity and timing.
public struct TranscriptLinkedItem {
    public enum Kind: String, CaseIterable {
        case action = "Action Item", decision = "Decision", note = "note"
    }
    public let id: String
    public let kind: Kind
    public var text: String
    public let source: MeetingTranscriptSegment

    public init(id: String = UUID().uuidString.lowercased(), kind: Kind, text: String, source: MeetingTranscriptSegment) {
        self.id = id; self.kind = kind; self.text = text; self.source = source
    }
}

extension MeetingManagementService {
    public func createTranscriptItem(_ draft: TranscriptLinkedItem, for meetingID: String,
                                     expectedVersion: WorkspaceFileVersion) throws -> MeetingBrowserDetail {
        let detail = try self.detail(for: meetingID)
        guard !detail.row.isArchived, detail.transcript.contains(draft.source) else {
            throw MeetingManagementError.retryRejected("Source no longer retained or changed. Cancel and select an available Transcript source.")
        }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: draft.id) != nil, !text.isEmpty, !text.contains("<!--"),
              draft.kind == .note || !text.contains(where: { $0.isNewline }) else {
            throw MeetingManagementError.retryRejected("Enter text without metadata comments. Action Items and Decisions need a single line.")
        }
        let citation = MeetingOutcomeCitation(segmentID: draft.source.id, startSeconds: draft.source.startSeconds, endSeconds: draft.source.endSeconds)
        switch draft.kind {
        case .decision:
            return try saveOutcome(.init(id: draft.id, text: text, kind: .decision, citations: [citation]), for: meetingID, expectedVersion: expectedVersion)
        case .action:
            guard var sections = detail.summary else { throw MeetingManagementError.unavailable }
            guard !detail.reviewItems.contains(where: { $0.id == draft.id }) else {
                throw MeetingManagementError.retryRejected("This linked item is already saved. Cancel and open Action Items.")
            }
            let metadata = MeetingItemMetadata(v: 1, id: draft.id, owner: nil, review: "pending", origin: "manual", legacyID: nil, citations: [citation])
            sections.myActionItems += "\n- [ ] " + text + " <!-- sm-item:" + String(decoding: try JSONEncoder().encode(metadata), as: UTF8.self) + " -->\n"
            return try saveSummary(sections, for: meetingID, expectedVersion: expectedVersion)
        case .note:
            let source = String(decoding: try JSONEncoder().encode(citation), as: UTF8.self)
            return try saveHumanNotes(detail.humanNotes + "\n\n" + text + "\n<!-- sm-source:" + source + " -->\n", for: meetingID, expectedVersion: expectedVersion)
        }
    }
}
