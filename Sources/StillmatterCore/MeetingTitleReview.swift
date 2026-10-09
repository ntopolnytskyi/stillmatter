import Foundation

public enum MeetingTitleReviewError: Error, Equatable {
    case invalidTitle
    case notPending
    case notMeeting
    case changedTitle
}

/// Resolves Required title reviews against the current doorway, never against a stale title.
public final class MeetingTitleReviewService {
    private let vault: WorkspaceVault
    private let inbox: TasksInbox
    private let jobs: JobStore?
    private let index: SearchIndex?

    public init(vault: WorkspaceVault, inbox: TasksInbox, jobStore: JobStore? = nil, searchIndex: SearchIndex? = nil) {
        self.vault = vault
        self.inbox = inbox
        self.jobs = jobStore
        self.index = searchIndex
    }

    public static func reviewID(sessionID: String) -> String { "meeting-title:\(sessionID)" }

    @discardableResult
    public func accept(id: String, title: String) throws -> String {
        guard let item = try inbox.items(category: .required).first(where: { $0.id == id && $0.kind == .titleReview }),
              let path = item.sourceRef else { throw MeetingTitleReviewError.notPending }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, !cleaned.contains("\n"), !cleaned.contains("\r"),
              !cleaned.contains("/"), !cleaned.contains("\\") else {
            throw MeetingTitleReviewError.invalidTitle
        }
        let current = try vault.readMarkdown(relativePath: path)
        guard let text = String(data: current.data, encoding: .utf8),
              text.contains("\ntype: meeting\n") else { throw MeetingTitleReviewError.notMeeting }
        guard let titleLine = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("title: ") }),
              let heading = text.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }) else {
            throw MeetingTitleReviewError.notMeeting
        }
        let oldTitle = String(titleLine.dropFirst(7))
        guard oldTitle.hasPrefix("Untitled Meeting at ") else { throw MeetingTitleReviewError.changedTitle }
        guard heading == "# \(oldTitle)" else { throw MeetingTitleReviewError.changedTitle }
        let updated = text.replacingOccurrences(of: titleLine + "\n", with: "title: \(cleaned)\n")
            .replacingOccurrences(of: heading + "\n", with: "# \(cleaned)\n")
        let words = cleaned.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let slug = words.prefix(8).joined(separator: "-")
        let directory = (path as NSString).deletingLastPathComponent
        let parent = (directory as NSString).deletingLastPathComponent
        let basename = (directory as NSString).lastPathComponent
        let timePrefix = basename.components(separatedBy: "-untitled-meeting").first ?? basename
        var finalPath = path
        if !slug.isEmpty, basename.contains("-untitled-meeting"),
           !directory.contains(".."), !cleaned.contains("/") {
            let candidate = "\(parent)/\(timePrefix)-\(slug)/meeting.md"
            if candidate != path {
                finalPath = try MeetingManagementService(vault: vault, jobStore: jobs, inbox: inbox,
                    searchIndex: index).rename(meetingID: path, title: cleaned,
                    expectedVersion: current.version).row.meetingRelativePath
            } else {
                _ = try vault.writeMarkdown(Data(updated.utf8), relativePath: path, expectedVersion: current.version)
            }
        } else {
            _ = try vault.writeMarkdown(Data(updated.utf8), relativePath: path, expectedVersion: current.version)
        }
        try inbox.removeItem(id: id)
        return finalPath
    }
}
