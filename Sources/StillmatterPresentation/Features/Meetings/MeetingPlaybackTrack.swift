/// Source provenance remains separate from transcript speaker identity.
public enum MeetingPlaybackTrack: String, CaseIterable {
    case both = "Both"
    case mine = "My speech"
    case other = "Other participants"

    public func isAvailable(hasOtherTrack: Bool) -> Bool {
        self != .other || hasOtherTrack
    }
}
