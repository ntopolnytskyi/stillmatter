import Foundation

/// Implementations must score supplied text locally, without uploading search content.
/// Scores are cosine similarities, one per passage, in the same order.
public protocol LocalSemanticSearching {
    func similarities(query: String, passages: [String]) throws -> [Double]
}

public struct SearchRetrieval {
    public let results: [SearchResult]
    public let semanticNotice: String?

    public init(results: [SearchResult], semanticNotice: String? = nil) {
        self.results = results
        self.semanticNotice = semanticNotice
    }
}
