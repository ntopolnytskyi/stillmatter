import Foundation

public struct TranscriptSearchMatch: Equatable {
    public let phraseID: String
    /// UTF-16 coordinates into the unchanged source phrase, suitable for native text highlighting.
    public let range: NSRange

    init(phraseID: String, range: NSRange) {
        self.phraseID = phraseID
        self.range = range
    }
}
