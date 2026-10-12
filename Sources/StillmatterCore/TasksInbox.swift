import Foundation
import SQLite3

public enum InboxCategory: String, CaseIterable, Codable, Equatable {
    case required
    case review
    case attention

    public static let allDisplayCases: [InboxCategory] = [.required, .review, .attention]

    public var displayName: String {
        switch self {
        case .required: return "Required"
        case .review: return "Review"
        case .attention: return "Attention"
        }
    }
}

public enum InboxItemKind: String, Codable, Equatable {
    case weeklyReport
    case titleReview
    case proposal
    case failedJob
    case overdueTodo
    case cleanupProposal
}

public struct InboxItem: Equatable {
    public let id: String
    public let category: InboxCategory
    public let kind: InboxItemKind
    public let title: String
    public let sourceRef: String?
    public let details: String?
    public let createdAt: String

    public init(
        id: String,
        category: InboxCategory,
        kind: InboxItemKind,
        title: String,
        sourceRef: String?,
        details: String?,
        createdAt: String
    ) {
        self.id = id
        self.category = category
        self.kind = kind
        self.title = title
        self.sourceRef = sourceRef
        self.details = details
        self.createdAt = createdAt
    }
}

public enum ProposalReviewState: String, Codable, Equatable {
    case pending
    case accepted
    case referenceOnly
    case merged
    case dismissed
}

public struct ActionItemProposal: Equatable {
    public let id: String
    public let title: String
    public let sourceRef: String
    public let isObsolete: Bool

    public init(id: String, title: String, sourceRef: String, isObsolete: Bool = false) {
        self.id = id
        self.title = title
        self.sourceRef = sourceRef
        self.isObsolete = isObsolete
    }
}

public enum OperationalStoreError: Error, Equatable, CustomStringConvertible {
    case sqlite(code: Int32, message: String)
    case invalidStoredValue(column: String, value: String)

    public var description: String {
        switch self {
        case let .sqlite(code, message): return "SQLite error \(code): \(message)"
        case let .invalidStoredValue(column, value): return "Invalid stored \(column): \(value)"
        }
    }
}

/// Application service for the rebuildable SQLite-backed operational Inbox.
/// Canonical Markdown remains outside this store.
public final class TasksInbox {
    let databaseURL: URL
    private let database: SQLiteDatabase
    private let now: () -> String
    private let lock = NSRecursiveLock()

