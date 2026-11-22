import Foundation
import SQLite3

public enum SearchChunkKind: String, CaseIterable, Hashable, Codable {
    case meeting
    case summary
    case transcript
    case metadata
    case todo
    case project
    case markdown

    public var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .summary: return "Summary"
        case .transcript: return "Transcript"
        case .metadata: return "Metadata"
        case .todo: return "Todo Item"
        case .project: return "Project"
        case .markdown: return "Markdown"
        }
    }
}

public struct SearchFilter: Equatable {
    public var kinds: Set<SearchChunkKind>
    public var pathPrefix: String?
    public var includeArchived: Bool

    public init(kinds: Set<SearchChunkKind> = [], pathPrefix: String? = nil, includeArchived: Bool = false) {
        self.kinds = kinds
        self.pathPrefix = pathPrefix
        self.includeArchived = includeArchived
    }
}

public struct SearchResult: Equatable {
    public var isArchived: Bool = false
    public let kind: SearchChunkKind
    public let sourcePath: String
    public let title: String
    public let body: String
    public let transcriptStartSeconds: Double?
    public let transcriptEndSeconds: Double?

    public var displayKindName: String {
        kind.displayName
    }

    public init(
        kind: SearchChunkKind,
        sourcePath: String,
        title: String,
        body: String,
        transcriptStartSeconds: Double? = nil,
        transcriptEndSeconds: Double? = nil
    ) {
        self.kind = kind
        self.sourcePath = sourcePath
        self.title = title
        self.body = body
        self.transcriptStartSeconds = transcriptStartSeconds
        self.transcriptEndSeconds = transcriptEndSeconds
    }
}

public enum SearchIndexError: Error, Equatable, CustomStringConvertible {
    case sqlite(code: Int32, message: String)
    case invalidStoredKind(String)

    public var description: String {
        switch self {
        case let .sqlite(code, message): return "SQLite search index error \(code): \(message)"
        case let .invalidStoredKind(kind): return "Invalid search chunk kind: \(kind)"
        }
    }
}

/// Rebuildable full-text index over canonical files in an Stillmatter workspace.
public final class SearchIndex {
    private let database: SearchSQLiteDatabase
    private let workspaceRootURL: URL
    private let semanticSearch: LocalSemanticSearching?
    private let sources: SearchSources
    private let lock = NSRecursiveLock()
    private var refreshErrors: [String: Error] = [:]

