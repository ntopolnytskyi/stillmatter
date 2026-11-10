import Foundation
import StillmatterCore

/// Whole-transcript selection with bounded rendering, independent of playback ticks.
public final class TranscriptReaderState {
    public let pageSize = 100
    public var pageStart: Int { page * pageSize + 1 }
    public var pageEnd: Int { min((page + 1) * pageSize, results.count) }
    public private(set) var phrases: [TranscriptReaderPhrase] = []
    public private(set) var results: [TranscriptReaderPhrase] = []
    public private(set) var matches: [TranscriptSearchMatch] = []
    public private(set) var query = ""
    public private(set) var speakers: Set<String> = []
    public private(set) var view: TranscriptReadingView
    public private(set) var page = 0
    public private(set) var selectedID: String?
    private var matchIndex = 0
    private var meetingID: String?
    public init(view: TranscriptReadingView = .timestamps) { self.view = view }

    public var availableSpeakers: [String] { Array(Set(phrases.map(\.speaker))).sorted() }
    public var pageRows: [TranscriptReaderPhrase] { Array(results.dropFirst(page * pageSize).prefix(pageSize)) }
    public var selectedMatch: TranscriptSearchMatch? { matches.indices.contains(matchIndex) ? matches[matchIndex] : nil }
    public var matchNumber: Int { matches.isEmpty ? 0 : matchIndex + 1 }
    public var canNextPage: Bool { (page + 1) * pageSize < results.count }
    public var canPreviousPage: Bool { page > 0 }
    public var canNextMatch: Bool { matchIndex + 1 < matches.count }
    public var canPreviousMatch: Bool { !matches.isEmpty && matchIndex > 0 }

    public func load(meetingID: String, phrases: [TranscriptReaderPhrase]) {
        if self.meetingID != meetingID {
            query = ""; speakers = []; selectedID = nil; page = 0; matchIndex = 0
        }
        self.meetingID = meetingID
        self.phrases = phrases
        refresh()
    }
    public func setQuery(_ query: String) {
        self.query = query; selectedID = nil; page = 0; matchIndex = 0; refresh()
    }
    public func setSpeakers(_ speakers: Set<String>) { self.speakers = speakers; refresh() }
    public func setView(_ view: TranscriptReadingView) { self.view = view; refresh() }
    public func nextPage() { if canNextPage { page += 1; selectFirstOnPage() } }
    public func previousPage() { if canPreviousPage { page -= 1; selectFirstOnPage() } }
    public func nextMatch() { if canNextMatch { matchIndex += 1; revealMatch() } }
    public func previousMatch() { if canPreviousMatch { matchIndex -= 1; revealMatch() } }
    public func reveal(id: String) {
        guard phrases.contains(where: { $0.id == id }) else { return }
        query = ""; speakers = []; selectedID = id; refresh()
    }

    private func refresh() {
        let oldMatch = selectedMatch
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = phrases.filter { (speakers.isEmpty || speakers.contains($0.speaker)) &&
            (term.isEmpty || $0.text.localizedStandardContains(term)) }.sorted {
                if view == .speakers && $0.speaker != $1.speaker { return $0.speaker < $1.speaker }
                return $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds < $1.seconds
            }
        matches = []
        if !term.isEmpty {
            for phrase in results {
                let text = phrase.text as NSString
                var offset = 0
                while offset < text.length {
                    let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: NSRange(location: offset, length: text.length - offset))
                    if range.location == NSNotFound { break }
                    matches.append(TranscriptSearchMatch(phraseID: phrase.id, range: range))
                    offset = range.location + range.length
                }
            }
        }
        if let oldMatch, let index = matches.firstIndex(of: oldMatch) { matchIndex = index }
        else { matchIndex = 0 }
        if !matches.isEmpty { revealMatch() }
        else if let selectedID, let index = results.firstIndex(where: { $0.id == selectedID }) { page = index / pageSize }
        else { selectedID = nil; page = min(page, max(0, (results.count - 1) / pageSize)) }
    }
    private func revealMatch() {
        guard let match = selectedMatch, let index = results.firstIndex(where: { $0.id == match.phraseID }) else { return }
        selectedID = match.phraseID; page = index / pageSize
    }
    private func selectFirstOnPage() {
        selectedID = pageRows.first?.id
        if let index = matches.firstIndex(where: { $0.phraseID == selectedID }) { matchIndex = index }
    }
}
