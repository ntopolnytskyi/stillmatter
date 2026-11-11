import Foundation

/// An immutable presentation of a saved phrase; its ID and time always refer to the source.
public struct TranscriptReaderPhrase: Equatable, Identifiable {
    public enum Kind: String, CaseIterable {
        case transcript = "Transcript", decision = "Decisions", action = "Actions"
        public var caption: String {
            switch self { case .transcript: return "TRANSCRIPT"; case .decision: return "DECISION"; case .action: return "ACTION" }
        }
    }
    public var metadata: String {
        if kind == .transcript {
            let initials = speaker.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
            return "\(initials)  \(speaker)"
        }
        return "\(context)\(speaker.isEmpty ? "" : " · \(speaker)")"
    }
    public let kind: Kind
    public let sourceSegmentID: String
    public let context: String
    public let id: String
    public let seconds: Double
    public let speaker: String
    public let text: String
    public let seekSeconds: Double?

    public init(id: String, seconds: Double, speaker: String, text: String, seekSeconds: Double?,
                kind: Kind = .transcript, sourceSegmentID: String? = nil, context: String? = nil) {
        self.kind = kind
        self.sourceSegmentID = sourceSegmentID ?? id
        self.context = context ?? speaker
        self.id = id
        self.seconds = seconds
        self.speaker = speaker
        self.text = text
        self.seekSeconds = seekSeconds
    }
}