    public init(databaseURL: URL, workspaceRootURL: URL, excludedPatterns: [String] = [], semanticSearch: LocalSemanticSearching? = nil) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.database = try SearchSQLiteDatabase(url: databaseURL)
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.sources = SearchSources(workspaceRootURL: self.workspaceRootURL, excludedPatterns: excludedPatterns)
        self.semanticSearch = semanticSearch
        try migrate()
    }

    /// Deletes derived database state and recreates it from canonical workspace files.
    /// This remains available even when opening the existing database fails due to corruption.
    public static func recoveringRebuild(
        databaseURL: URL,
        workspaceRootURL: URL,
        excludedPatterns: [String] = [],
        semanticSearch: LocalSemanticSearching? = nil
    ) throws -> SearchIndex {
        for suffix in ["", "-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        let index = try SearchIndex(
            databaseURL: databaseURL,
            workspaceRootURL: workspaceRootURL,
            excludedPatterns: excludedPatterns, semanticSearch: semanticSearch
        )
        try index.rebuild()
        return index
    }

    /// Performs the launch-time consistency scan. The index is derived state, so a full
    /// rebuild is intentionally the recovery path for stale or partially deleted data.
    public func startupScan() throws {
        try rebuild()
    }

    public func rebuild() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            let paths = try sources.paths()
            try database.transaction {
                try database.run("DELETE FROM search_chunks")
                for path in paths { try insertChunks(for: path) }
            }
            refreshErrors.removeAll()
        } catch {
            refreshErrors = ["rebuild": error]
            throw error
        }
    }

    /// Removes all derived search chunks for a deleted Meeting folder.
    public func removeDirectory(relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let prefix = Self.normalize(relativePath) + "/"
        try database.run("DELETE FROM search_chunks WHERE substr(source_path, 1, ?) = ?",
                         bindings: [.text(String(prefix.count)), .text(prefix)])
    }

    /// Applies one filesystem watcher event. A missing file removes its old chunks.
    public func update(relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let refresh = sources.refresh(for: relativePath)
        do {
            try database.transaction {
                // Delete the whole pair before inserting its chosen source. A JSON
                // event may legitimately publish chunks whose source is the text file.
                for path in refresh.paths {
                    try database.run("DELETE FROM search_chunks WHERE source_path = ?", bindings: [.text(path)])
                }
                for path in refresh.paths { try insertChunks(for: path) }
            }
            refreshErrors.removeValue(forKey: refresh.errorKey)
            // Keep an old source error visible to Search without rejecting unrelated
            // canonical publication. Repair attempts retain their own rebuild error.
            if refreshErrors["rebuild"] != nil { try? rebuild() }
        } catch {
            refreshErrors[refresh.errorKey] = error
            throw error
        }
    }

    public func search(_ query: String, filter: SearchFilter = SearchFilter(), limit: Int? = nil) throws -> [SearchResult] {
        lock.lock()
        defer { lock.unlock() }
        if let key = refreshErrors.keys.sorted().first, let error = refreshErrors[key] { throw error }
        var clauses: [String] = []
        var bindings: [SearchSQLiteValue] = []
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !terms.isEmpty {
            clauses.append("search_chunks MATCH ?")
            let escaped = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: " ")
            bindings.append(.text(escaped))
        }
        if !filter.kinds.isEmpty {
            let kinds = filter.kinds.sorted { $0.rawValue < $1.rawValue }
            clauses.append("kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))")
            bindings.append(contentsOf: kinds.map { .text($0.rawValue) })
        }
        if let prefix = filter.pathPrefix {
            clauses.append("source_path LIKE ? ESCAPE '\\'")
            bindings.append(.text(Self.escapeLike(Self.normalize(prefix)) + "%"))
        }
        let whereClause = clauses.isEmpty ? "" : " WHERE " + clauses.joined(separator: " AND ")
        let orderClause = terms.isEmpty ? " ORDER BY source_path, rowid" : " ORDER BY bm25(search_chunks), source_path, rowid"
        if let limit { precondition(limit > 0, "Search limit must be positive") }
        // Apply lifecycle filtering before limiting, so archives cannot consume result slots.
        let results = try database.query(
            "SELECT kind, source_path, title, body, transcript_start, transcript_end FROM search_chunks\(whereClause)\(orderClause)",
            bindings: bindings
        ) { statement in
            let storedKind = SearchSQLiteDatabase.text(statement, column: 0)
            guard let kind = SearchChunkKind(rawValue: storedKind) else {
                throw SearchIndexError.invalidStoredKind(storedKind)
            }
            return SearchResult(
                kind: kind,
                sourcePath: SearchSQLiteDatabase.text(statement, column: 1),
                title: SearchSQLiteDatabase.text(statement, column: 2),
                body: SearchSQLiteDatabase.text(statement, column: 3),
                transcriptStartSeconds: SearchSQLiteDatabase.optionalDouble(statement, column: 4),
                transcriptEndSeconds: SearchSQLiteDatabase.optionalDouble(statement, column: 5)
            )
        }
        let visible = try results.compactMap { result -> SearchResult? in
            guard result.sourcePath.hasPrefix("Meetings/") else { return result }
            let marker = workspaceRootURL.appendingPathComponent(MeetingArchiveState.relativePath(for: result.sourcePath))
            guard FileManager.default.fileExists(atPath: marker.path) else { return result }
            let state = try MeetingArchiveState.decode(Data(contentsOf: marker))
            guard filter.includeArchived || !state.archived else { return nil }
            var result = result
            result.isArchived = state.archived
            return result
        }
        return limit.map { Array(visible.prefix($0)) } ?? visible
    }

    /// Keyword matches lead; locally ranked suggestions follow. No relevance cutoff is
    /// claimed: the selected model has no calibrated abstention threshold.
    public func retrieve(_ query: String, filter: SearchFilter = SearchFilter(), limit: Int = 100) throws -> SearchRetrieval {
        precondition(limit > 0)
        let keywords = try search(query, filter: filter)
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return SearchRetrieval(results: Array(keywords.prefix(limit)))
        }
        guard let semanticSearch else {
            return SearchRetrieval(results: Array(keywords.prefix(limit)),
                semanticNotice: "Keyword results only. Local semantic search is not installed. See local search setup instructions.")
        }
        let candidates = try search("", filter: filter).filter { result in
            // Embed only canonical Meeting text, never recording metadata or arbitrary
            // workspace files. Existing global destinations remain keyword searchable.
            result.sourcePath.hasPrefix("Meetings/") && result.kind != .metadata && result.kind != .todo
        }
        guard !candidates.isEmpty else { return SearchRetrieval(results: Array(keywords.prefix(limit))) }
        do {
            let scores = try semanticSearch.similarities(query: query, passages: candidates.map { $0.title + "\n" + $0.body })
            guard scores.count == candidates.count, scores.allSatisfy({ $0.isFinite && (-1.001...1.001).contains($0) }) else {
                throw NSError(domain: "Stillmatter.Search", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Local embedding model returned invalid scores."])
            }
            let ranked = candidates.indices.sorted { scores[$0] == scores[$1] ? $0 < $1 : scores[$0] > scores[$1] }
            var combined = keywords
            for index in ranked.prefix(20) where !combined.contains(candidates[index]) { combined.append(candidates[index]) }
            // A watcher or mutation may have refreshed canonical content while the
            // model was working. Never publish a removed/replaced chunk from that snapshot.
            let current = try search("", filter: filter)
            combined = combined.filter { current.contains($0) }
            return SearchRetrieval(results: Array(combined.prefix(limit)),
                semanticNotice: "Keyword matches first, then local semantic suggestions. Suggestions may be unrelated; verify their source.")
        } catch {
            return SearchRetrieval(results: try search(query, filter: filter, limit: limit),
                semanticNotice: "Keyword results only. Local semantic search unavailable: \(error.localizedDescription)")
        }
    }

    private func migrate() throws {
        try database.run("PRAGMA journal_mode = WAL")
        let columns: [String] = try database.query("PRAGMA table_info(search_chunks)") {
            SearchSQLiteDatabase.text($0, column: 1)
        }
        if !columns.isEmpty && columns != ["source_path", "kind", "title", "body", "transcript_start", "transcript_end"] {
            try database.run("DROP TABLE search_chunks")
        }
        try database.run("CREATE VIRTUAL TABLE IF NOT EXISTS search_chunks USING fts5(source_path UNINDEXED, kind UNINDEXED, title, body, transcript_start UNINDEXED, transcript_end UNINDEXED)")
    }

    private func insertChunks(for relativePath: String) throws {
        guard let source = try sources.read(relativePath) else { return }
        let chunks = source.isTranscript
            ? Self.jsonTranscriptChunks(source.contents)
            : Self.chunks(relativePath: source.relativePath, contents: source.contents)
        for chunk in chunks {
            try database.run(
                "INSERT INTO search_chunks (source_path, kind, title, body, transcript_start, transcript_end) VALUES (?, ?, ?, ?, ?, ?)",
                bindings: [
                    .text(source.relativePath), .text(chunk.kind.rawValue), .text(chunk.title), .text(chunk.body),
                    chunk.transcriptStartSeconds.map(SearchSQLiteValue.double) ?? .null,
                    chunk.transcriptEndSeconds.map(SearchSQLiteValue.double) ?? .null
                ]
            )
        }
    }

    private static func chunks(relativePath: String, contents: String) -> [SearchChunk] {
        let kind = fileKind(relativePath: relativePath)
        if relativePath.lowercased().hasSuffix(".vtt") {
            return vttChunks(contents)
        }
        if relativePath.lowercased().hasSuffix("/transcript.json") || relativePath.lowercased() == "transcript.json" {
            let segments = jsonTranscriptChunks(contents)
            if !segments.isEmpty { return segments }
        }
        if relativePath.lowercased().hasSuffix(".md") {
            let lines = contents.components(separatedBy: .newlines)
            let todoBodies: [String]
            if relativePath.hasPrefix("Meetings/") {
                let isNotes = ["my-notes.md", "notes.md"].contains(URL(fileURLWithPath: relativePath).lastPathComponent)
                todoBodies = TodoItemParser().parse(markdown: contents, relativePath: relativePath).compactMap { item in
                    if let metadata = TodoItemParser.metadata(in: item.rawText) {
                        return metadata.owner == "me" && metadata.review == "approved" ? item.title : nil
                    }
                    // User-authored My Notes tasks default to Me/approved. Explicit
                    // broken metadata is never treated as implicit approval.
                    return isNotes && !item.rawText.contains("<!-- sm-item:") ? item.title : nil
                }
            } else { todoBodies = lines.compactMap(todoBody) }
            if kind == .todo && !todoBodies.isEmpty {
                return todoBodies.map { SearchChunk(kind: .todo, title: $0, body: $0) }
            }
            var chunks = markdownSections(
                lines: lines,
                kind: kind,
                fallbackTitle: URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
            )
            if let frontmatter = markdownFrontmatter(lines) {
                chunks.append(SearchChunk(kind: .metadata, title: "Frontmatter", body: frontmatter))
            }
            chunks.append(contentsOf: todoBodies.map { SearchChunk(kind: .todo, title: $0, body: $0) })
            return chunks
        }
        let title = URL(fileURLWithPath: relativePath).deletingPathExtension().lastPathComponent
        return [SearchChunk(kind: kind, title: title, body: contents.trimmingCharacters(in: .whitespacesAndNewlines))]
    }

    private static func markdownSections(
        lines: [String],
        kind: SearchChunkKind,
        fallbackTitle: String
    ) -> [SearchChunk] {
        var sections: [SearchChunk] = []
        var title: String?
        var bodyLines: [String] = []

        func appendSection() {
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty {
                sections.append(SearchChunk(kind: kind, title: title ?? fallbackTitle, body: body))
            }
            bodyLines = []
        }

        let contentStart = lines.first?.trimmingCharacters(in: .whitespaces) == "---"
            ? (lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }).map { $0 + 1 } ?? 0) : 0
        for line in lines.dropFirst(contentStart) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), let firstText = trimmed.firstIndex(where: { $0 != "#" && !$0.isWhitespace }) {
                appendSection()
                title = String(trimmed[firstText...]).trimmingCharacters(in: .whitespaces)
            } else {
                bodyLines.append(line)
            }
        }
        appendSection()

        if sections.isEmpty {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { sections.append(SearchChunk(kind: kind, title: title ?? fallbackTitle, body: body)) }
        }
        return sections
    }

    private static func markdownFrontmatter(_ lines: [String]) -> String? {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let closingIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        let body = lines[lines.index(after: lines.startIndex)..<closingIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }

    private static func jsonTranscriptChunks(_ contents: String) -> [SearchChunk] {
        guard let data = contents.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let segments = root["segments"] as? [[String: Any]] else { return [] }
        return segments.compactMap { segment in
            guard let text = segment["text"] as? String else { return nil }
            let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            let start = number(in: segment, keys: ["start", "start_sec", "startSeconds"])
            let end = number(in: segment, keys: ["end", "end_sec", "endSeconds"])
            return SearchChunk(
                kind: .transcript,
                title: start.map { String(format: "Transcript %.3fs", $0) } ?? "Transcript",
                body: body,
                transcriptStartSeconds: start,
                transcriptEndSeconds: end
            )
        }
    }

    private static func number(in dictionary: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = dictionary[key] as? NSNumber { return value.doubleValue }
        }
        return nil
    }

    private static func vttChunks(_ contents: String) -> [SearchChunk] {
        let blocks = contents.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard let timingIndex = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let times = lines[timingIndex].components(separatedBy: " --> ")
            guard times.count == 2,
                  let start = vttSeconds(times[0]),
                  let end = vttSeconds(times[1].components(separatedBy: .whitespaces).first ?? "") else { return nil }
            let body = lines.dropFirst(timingIndex + 1).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return nil }
            return SearchChunk(
                kind: .transcript,
                title: "Transcript \(times[0])",
                body: body,
                transcriptStartSeconds: start,
                transcriptEndSeconds: end
            )
        }
    }

    private static func vttSeconds(_ value: String) -> Double? {
        let components = value.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard components.count == 2 || components.count == 3,
              let seconds = Double(components.last ?? "") else { return nil }
        let minutesIndex = components.count - 2
        guard let minutes = Double(components[minutesIndex]) else { return nil }
        let hours = components.count == 3 ? Double(components[0]) ?? 0 : 0
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func todoBody(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ["), trimmed.count >= 6 else { return nil }
        let markerIndex = trimmed.index(trimmed.startIndex, offsetBy: 3)
        guard " xXBCbc".contains(trimmed[markerIndex]), trimmed[trimmed.index(after: markerIndex)] == "]" else { return nil }
        return String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
    }

    private static func fileKind(relativePath: String) -> SearchChunkKind {
        let path = relativePath.lowercased()
        let filename = URL(fileURLWithPath: path).lastPathComponent
        if filename == "meeting.md" { return .meeting }
        if filename == "summary.md" && path.hasPrefix("meetings/") { return .summary }
        if filename.hasPrefix("transcript.") { return .transcript }
        if filename == "recording.localref.json" { return .metadata }
        if path.hasPrefix("todos/") { return .todo }
        if path.hasPrefix("projects/") { return .project }
        return .markdown
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }


}

private struct SearchChunk {
    let kind: SearchChunkKind
    let title: String
    let body: String
    let transcriptStartSeconds: Double?
    let transcriptEndSeconds: Double?

    init(
        kind: SearchChunkKind,
        title: String,
        body: String,
        transcriptStartSeconds: Double? = nil,
        transcriptEndSeconds: Double? = nil
    ) {
        self.kind = kind
        self.title = title
        self.body = body
        self.transcriptStartSeconds = transcriptStartSeconds
        self.transcriptEndSeconds = transcriptEndSeconds
    }
}

private enum SearchSQLiteValue {
    case text(String)
    case double(Double)
    case null
}

private final class SearchSQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            if let handle = handle { sqlite3_close(handle) }
            handle = nil
            throw SearchIndexError.sqlite(code: result, message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle = handle { sqlite3_close(handle) }
    }

    func run(_ sql: String, bindings: [SearchSQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error(code: result) }
    }

    func query<T>(_ sql: String, bindings: [SearchSQLiteValue] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw error(code: result) }
            rows.append(try row(statement))
        }
    }

    func transaction(_ work: () throws -> Void) throws {
        try run("BEGIN IMMEDIATE")
        do {
            try work()
            try run("COMMIT")
        } catch {
            try? run("ROLLBACK")
            throw error
        }
    }

    static func optionalDouble(_ statement: OpaquePointer, column: Int32) -> Double? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, column)
    }

    static func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    private func prepare(_ sql: String, bindings: [SearchSQLiteValue]) throws -> OpaquePointer {
        guard let handle = handle else { throw SearchIndexError.sqlite(code: SQLITE_MISUSE, message: "Database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let prepared = statement else { throw error(code: result) }
        for (offset, binding) in bindings.enumerated() {
            let bindResult: Int32
            switch binding {
            case let .text(value):
                bindResult = sqlite3_bind_text(prepared, Int32(offset + 1), value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let .double(value):
                bindResult = sqlite3_bind_double(prepared, Int32(offset + 1), value)
            case .null:
                bindResult = sqlite3_bind_null(prepared, Int32(offset + 1))
            }
            guard bindResult == SQLITE_OK else {
                sqlite3_finalize(prepared)
                throw error(code: bindResult)
            }
        }
        return prepared
    }

    private func error(code: Int32) -> SearchIndexError {
        .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error")
    }
}
