extension MeetingBrowserDetail {
    /// Snapshot decisions for native controls. Commands still recheck current files
    /// and owned Jobs; presentation adds dirty-draft and busy-state restrictions.
    public var canRename: Bool { canAssociateCalendar && doorwayVersion != nil }

    public var canAssociateCalendar: Bool { isStoppedWithoutActiveJobs && !row.isArchived }

    /// Archive does not prevent explicit removal. A command also needs a file version.
    public var canRemove: Bool { isStoppedWithoutActiveJobs }

    public var reprocessUnavailableReason: String? {
        if row.isArchived { return "Archived Meetings cannot be reprocessed." }
        if !isStoppedWithoutActiveJobs { return "Wait for this Meeting’s active work to finish." }
        return nil
    }

    private var isStoppedWithoutActiveJobs: Bool {
        row.captureState == .stopped && !hasActiveManagementJobs
    }

    private var hasActiveManagementJobs: Bool {
        jobs.contains { $0.status == .queued || $0.status == .running }
    }

    /// Shared by the archive command and its disabled-state explanation.
    public var archiveUnavailableReason: String? {
        if row.isArchived { return "Archived Meetings are read-only." }
        if row.captureState == .live { return "Stop recording before archiving this Meeting." }
        if hasActiveManagementJobs || row.processingState == .processing {
            return "Finish processing before archiving this Meeting."
        }
        if row.captureState != .stopped || row.processingState != .ready {
            return "Only Ready Meetings can be archived."
        }
        if reviewItems.contains(where: { $0.review != "rejected" && $0.review != "dismissed" &&
            ($0.isPending || $0.status != .done) }) || !staleProposals.isEmpty {
            return "Resolve or reject every Action Item, including other people’s and unknown-owner work, before archiving."
        }
        return nil
    }
}

