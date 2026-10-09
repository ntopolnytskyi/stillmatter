import Foundation
import SQLite3

public enum SearchChunkKind: String, CaseIterable, Hashable, Codable {
    case meeting
    case summary
    case transcript
    case metadata
    case todo
    case activity
    case project
    case report
    case brief
    case markdown

    public var displayName: String {
        switch self {
        case .meeting: return "Meeting"
        case .summary: return "Summary"
        case .transcript: return "Transcript"
        case .metadata: return "Metadata"
        case .todo: return "Todo Item"
        case .activity: return "Activity Item"
        case .project: return "Project"
        case .report: return "Report"
        case .brief: return "Brief"
        case .markdown: return "Markdown"
        }
    }
}

public struct SearchFilter: Equatable {
    public var kinds: Set<SearchChunkKind>
    public var pathPrefix: String?

    public init(kinds: Set<SearchChunkKind> = [], pathPrefix: String? = nil) {
        self.kinds = kinds
        self.pathPrefix = pathPrefix
    }
}

public struct SearchResult: Equatable {
    public let kind: SearchChunkKind
    public let sourcePath: String
    public let title: String
    public let body: String
    public let transcriptStartSeconds: Double?
    public let transcriptEndSeconds: Double?

    public var displayKindName: String {
        let lowercasedPath = sourcePath.lowercased()
        if kind == .report && lowercasedPath.hasPrefix("reports/weekly/") { return "Weekly Report" }
        if kind == .report && lowercasedPath.hasPrefix("reports/daily/") { return "Daily Report" }
        if kind == .brief && lowercasedPath.hasPrefix("briefs/daily/") { return "Daily Brief" }
        if kind == .brief && lowercasedPath.hasPrefix("briefs/weekly/") { return "Weekly Brief" }
        return kind.displayName
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
    private let excludedPatterns: [String]
    private let lock = NSRecursiveLock()

    public init(databaseURL: URL, workspaceRootURL: URL, excludedPatterns: [String] = []) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.database = try SearchSQLiteDatabase(url: databaseURL)
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.excludedPatterns = excludedPatterns
        try migrate()
    }

    /// Deletes derived database state and recreates it from canonical workspace files.
    /// This remains available even when opening the existing database fails due to corruption.
    public static func recoveringRebuild(
        databaseURL: URL,
        workspaceRootURL: URL,
        excludedPatterns: [String] = []
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
            excludedPatterns: excludedPatterns
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
        let files = try indexableFiles()
        try database.transaction {
            try database.run("DELETE FROM search_chunks")
            for file in files {
                try insertChunks(for: file.relativePath, fileURL: file.url)
            }
        }
    }

