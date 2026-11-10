import Foundation

/// An immutable presentation of a saved phrase; its ID and time always refer to the source.
public struct TranscriptReaderPhrase: Equatable, Identifiable {
    public let id: String
    public let seconds: Double
    public let speaker: String
    public let text: String
    public let seekSeconds: Double?

    public init(id: String, seconds: Double, speaker: String, text: String, seekSeconds: Double?) {
        self.id = id
        self.seconds = seconds
        self.speaker = speaker
        self.text = text
        self.seekSeconds = seekSeconds
    }
}
