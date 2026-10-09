import Foundation

public struct WeeklyReportAcceptanceRequest: Equatable {
    public let draft: WeeklyReportDraft
    public let editedText: String

    public init(draft: WeeklyReportDraft, editedText: String) {
        self.draft = draft
        self.editedText = editedText
    }
}

public enum WeeklyReportPromptState: Equatable {
    case idle
    case deferred(WeeklyReportDraft)
    case presented(WeeklyReportDraft)
}

/// Owns prompt timing independently of AppKit so required prompts can be held
/// while a Meeting or recording is active and presented immediately afterward.
public final class WeeklyReportPromptCoordinator {
    public private(set) var state: WeeklyReportPromptState = .idle {
        didSet { onStateChange(state) }
    }

    private let onAccept: (WeeklyReportAcceptanceRequest) throws -> Void
    private let onStateChange: (WeeklyReportPromptState) -> Void
    private var pendingDraft: WeeklyReportDraft?
    private var remindedDraftID: String?
    private var acceptedDraftIDs: Set<String> = []

    public init(
        onAccept: @escaping (WeeklyReportAcceptanceRequest) throws -> Void = { _ in },
        onStateChange: @escaping (WeeklyReportPromptState) -> Void = { _ in }
    ) {
        self.onAccept = onAccept
        self.onStateChange = onStateChange
    }

    public func offer(_ draft: WeeklyReportDraft, isMeetingOrRecordingActive: Bool) {
        guard !acceptedDraftIDs.contains(draft.id) else { return }
        if pendingDraft?.id == draft.id {
            guard remindedDraftID != draft.id else { return }
            switch state {
            case .presented, .deferred: return
            case .idle: break
            }
        }
        pendingDraft = draft
        guard remindedDraftID != draft.id else { return }
        state = isMeetingOrRecordingActive ? .deferred(draft) : .presented(draft)
    }

    public func meetingOrRecordingActivityDidChange(isActive: Bool) {
        guard let draft = pendingDraft else { return }
        if isActive {
            if case .presented = state { state = .deferred(draft) }
        } else if case .deferred = state {
            state = .presented(draft)
        }
    }

    public func remindNextTime() {
        guard let draft = pendingDraft else { return }
        remindedDraftID = draft.id
        state = .idle
    }

    public func nextPromptOpportunity(isMeetingOrRecordingActive: Bool) {
        remindedDraftID = nil
        guard let draft = pendingDraft else { return }
        state = isMeetingOrRecordingActive ? .deferred(draft) : .presented(draft)
    }

    public func accept(editedText: String) throws {
        guard let draft = pendingDraft else { return }
        try onAccept(WeeklyReportAcceptanceRequest(draft: draft, editedText: editedText))
        acceptedDraftIDs.insert(draft.id)
        pendingDraft = nil
        remindedDraftID = nil
        state = .idle
    }
}