    /// Applies one filesystem watcher event. A missing file removes its old chunks.
    public func update(relativePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let normalizedPath = Self.normalize(relativePath)
        try database.transaction {
            try database.run("DELETE FROM search_chunks WHERE source_path = ?", bindings: [.text(normalizedPath)])
            let fileURL = workspaceRootURL.appendingPathComponent(normalizedPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  isIndexable(relativePath: normalizedPath) else { return }
            try insertChunks(for: normalizedPath, fileURL: fileURL)
        }
    }

    public func search(_ query: String, filter: SearchFilter = SearchFilter(), limit: Int? = nil) throws -> [SearchResult] {
        lock.lock()
        defer { lock.unlock() }
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
        let limitClause: String
        if let limit {
            precondition(limit > 0, "Search limit must be positive")
            limitClause = " LIMIT \(limit)"
        } else {
            limitClause = ""
        }
        return try database.query(
            "SELECT kind, source_path, title, body, transcript_start, transcript_end FROM search_chunks\(whereClause)\(orderClause)\(limitClause)",
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

    private func indexableFiles() throws -> [(url: URL, relativePath: String)] {
        guard let enumerator = FileManager.default.enumerator(
            at: workspaceRootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [(url: URL, relativePath: String)] = []
        for case let enumeratedURL as URL in enumerator {
            let url = enumeratedURL.resolvingSymlinksInPath()
            let relativePath = String(url.path.dropFirst(workspaceRootURL.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values.isDirectory == true && isExcluded(relativePath: relativePath, isDirectory: true, applyConfiguredPatterns: false) {
                enumerator.skipDescendants()
            } else if values.isRegularFile == true && isIndexable(relativePath: relativePath) {
                files.append((url, relativePath))
            }
        }
        return files.sorted { $0.relativePath < $1.relativePath }
    }

    private func isIndexable(relativePath: String) -> Bool {
        let path = relativePath.lowercased()
        let isLightweightMetadata = path.hasSuffix("/recording.localref.json") || path == "recording.localref.json"
        guard !isExcluded(relativePath: relativePath, isDirectory: false, applyConfiguredPatterns: !isLightweightMetadata) else { return false }
        if path.hasSuffix(".md") { return true }
        if path.hasSuffix("/transcript.vtt") || path == "transcript.vtt" { return true }
        if path.hasSuffix("/transcript.json") || path == "transcript.json" { return true }
        return isLightweightMetadata
    }

    private func isExcluded(relativePath: String, isDirectory: Bool, applyConfiguredPatterns: Bool = true) -> Bool {
        let normalized = Self.normalize(relativePath)
        let lowercased = normalized.lowercased()
        let components = lowercased.split(separator: "/").map(String.init)
        let noisyDirectories: Set<String> = [".git", ".obsidian", "node_modules", "dist", "build", ".build", ".cache", ".tmp", "snapshots", "logs"]
        if components.contains(where: noisyDirectories.contains) { return true }
        if !isDirectory {
            let filename = components.last ?? ""
            let excludedExtensions: Set<String> = [
                "m4a", "mp3", "wav", "caf", "mp4", "mov", "webm",
                "png", "jpg", "jpeg", "heic", "gif", "pdf", "zip", "tar", "gz",
                "sqlite", "sqlite-wal", "sqlite-shm", "db", "log"
            ]
            if excludedExtensions.contains(URL(fileURLWithPath: filename).pathExtension.lowercased()) { return true }
            if filename == ".ds_store" { return true }
        }
        return applyConfiguredPatterns && excludedPatterns.contains { Self.glob($0, matches: normalized, isDirectory: isDirectory) }
    }

    private func insertChunks(for relativePath: String, fileURL: URL) throws {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard let contents = String(data: data, encoding: .utf8) else { return }
        for chunk in Self.chunks(relativePath: relativePath, contents: contents) {
            try database.run(
                "INSERT INTO search_chunks (source_path, kind, title, body, transcript_start, transcript_end) VALUES (?, ?, ?, ?, ?, ?)",
                bindings: [
                    .text(relativePath), .text(chunk.kind.rawValue), .text(chunk.title), .text(chunk.body),
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
            let todoBodies = lines.compactMap(todoBody)
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

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#"), let firstText = trimmed.firstIndex(where: { $0 != "#" && !$0.isWhitespace }) {
                appendSection()
                title = String(trimmed[firstText...]).trimmingCharacters(in: .whitespaces)
            } else if title != nil {
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
        if path.hasPrefix("activities/") { return .activity }
        if path.hasPrefix("projects/") { return .project }
        if path.hasPrefix("reports/") { return .report }
        if path.hasPrefix("briefs/") { return .brief }
        return .markdown
    }

    private static func normalize(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    private static func glob(_ pattern: String, matches path: String, isDirectory: Bool) -> Bool {
        let normalizedPattern = normalize(pattern)
        var expression = "^"
        var index = normalizedPattern.startIndex
        while index < normalizedPattern.endIndex {
            let character = normalizedPattern[index]
            if character == "*" {
                let next = normalizedPattern.index(after: index)
                if next < normalizedPattern.endIndex && normalizedPattern[next] == "*" {
                    expression += ".*"
                    index = normalizedPattern.index(after: next)
                } else {
                    expression += "[^/]*"
                    index = next
                }
            } else if character == "?" {
                expression += "[^/]"
                index = normalizedPattern.index(after: index)
            } else {
                expression += NSRegularExpression.escapedPattern(for: String(character))
                index = normalizedPattern.index(after: index)
            }
        }
        expression += (isDirectory && normalizedPattern.hasSuffix("/**")) ? "(?:/.*)?$" : "$"
        return path.range(of: expression, options: [.regularExpression, .caseInsensitive]) != nil
            || (normalizedPattern.hasSuffix("/**") && path.caseInsensitiveCompare(String(normalizedPattern.dropLast(3))) == .orderedSame)
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
