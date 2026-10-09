import Foundation

public enum ActionItemProposalReviewError: Error, Equatable {
    case proposalNotPending(String)
    case noProposalsToMerge
    case emptyTodoTitle
}

/// Resolves pending Action Item proposals and promotes accepted work into the
/// canonical Markdown todo queue.
public final class ActionItemProposalReviewer {
    private let inbox: TasksInbox
    private let todoMutator: TodoItemMutator

    public init(inbox: TasksInbox, todoMutator: TodoItemMutator) {
        self.inbox = inbox
        self.todoMutator = todoMutator
    }

    @discardableResult
    public func accept(
        proposalID: String,
        editedTitle: String? = nil,
        expectedTodoVersion: WorkspaceFileVersion
    ) throws -> WorkspaceFileVersion {
        let proposal = try pendingProposal(id: proposalID)
        let draft = try todoDraft(for: proposal, title: editedTitle ?? proposal.title)
        let version = try todoMutator.createInQueue([draft], expectedVersion: expectedTodoVersion)
        try inbox.setProposalReviewState(id: proposalID, state: .accepted)
        return version
    }

    @discardableResult
    public func batchAccept(
        proposalIDsInDisplayedOrder proposalIDs: [String],
        expectedTodoVersion: WorkspaceFileVersion
    ) throws -> WorkspaceFileVersion {
        try batchAccept(
            proposalEditsInDisplayedOrder: proposalIDs.map { ($0, nil) },
            expectedTodoVersion: expectedTodoVersion
        )
    }

    /// Accepts proposals atomically in displayed order while preserving any title edits
    /// made in the review collection.
    @discardableResult
    public func batchAccept(
        proposalEditsInDisplayedOrder proposalEdits: [(id: String, editedTitle: String?)],
        expectedTodoVersion: WorkspaceFileVersion
    ) throws -> WorkspaceFileVersion {
        let proposalsAndTitles = try proposalEdits.map { edit in
            let proposal = try pendingProposal(id: edit.id)
            return (proposal, edit.editedTitle ?? proposal.title)
        }
        let drafts = try proposalsAndTitles.map { proposal, title in
            try todoDraft(for: proposal, title: title)
        }
        let proposals = proposalsAndTitles.map(\.0)
        let version = try todoMutator.createInQueue(drafts, expectedVersion: expectedTodoVersion)
        try inbox.setProposalReviewStates(ids: proposals.map(\.id), state: .accepted)
        return version
    }

    @discardableResult
    public func merge(
        proposalIDs: [String],
        title: String,
        expectedTodoVersion: WorkspaceFileVersion
    ) throws -> WorkspaceFileVersion {
        guard !proposalIDs.isEmpty else { throw ActionItemProposalReviewError.noProposalsToMerge }
        let proposals = try proposalIDs.map(pendingProposal(id:))
        let sourceRefs = proposals.map(\.sourceRef).reduce(into: [String]()) { uniqueRefs, sourceRef in
            if !uniqueRefs.contains(sourceRef) { uniqueRefs.append(sourceRef) }
        }
        let draft = try todoDraft(title: title, sourceRefs: sourceRefs)
        let version = try todoMutator.createInQueue([draft], expectedVersion: expectedTodoVersion)
        try inbox.setProposalReviewStates(ids: proposals.map(\.id), state: .merged)
        return version
    }

    public func markReferenceOnly(proposalID: String) throws {
        _ = try pendingProposal(id: proposalID)
        try inbox.setProposalReviewState(id: proposalID, state: .referenceOnly)
    }

    public func dismiss(proposalID: String) throws {
        _ = try pendingProposal(id: proposalID)
        try inbox.setProposalReviewState(id: proposalID, state: .dismissed)
    }

    public func cancel(proposalID: String) throws {
        try dismiss(proposalID: proposalID)
    }

    private func pendingProposal(id: String) throws -> ActionItemProposal {
        guard let proposal = try inbox.pendingProposal(id: id) else {
            throw ActionItemProposalReviewError.proposalNotPending(id)
        }
        return proposal
    }

    private func todoDraft(for proposal: ActionItemProposal, title: String) throws -> TodoItemDraft {
        try todoDraft(title: title, sourceRefs: [proposal.sourceRef])
    }

    private func todoDraft(title: String, sourceRefs: [String]) throws -> TodoItemDraft {
        let title = Self.removingAIProposedMarker(from: title)
        guard !title.isEmpty else { throw ActionItemProposalReviewError.emptyTodoTitle }
        return TodoItemDraft(title: title, sourceRefs: sourceRefs)
    }

    private static func removingAIProposedMarker(from title: String) -> String {
        title
            .replacingOccurrences(
                of: #"(?i)(?:^|\s)#ai-proposed(?=\s|$)"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
