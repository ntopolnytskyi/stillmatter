import Foundation

/// Read-only identity check for a Today action. Callers must still re-read the
/// owning store/event before showing a target. No mutation or fallback selection.
public enum TodayTargetResolution {
    public static func inbox(_ selected: InboxItem, owner: String,
                             current: [InboxItem]) -> InboxItem? {
        guard selected.workspaceOwner == owner else { return nil }
        return current.first(where: { $0.id == selected.id && $0.kind == selected.kind
            && $0.workspaceOwner == owner && $0 == selected })
    }

    /// Markdown has no durable Todo UUID. Match the complete canonical line and
    /// source, only when unique. Reordering may change line numbers; edits,
    /// duplicate lines and deletions fail closed instead of opening another item.
    public static func queue(_ selected: TodoItem, selectedOwner: String?, owner: String,
                             current: [TodoItem]) -> TodoItem? {
        guard selectedOwner == owner else { return nil }
        let matches = current.filter { $0.rawText == selected.rawText
            && $0.sourceRef == selected.sourceRef
            && $0.status == selected.status
            && $0.dueDate == selected.dueDate
            && $0.comments == selected.comments }
        return matches.count == 1 ? matches[0] : nil
    }

    /// A failed Inbox Job has a Job ID, but only a uniquely matched current
    /// Meeting Job can expose the existing Meeting retry contract.
    public static func retryableMeetingID(
        for item: InboxItem, owner: String, jobID: String, jobOwner: String?,
        jobStatus: JobStatus, meetings: [(meetingID: String, jobID: String, status: JobStatus)]
    ) -> String? {
        guard item.kind == .failedJob, item.workspaceOwner == owner,
              item.id == "job:\(jobID)", jobOwner == owner, jobStatus == .failed else { return nil }
        let matches = meetings.filter { $0.jobID == jobID && $0.status == .failed }
        return matches.count == 1 ? matches[0].meetingID : nil
    }

    public static func calendar(_ selected: TodayMeeting, selectedOwner: String?, owner: String,
                                eventIdentifier: String, calendarIdentifier: String,
                                eventStart: Date? = nil) -> Bool {
        selectedOwner == owner && selected.eventIdentifier == eventIdentifier
            && selected.calendarIdentifier == calendarIdentifier
            && selected.eventStart == eventStart
    }
}
