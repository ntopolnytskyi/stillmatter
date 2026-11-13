import StillmatterCore

/// Captures the displayed file version before editing, including across external refreshes.
public struct MeetingOutcomeDraft {
    public var entry: MeetingOutcomeEntry
    public var baseVersion: WorkspaceFileVersion
    public init(entry: MeetingOutcomeEntry, baseVersion: WorkspaceFileVersion) {
        self.entry = entry; self.baseVersion = baseVersion
    }
}
