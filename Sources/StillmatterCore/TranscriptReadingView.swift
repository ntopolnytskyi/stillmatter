/// The persisted Transcript reading presentation; source phrases remain unchanged.
public enum TranscriptReadingView: String, Codable, CaseIterable {
    case timestamps = "With timestamps"
    case clearText = "Clear text"
    case speakers = "By speakers"
}
