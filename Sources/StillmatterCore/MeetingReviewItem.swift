import Foundation

/// A versioned canonical checkbox, shared by Meeting review and the personal Todo projection.
public struct MeetingReviewItem: Equatable, Identifiable {
    public let id: String
    public let text: String
    public let owner: String?
    public let review: String
    public let status: TodoStatus
    public let dueDate: String?
    public let citations: [MeetingOutcomeCitation]
    public let path: String
    public let version: WorkspaceFileVersion
    public let rawLine: String
    public let origin: String

    public var isPending: Bool { review == "pending" }
    public var hasOwner: Bool { owner != nil && owner != "unknown" && owner != "" }
}
