import Foundation
import StillmatterCore

/// Whole-transcript selection with bounded rendering, independent of playback ticks.
public final class TranscriptReaderState {
    public let windowDuration: Double = 900
    public private(set) var windowStart: Double = 0
    public private(set) var duration: Double = 0
    public private(set) var kinds = Set(TranscriptReaderPhrase.Kind.allCases)
    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var hourCount: Int { max(1, Int(ceil(duration / 3600))) }
    public var windowEnd: Double { min(windowStart + windowDuration, duration) }
    private var lastWindowStart: Double { floor(max(0, duration - 0.001) / windowDuration) * windowDuration }
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

    public var availableSpeakers: [String] { Array(Set(phrases.map(\.speaker).filter { !$0.isEmpty })).sorted() }
    public var pageRows: [TranscriptReaderPhrase] { Array(results.dropFirst(page * pageSize).prefix(pageSize)) }
    public var selectedMatch: TranscriptSearchMatch? { matches.indices.contains(matchIndex) ? matches[matchIndex] : nil }
    public var matchNumber: Int { matches.isEmpty ? 0 : matchIndex + 1 }
    public var canNextPage: Bool { (page + 1) * pageSize < results.count || (!isSearching && windowStart < lastWindowStart) }
    public var canPreviousPage: Bool { page > 0 || (!isSearching && windowStart > 0) }
    public var canNextMatch: Bool { matchIndex + 1 < matches.count }
    public var canPreviousMatch: Bool { !matches.isEmpty && matchIndex > 0 }

    public func load(meetingID: String, phrases: [TranscriptReaderPhrase], duration: Double? = nil) {
        if self.meetingID != meetingID {
            query = ""; speakers = []; kinds = Set(TranscriptReaderPhrase.Kind.allCases); windowStart = 0; resetSelection()
        }
        self.meetingID = meetingID
        self.phrases = phrases.filter { $0.seconds.isFinite && $0.seconds >= 0 }
        let sourceEnd = (self.phrases.map(\.seconds).max() ?? 0) + 0.001
        self.duration = max(sourceEnd, duration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? 0)
        windowStart = min(windowStart, lastWindowStart)
        refresh()
    }
    public func setQuery(_ query: String) {
        self.query = query; resetSelection(); refresh()
    }
    public func setKinds(_ kinds: Set<TranscriptReaderPhrase.Kind>) { self.kinds = kinds; refresh() }
    public func setWindow(hour: Int) { changeWindow(to: min(lastWindowStart, max(0, Double(hour) * 3600))) }
    private func changeWindow(to start: Double) {
        query = ""; resetSelection(); windowStart = start; refresh()
    }
    private func resetSelection() { selectedID = nil; page = 0; matchIndex = 0 }
    public func setSpeakers(_ speakers: Set<String>) { self.speakers = speakers; refresh() }
    public func setView(_ view: TranscriptReadingView) { self.view = view; refresh() }
    public func nextPage() {
        if (page + 1) * pageSize < results.count { page += 1; selectFirstOnPage() }
        else if !isSearching && windowStart < lastWindowStart { changeWindow(to: windowStart + windowDuration) }
    }
    public func previousPage() {
        if page > 0 { page -= 1; selectFirstOnPage() }
        else if !isSearching && windowStart > 0 { changeWindow(to: windowStart - windowDuration) }
    }
    public func nextMatch() { if canNextMatch { matchIndex += 1; revealMatch() } }
    public func previousMatch() { if canPreviousMatch { matchIndex -= 1; revealMatch() } }
    public func reveal(id: String) {
        guard let phrase = phrases.first(where: { $0.id == id }) else { return }
        query = ""; speakers = []; kinds.insert(phrase.kind)
        windowStart = floor(phrase.seconds / windowDuration) * windowDuration
        selectedID = id; refresh()
    }

    private func refresh() {
        let oldMatch = selectedMatch
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        results = phrases.filter { kinds.contains($0.kind) && (speakers.isEmpty || speakers.contains($0.speaker)) &&
            (term.isEmpty ? ($0.seconds >= windowStart && $0.seconds < windowStart + windowDuration)
             : $0.text.localizedStandardContains(term) || $0.metadata.localizedStandardContains(term)) }.sorted {
                if view == .speakers && $0.speaker != $1.speaker { return $0.speaker < $1.speaker }
                return $0.seconds == $1.seconds ? $0.id < $1.id : $0.seconds < $1.seconds
            }
        matches = []
        if !term.isEmpty {
            for phrase in results {
                for (field, value) in [(TranscriptSearchMatch.Field.text, phrase.text), (.context, phrase.metadata)] {
                    let text = value as NSString
                    var offset = 0
                    while offset < text.length {
                        let range = text.range(of: term, options: [.caseInsensitive, .diacriticInsensitive],
                                               range: NSRange(location: offset, length: text.length - offset))
                        if range.location == NSNotFound { break }
                        matches.append(TranscriptSearchMatch(phraseID: phrase.id, range: range, field: field))
                        offset = range.location + range.length
                    }
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
