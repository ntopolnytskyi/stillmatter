/// The persisted Transcript reading presentation; source phrases remain unchanged.
public enum TranscriptReadingView: String, Codable, CaseIterable {
    case timestamps = "With timestamps"
    case clearText = "Clear text"
    case speakers = "By speakers"

    /// Display labels can evolve without changing stored preference values.
    public var title: String {
        switch self {
        case .timestamps: return "With timestamps"
        case .clearText: return "Text only"
        case .speakers: return "Grouped by speaker"
        }
    }

    /// Old settings and unrecognized future preferences retain the default presentation.
    public init(persistedValue: String?) {
        self = persistedValue.flatMap(Self.init(rawValue:)) ?? .timestamps
    }
}
