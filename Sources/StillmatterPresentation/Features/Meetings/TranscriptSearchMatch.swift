import Foundation

public struct TranscriptSearchMatch: Equatable {
    public enum Field { case text, context }
    public let field: Field
    public let phraseID: String
    /// UTF-16 coordinates into the indicated text/context field; spoken text stays unchanged.
    public let range: NSRange

    init(phraseID: String, range: NSRange, field: Field = .text) {
        self.field = field
        self.phraseID = phraseID
        self.range = range
    }
}