    public init(databaseURL: URL, now: @escaping () -> String = TasksInbox.systemTimestamp) throws {
        let parentURL = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)
        self.databaseURL = databaseURL.standardizedFileURL.resolvingSymlinksInPath()
        database = try SQLiteDatabase(url: databaseURL)
        self.now = now
        try migrate()
    }

    public func save(_ item: InboxItem) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveUnlocked(item)
    }

    /// Update Stillmatter-controlled Inbox and review references after a no-alias Meeting rename.
    public func rewriteMeetingReferences(from oldDirectory: String, to newDirectory: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            for table in ["inbox_items", "proposal_reviews"] {
                let column = "source_ref"
                let entries: [(String, String)] = try database.query(
                    "SELECT \(table == "inbox_items" ? "id" : "proposal_id"), \(column) FROM \(table) WHERE \(column) IS NOT NULL"
                ) { (SQLiteDatabase.text($0, column: 0), SQLiteDatabase.text($0, column: 1)) }
                for (id, source) in entries {
                    let updated = source.replacingOccurrences(of: oldDirectory + "/", with: newDirectory + "/")
                    guard updated != source else { continue }
                    try database.run("UPDATE \(table) SET source_ref = ? WHERE \(table == "inbox_items" ? "id" : "proposal_id") = ?",
                        bindings: [.text(updated), .text(id)])
                }
            }
        }
    }

    public func removeItem(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try database.run("DELETE FROM inbox_items WHERE id = ?", bindings: [.text(id)])
    }

    public func items(category: InboxCategory? = nil) throws -> [InboxItem] {
        lock.lock()
        defer { lock.unlock() }
        let sql: String
        let bindings: [SQLiteValue]
        if let category = category {
            sql = "SELECT id, category, kind, title, source_ref, details, created_at FROM inbox_items WHERE category = ? ORDER BY created_at, rowid"
            bindings = [.text(category.rawValue)]
        } else {
            sql = "SELECT id, category, kind, title, source_ref, details, created_at FROM inbox_items ORDER BY CASE category WHEN 'required' THEN 0 WHEN 'review' THEN 1 ELSE 2 END, created_at, rowid"
            bindings = []
        }
        return try database.query(sql, bindings: bindings) { statement in
            let categoryValue = SQLiteDatabase.text(statement, column: 1)
            let kindValue = SQLiteDatabase.text(statement, column: 2)
            guard let category = InboxCategory(rawValue: categoryValue) else {
                throw OperationalStoreError.invalidStoredValue(column: "category", value: categoryValue)
            }
            guard let kind = InboxItemKind(rawValue: kindValue) else {
                throw OperationalStoreError.invalidStoredValue(column: "kind", value: kindValue)
            }
            return InboxItem(
                id: SQLiteDatabase.text(statement, column: 0),
                category: category,
                kind: kind,
                title: SQLiteDatabase.text(statement, column: 3),
                sourceRef: SQLiteDatabase.optionalText(statement, column: 4),
                details: SQLiteDatabase.optionalText(statement, column: 5),
                createdAt: SQLiteDatabase.text(statement, column: 6)
            )
        }
    }

    public func requireTitleReview(id: String, title: String, sourceRef: String) throws {
        try save(InboxItem(
            id: id,
            category: .required,
            kind: .titleReview,
            title: title,
            sourceRef: sourceRef,
            details: nil,
            createdAt: now()
        ))
    }

    public func recordFailedJob(id: String, title: String, details: String) throws {
        try save(InboxItem(
            id: id,
            category: .attention,
            kind: .failedJob,
            title: title,
            sourceRef: nil,
            details: details,
            createdAt: now()
        ))
    }

    @discardableResult
    public func queueProposal(
        id: String,
        title: String,
        sourceRef: String,
        suppressionKey: String? = nil
    ) throws -> Bool {
        let savedTitle = try proposalDraft(id: id)?.title
        lock.lock()
        defer { lock.unlock() }
        let key = suppressionKey ?? id
        guard try !isProposalDismissedUnlocked(suppressionKey: key) else { return false }
        // Regeneration may encounter the same stable outcome ID again; review decisions
        // are user decisions, not generated state to be reset by a new Summary.
        if let existing = try proposalReviewState(id: id), existing != .pending { return false }

        try database.transaction {
            try database.run("""
                INSERT INTO proposal_reviews (proposal_id, state, suppression_key, source_ref, title, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(proposal_id) DO UPDATE SET
                    state = excluded.state,
                    suppression_key = excluded.suppression_key,
                    source_ref = excluded.source_ref,
                    title = excluded.title,
                    updated_at = excluded.updated_at
                """, bindings: [
                    .text(id), .text(ProposalReviewState.pending.rawValue), .text(key),
                    .text(sourceRef), .text(savedTitle ?? title), .text(now())
                ])
            try saveUnlocked(InboxItem(
                id: id,
                category: .review,
                kind: .proposal,
                title: savedTitle ?? title,
                sourceRef: sourceRef,
                details: nil,
                createdAt: now()
            ))
        }
        return true
    }

    /// Reconcile only pending proposals from this Meeting after a validated Summary is published.
    /// Reviewed decisions remain in proposal_reviews; unsupported pending items stay visible with
    /// durable provenance instead of masquerading as current Action Items.
    public func reconcileMeetingProposals(sessionID: String, sourceRef: String, currentIDs: Set<String>) throws {
        lock.lock()
        defer { lock.unlock() }
        let prefix = "meeting-action:\(sessionID):"
        try database.transaction {
            let pending: [String] = try database.query(
                "SELECT proposal_id FROM proposal_reviews WHERE state = ? AND source_ref = ?",
                bindings: [.text(ProposalReviewState.pending.rawValue), .text(sourceRef)]
            ) { SQLiteDatabase.text($0, column: 0) }
            for id in pending where id.hasPrefix(prefix) {
                try database.run("UPDATE inbox_items SET details = ?, updated_at = ? WHERE id = ? AND kind = ?",
                    bindings: [currentIDs.contains(id) ? .null : .text("Not supported by the current Summary"),
                               .text(now()), .text(id), .text(InboxItemKind.proposal.rawValue)])
            }
        }
    }

    public func setProposalReviewState(id: String, state: ProposalReviewState) throws {
        try setProposalReviewStates(ids: [id], state: state)
    }

    public func setProposalReviewStates(ids: [String], state: ProposalReviewState) throws {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            for id in ids {
                if state == .dismissed {
                    let suppressionKeys: [String] = try database.query(
                        "SELECT suppression_key FROM proposal_reviews WHERE proposal_id = ?",
                        bindings: [.text(id)]
                    ) { SQLiteDatabase.text($0, column: 0) }
                    if let suppressionKey = suppressionKeys.first {
                        try database.run("""
                            INSERT INTO dismissed_proposals (suppression_key, dismissed_at)
                            VALUES (?, ?)
                            ON CONFLICT(suppression_key) DO UPDATE SET dismissed_at = excluded.dismissed_at
                            """, bindings: [.text(suppressionKey), .text(now())])
                    }
                }
                try database.run(
                    "UPDATE proposal_reviews SET state = ?, updated_at = ? WHERE proposal_id = ?",
                    bindings: [.text(state.rawValue), .text(now()), .text(id)]
                )
                if state != .pending {
                    try database.run("DELETE FROM inbox_items WHERE id = ? AND kind = ?", bindings: [.text(id), .text(InboxItemKind.proposal.rawValue)])
                }
            }
        }
    }

    public func proposalReviewState(id: String) throws -> ProposalReviewState? {
        lock.lock()
        defer { lock.unlock() }
        let values: [String] = try database.query(
            "SELECT state FROM proposal_reviews WHERE proposal_id = ?",
            bindings: [.text(id)]
        ) { SQLiteDatabase.text($0, column: 0) }
        guard let value = values.first else { return nil }
        guard let state = ProposalReviewState(rawValue: value) else {
            throw OperationalStoreError.invalidStoredValue(column: "proposal state", value: value)
        }
        return state
    }

    /// User-authored draft remains separate from generated evidence and review state.
    public func saveProposalDraft(id: String, title: String, comment: String) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, try pendingProposal(id: id) != nil else { throw ActionItemProposalReviewError.proposalNotPending(id) }
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            try database.run("INSERT INTO proposal_edits (proposal_id, title, comment) VALUES (?, ?, ?) ON CONFLICT(proposal_id) DO UPDATE SET title = excluded.title, comment = excluded.comment",
                bindings: [.text(id), .text(title), .text(comment)])
            try database.run("UPDATE inbox_items SET title = ?, updated_at = ? WHERE id = ?", bindings: [.text(title), .text(now()), .text(id)])
        }
    }

    public func proposalDraft(id: String) throws -> (title: String, comment: String)? {
        lock.lock()
        defer { lock.unlock() }
        return try database.query("SELECT title, comment FROM proposal_edits WHERE proposal_id = ?", bindings: [.text(id)]) { statement in
            (SQLiteDatabase.text(statement, column: 0), SQLiteDatabase.text(statement, column: 1))
        }.first
    }

    public func pendingProposal(id: String) throws -> ActionItemProposal? {
        lock.lock()
        defer { lock.unlock() }
        return try database.query(
            "SELECT r.proposal_id, COALESCE(e.title, r.title), r.source_ref, i.details FROM proposal_reviews r LEFT JOIN inbox_items i ON i.id = r.proposal_id LEFT JOIN proposal_edits e ON e.proposal_id = r.proposal_id WHERE r.proposal_id = ? AND r.state = ?",
            bindings: [.text(id), .text(ProposalReviewState.pending.rawValue)]
        ) { statement in
            ActionItemProposal(
                id: SQLiteDatabase.text(statement, column: 0),
                title: SQLiteDatabase.text(statement, column: 1),
                sourceRef: SQLiteDatabase.text(statement, column: 2),
                isObsolete: SQLiteDatabase.optionalText(statement, column: 3) == "Not supported by the current Summary"
            )
        }.first
    }

    public func dismissProposal(id: String, suppressionKey: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            try database.run("""
                INSERT INTO dismissed_proposals (suppression_key, dismissed_at)
                VALUES (?, ?)
                ON CONFLICT(suppression_key) DO UPDATE SET dismissed_at = excluded.dismissed_at
                """, bindings: [.text(suppressionKey), .text(now())])
            try database.run(
                "UPDATE proposal_reviews SET state = ?, suppression_key = ?, updated_at = ? WHERE proposal_id = ?",
                bindings: [.text(ProposalReviewState.dismissed.rawValue), .text(suppressionKey), .text(now()), .text(id)]
            )
            try database.run("DELETE FROM inbox_items WHERE id = ? AND kind = ?", bindings: [.text(id), .text(InboxItemKind.proposal.rawValue)])
        }
    }

    public func isProposalDismissed(suppressionKey: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return try isProposalDismissedUnlocked(suppressionKey: suppressionKey)
    }

    public func syncOverdueTodos(_ todos: [TodoItem], today: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let overdue = todos.filter { item in
            guard let dueDate = item.dueDate else { return false }
            return dueDate < today && item.status != .done && item.status != .canceled
        }
        try database.transaction {
            try database.run("DELETE FROM inbox_items WHERE kind = ?", bindings: [.text(InboxItemKind.overdueTodo.rawValue)])
            for item in overdue {
                try saveUnlocked(InboxItem(
                    id: "overdue:\(item.id)",
                    category: .attention,
                    kind: .overdueTodo,
                    title: item.title,
                    sourceRef: item.sourceRef ?? "\(item.location.relativePath):\(item.location.lineNumber)",
                    details: "due: \(item.dueDate ?? "")",
                    createdAt: now()
                ))
            }
        }
    }

    public static func systemTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    private func migrate() throws {
        lock.lock()
        defer { lock.unlock() }
        try database.run("PRAGMA foreign_keys = ON")
        try database.run("PRAGMA journal_mode = WAL")
        try database.transaction {
            try database.run("CREATE TABLE IF NOT EXISTS schema_metadata (version INTEGER NOT NULL)")
            try database.run("INSERT INTO schema_metadata (version) SELECT 1 WHERE NOT EXISTS (SELECT 1 FROM schema_metadata)")
            try database.run("""
                CREATE TABLE IF NOT EXISTS inbox_items (
                    id TEXT PRIMARY KEY NOT NULL,
                    category TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    title TEXT NOT NULL,
                    source_ref TEXT,
                    details TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
            try database.run("CREATE INDEX IF NOT EXISTS inbox_items_category_index ON inbox_items (category, created_at)")
            try database.run("CREATE TABLE IF NOT EXISTS proposal_edits (proposal_id TEXT PRIMARY KEY NOT NULL, title TEXT NOT NULL, comment TEXT NOT NULL)")
            try database.run("""
                CREATE TABLE IF NOT EXISTS dismissed_proposals (
                    suppression_key TEXT PRIMARY KEY NOT NULL,
                    dismissed_at TEXT NOT NULL
                )
                """)
            try database.run("""
                CREATE TABLE IF NOT EXISTS proposal_reviews (
                    proposal_id TEXT PRIMARY KEY NOT NULL,
                    state TEXT NOT NULL,
                    suppression_key TEXT NOT NULL,
                    source_ref TEXT NOT NULL,
                    title TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """)
        }
    }

    private func saveUnlocked(_ item: InboxItem) throws {
        try database.run("""
            INSERT INTO inbox_items (id, category, kind, title, source_ref, details, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                category = excluded.category,
                kind = excluded.kind,
                title = excluded.title,
                source_ref = excluded.source_ref,
                details = excluded.details,
                updated_at = excluded.updated_at
            """, bindings: [
                .text(item.id), .text(item.category.rawValue), .text(item.kind.rawValue), .text(item.title),
                item.sourceRef.map(SQLiteValue.text) ?? .null,
                item.details.map(SQLiteValue.text) ?? .null,
                .text(item.createdAt), .text(now())
            ])
    }

    private func isProposalDismissedUnlocked(suppressionKey: String) throws -> Bool {
        let matches: [Int32] = try database.query(
            "SELECT 1 FROM dismissed_proposals WHERE suppression_key = ? LIMIT 1",
            bindings: [.text(suppressionKey)]
        ) { sqlite3_column_int($0, 0) }
        return !matches.isEmpty
    }
}

private enum SQLiteValue {
    case text(String)
    case null
}

private final class SQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            if let handle = handle { sqlite3_close(handle) }
            handle = nil
            throw OperationalStoreError.sqlite(code: result, message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle = handle { sqlite3_close(handle) }
    }

    func run(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error(code: result) }
    }

    func query<T>(_ sql: String, bindings: [SQLiteValue] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
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

    static func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    static func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column: column)
    }

    private func prepare(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
        guard let handle = handle else { throw OperationalStoreError.sqlite(code: SQLITE_MISUSE, message: "Database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let prepared = statement else { throw error(code: result) }
        do {
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let bindResult: Int32
                switch value {
                case let .text(text):
                    bindResult = sqlite3_bind_text(prepared, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                case .null:
                    bindResult = sqlite3_bind_null(prepared, index)
                }
                guard bindResult == SQLITE_OK else { throw error(code: bindResult) }
            }
            return prepared
        } catch {
            sqlite3_finalize(prepared)
            throw error
        }
    }

    private func error(code: Int32) -> OperationalStoreError {
        let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
        return .sqlite(code: code, message: message)
    }
}
