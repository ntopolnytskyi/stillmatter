import Foundation
import SQLite3

public enum JobExecutionClass: String, Codable, Equatable {
    case heavy
    case lightweight
}

public enum JobStatus: String, Codable, Equatable {
    case queued
    case running
    case succeeded
    case failed
    case dismissed
}

public enum JobStageStatus: String, Codable, Equatable {
    case pending
    case running
    case succeeded
    case failed
}

public struct JobStageDefinition: Codable, Equatable {
    public let id: String
    public let title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

public struct JobArtifactReference: Codable, Equatable {
    public let relativePath: String
    public let role: String

    public init(relativePath: String, role: String) {
        self.relativePath = relativePath
        self.role = role
    }
}

/// Declares a generated file that must pass validation before a job stage can succeed.
/// The framework deliberately does not apply generated files to the canonical workspace.
public struct GeneratedArtifactExpectation: Codable, Equatable {
    public let stageID: String
    public let relativePath: String
    public let validatorID: String
    public let required: Bool
    public let requiredFrontmatterFields: [String]
    public let requiredHeadings: [String]

    public init(
        stageID: String,
        relativePath: String,
        validatorID: String,
        required: Bool = true,
        requiredFrontmatterFields: [String] = [],
        requiredHeadings: [String] = []
    ) {
        self.stageID = stageID
        self.relativePath = relativePath
        self.validatorID = validatorID
        self.required = required
        self.requiredFrontmatterFields = requiredFrontmatterFields
        self.requiredHeadings = requiredHeadings
    }
}

/// A versioned, persisted contract for one app-owned unit of work.
public struct JobManifest: Codable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let type: String
    public let title: String
    public let executionClass: JobExecutionClass
    public let stages: [JobStageDefinition]
    public let sourceArtifacts: [JobArtifactReference]
    public let expectedOutputs: [GeneratedArtifactExpectation]
    public let metadata: [String: String]
    public let maxAutomaticRetries: Int

    public init(
        version: Int = JobManifest.currentVersion,
        type: String,
        title: String,
        executionClass: JobExecutionClass,
        stages: [JobStageDefinition],
        sourceArtifacts: [JobArtifactReference] = [],
        expectedOutputs: [GeneratedArtifactExpectation] = [],
        metadata: [String: String] = [:],
        maxAutomaticRetries: Int = 1
    ) {
        self.version = version
        self.type = type
        self.title = title
        self.executionClass = executionClass
        self.stages = stages
        self.sourceArtifacts = sourceArtifacts
        self.expectedOutputs = expectedOutputs
        self.metadata = metadata
        self.maxAutomaticRetries = max(0, maxAutomaticRetries)
    }
}

public struct JobStageRecord: Equatable {
    public let definition: JobStageDefinition
    public let status: JobStageStatus
    public let attemptCount: Int
    public let lastError: String?
    public let startedAt: String?
    public let finishedAt: String?
}

public struct JobRecord: Equatable {
    public let id: String
    public let manifest: JobManifest
    public let status: JobStatus
    public let stages: [JobStageRecord]
    public let createdAt: String
    public let updatedAt: String
    public let failureDetails: String?
}

public struct JobLogEntry: Equatable {
    public let sequence: Int
    public let timestamp: String
    public let level: String
    public let message: String
}

public struct JobDetails: Equatable {
    public let job: JobRecord
    public let logs: [JobLogEntry]
}

public struct GeneratedArtifact: Equatable {
    public let relativePath: String
    public let data: Data

    public init(relativePath: String, data: Data) {
        self.relativePath = relativePath
        self.data = data
    }
}

public struct JobStageResult: Equatable {
    public let artifacts: [GeneratedArtifact]
    public let logMessages: [String]

    public init(artifacts: [GeneratedArtifact] = [], logMessages: [String] = []) {
        self.artifacts = artifacts
        self.logMessages = logMessages
    }
}

public protocol GeneratedArtifactValidator {
    func validate(_ artifact: GeneratedArtifact, expectation: GeneratedArtifactExpectation) throws
}

public struct JSONGeneratedArtifactValidator: GeneratedArtifactValidator {
    public init() {}

    public func validate(_ artifact: GeneratedArtifact, expectation: GeneratedArtifactExpectation) throws {
        do {
            _ = try JSONSerialization.jsonObject(with: artifact.data)
        } catch {
            throw JobsError.invalidArtifact(path: artifact.relativePath, reason: "Invalid JSON: \(error)")
        }
    }
}

public struct WebVTTGeneratedArtifactValidator: GeneratedArtifactValidator {
    public init() {}

    public func validate(_ artifact: GeneratedArtifact, expectation: GeneratedArtifactExpectation) throws {
        guard let text = String(data: artifact.data, encoding: .utf8) else {
            throw JobsError.invalidArtifact(path: artifact.relativePath, reason: "WebVTT is not UTF-8")
        }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("WEBVTT\n") else {
            throw JobsError.invalidArtifact(path: artifact.relativePath, reason: "Missing WEBVTT header")
        }
        let timingPattern = #"(?m)^\d{2}:\d{2}:\d{2}\.\d{3} --> \d{2}:\d{2}:\d{2}\.\d{3}$"#
        guard normalized.range(of: timingPattern, options: .regularExpression) != nil || !normalized.contains("<v ") else {
            throw JobsError.invalidArtifact(path: artifact.relativePath, reason: "Missing a valid cue timestamp")
        }
    }
}

public struct MarkdownGeneratedArtifactValidator: GeneratedArtifactValidator {
    public init() {}

    public func validate(_ artifact: GeneratedArtifact, expectation: GeneratedArtifactExpectation) throws {
        guard let text = String(data: artifact.data, encoding: .utf8) else {
            throw JobsError.invalidArtifact(path: artifact.relativePath, reason: "Markdown is not UTF-8")
        }
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let closing = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            throw JobsError.invalidArtifact(path: artifact.relativePath, reason: "Missing frontmatter")
        }
        let frontmatter = lines[lines.index(after: lines.startIndex)..<closing]
        for field in expectation.requiredFrontmatterFields {
            guard frontmatter.contains(where: { $0.hasPrefix(field + ":") }) else {
                throw JobsError.invalidArtifact(path: artifact.relativePath, reason: "Missing frontmatter field \(field)")
            }
        }
        let headings = Set(lines.compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") else { return nil }
            return trimmed.drop(while: { $0 == "#" || $0.isWhitespace }).trimmingCharacters(in: .whitespaces)
        })
        for heading in expectation.requiredHeadings where !headings.contains(heading) {
            throw JobsError.invalidArtifact(path: artifact.relativePath, reason: "Missing heading \(heading)")
        }
    }
}

public protocol JobExecuting: AnyObject {
    func execute(
        job: JobRecord,
        stage: JobStageDefinition,
        completion: @escaping (Result<JobStageResult, Error>) -> Void
    )
}

public enum JobsError: Error, Equatable, CustomStringConvertible {
    case sqlite(code: Int32, message: String)
    case unsupportedManifestVersion(Int)
    case invalidManifest(String)
    case duplicateJob(String)
    case jobNotFound(String)
    case jobNotRetryable(String)
    case unknownValidator(String)
    case missingArtifact(String)
    case unexpectedArtifact(String)
    case invalidArtifact(path: String, reason: String)
    case invalidStoredValue(column: String, value: String)

    public var description: String {
        switch self {
        case let .sqlite(code, message): return "SQLite jobs error \(code): \(message)"
        case let .unsupportedManifestVersion(version): return "Unsupported job manifest version: \(version)"
        case let .invalidManifest(reason): return "Invalid job manifest: \(reason)"
        case let .duplicateJob(id): return "A job already exists with id \(id)"
        case let .jobNotFound(id): return "Job not found: \(id)"
        case let .jobNotRetryable(id): return "Job cannot be retried: \(id)"
        case let .unknownValidator(id): return "Unknown generated artifact validator: \(id)"
        case let .missingArtifact(path): return "Required generated artifact is missing: \(path)"
        case let .unexpectedArtifact(path): return "Generated artifact was not declared in the manifest: \(path)"
        case let .invalidArtifact(path, reason): return "Invalid generated artifact \(path): \(reason)"
        case let .invalidStoredValue(column, value): return "Invalid stored \(column): \(value)"
        }
    }
}

/// SQLite-backed operational state for typed jobs. Canonical workspace content is never stored here.
public final class JobStore {
    private let database: JobSQLiteDatabase
    private let now: () -> String
    private let inbox: TasksInbox?
    private let lock = NSRecursiveLock()

    public init(
        databaseURL: URL,
        inbox: TasksInbox? = nil,
        now: @escaping () -> String = TasksInbox.systemTimestamp
    ) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        database = try JobSQLiteDatabase(url: databaseURL)
        self.inbox = inbox
        self.now = now
        try migrate()
        try recoverInterruptedJobs()
    }

    public func enqueue(id: String = UUID().uuidString, manifest: JobManifest) throws -> JobRecord {
        lock.lock()
        defer { lock.unlock() }
        return try enqueueUnlocked(id: id, manifest: manifest)
    }

    /// Serialize the Meeting guard and insert across JobStore connections, not just threads
    /// sharing this instance's lock.
    public func enqueueUnlessActive(id: String = UUID().uuidString, manifest: JobManifest,
                                    belongsToMeeting: (JobRecord) -> Bool) throws -> JobRecord {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            guard !((try jobsUnlocked()).contains { belongsToMeeting($0) && ($0.status == .queued || $0.status == .running) }) else {
                throw JobsError.invalidManifest("This Meeting already has processing work in progress.")
            }
            _ = try enqueueUnlocked(id: id, manifest: manifest, inTransaction: true)
        }
        return try requireRecordUnlocked(id: id)
    }

    private var renamingMeeting = false

    /// Hold a cross-connection write transaction while the folder and its references move.
    /// An enqueue cannot slip between the active-Job check and the move.
    public func performRenameUnlessActive(belongsToMeeting: (JobRecord) -> Bool,
                                           _ action: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            guard !(try jobsUnlocked()).contains(where: {
                belongsToMeeting($0) && ($0.status == .queued || $0.status == .running)
            }) else { throw JobsError.invalidManifest("This Meeting has processing work in progress.") }
            renamingMeeting = true
            defer { renamingMeeting = false }
            try action()
        }
    }

    /// Repoint persisted inactive Job manifests after a canonical Meeting move.
    public func rewriteMeetingReferences(from oldDirectory: String, to newDirectory: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let rewrite = {
            let records = try self.jobsUnlocked()
            for job in records {
                let data = try JSONEncoder().encode(job.manifest)
                let raw = try JSONSerialization.jsonObject(with: data)
                func rewrite(_ value: Any) -> Any {
                    if let text = value as? String {
                        return text.replacingOccurrences(of: oldDirectory + "/", with: newDirectory + "/")
                    }
                    if let entries = value as? [String: Any] {
                        return entries.mapValues(rewrite)
                    }
                    if let entries = value as? [Any] { return entries.map(rewrite) }
                    return value
                }
                let updated = try JSONSerialization.data(withJSONObject: rewrite(raw))
                guard try JSONDecoder().decode(JobManifest.self, from: updated) != job.manifest else { continue }
                guard job.status != .queued && job.status != .running else {
                    throw JobsError.invalidManifest("This Meeting has processing work in progress.")
                }
                guard let json = String(data: updated, encoding: .utf8) else { continue }
                try self.database.run("UPDATE jobs SET manifest_json = ? WHERE id = ?", bindings: [.text(json), .text(job.id)])
            }
        }
        if renamingMeeting { try rewrite() } else { try database.transaction(rewrite) }
    }

    private func enqueueUnlocked(id: String, manifest: JobManifest, inTransaction: Bool = false) throws -> JobRecord {
        try validate(manifest)
        guard try recordUnlocked(id: id) == nil else { throw JobsError.duplicateJob(id) }
        let encoded = try JSONEncoder().encode(manifest)
        guard let manifestJSON = String(data: encoded, encoding: .utf8) else {
            throw JobsError.invalidManifest("Manifest could not be encoded")
        }
        let timestamp = now()
        let insert = {
            try self.database.run(
                "INSERT INTO jobs (id, manifest_json, status, created_at, updated_at, failure_details) VALUES (?, ?, ?, ?, ?, NULL)",
                bindings: [.text(id), .text(manifestJSON), .text(JobStatus.queued.rawValue), .text(timestamp), .text(timestamp)]
            )
            for (position, stage) in manifest.stages.enumerated() {
                try self.database.run(
                    "INSERT INTO job_stages (job_id, stage_id, title, position, status, attempt_count) VALUES (?, ?, ?, ?, ?, 0)",
                    bindings: [.text(id), .text(stage.id), .text(stage.title), .integer(position), .text(JobStageStatus.pending.rawValue)]
                )
            }
            try self.appendLogUnlocked(jobID: id, level: "info", message: "Job queued")
        }
        if inTransaction { try insert() } else { try database.transaction(insert) }
        return try requireRecordUnlocked(id: id)
    }

    public func job(id: String) throws -> JobRecord? {
        lock.lock()
        defer { lock.unlock() }
        return try recordUnlocked(id: id)
    }

    private func jobsUnlocked() throws -> [JobRecord] {
        let ids = try database.query("SELECT id FROM jobs ORDER BY created_at, rowid") { JobSQLiteDatabase.text($0, column: 0) }
        return try ids.map(requireRecordUnlocked)
    }

    public func jobs(status: JobStatus? = nil) throws -> [JobRecord] {
        lock.lock()
        defer { lock.unlock() }
        let ids: [String]
        if let status = status {
            ids = try database.query("SELECT id FROM jobs WHERE status = ? ORDER BY created_at, rowid", bindings: [.text(status.rawValue)]) {
                JobSQLiteDatabase.text($0, column: 0)
            }
        } else {
            ids = try database.query("SELECT id FROM jobs ORDER BY created_at, rowid") { JobSQLiteDatabase.text($0, column: 0) }
        }
        return try ids.map(requireRecordUnlocked)
    }

    public func details(id: String) throws -> JobDetails {
        lock.lock()
        defer { lock.unlock() }
        let job = try requireRecordUnlocked(id: id)
        let logs: [JobLogEntry] = try database.query(
            "SELECT sequence, timestamp, level, message FROM job_logs WHERE job_id = ? ORDER BY sequence",
            bindings: [.text(id)]
        ) { statement in
            JobLogEntry(
                sequence: JobSQLiteDatabase.integer(statement, column: 0),
                timestamp: JobSQLiteDatabase.text(statement, column: 1),
                level: JobSQLiteDatabase.text(statement, column: 2),
                message: JobSQLiteDatabase.text(statement, column: 3)
            )
        }
        return JobDetails(job: job, logs: logs)
    }

    /// Resets only the failed stage and later stages, preserving completed stage state for resumability.
    public func retry(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let job = try requireRecordUnlocked(id: id)
        guard job.status == .failed, let failedStage = job.stages.first(where: { $0.status == .failed }) else {
            throw JobsError.jobNotRetryable(id)
        }
        try resetUnlocked(job: job, fromStageID: failedStage.definition.id, logMessage: "Manual retry requested")
        try inbox?.removeItem(id: inboxID(jobID: id))
    }

    /// Atomically rejects active work belonging to the Meeting and resets its failed Job.
    public func retry(id: String, meetingRelativePath: String, captureSessionID: String? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        let directory = (meetingRelativePath as NSString).deletingLastPathComponent + "/"
        func belongsToMeeting(_ candidate: JobRecord) -> Bool {
            (captureSessionID != nil && candidate.manifest.metadata["capture_session_id"] == captureSessionID)
                || candidate.manifest.sourceArtifacts.contains { $0.relativePath == meetingRelativePath || $0.relativePath.hasPrefix(directory) }
                || candidate.manifest.expectedOutputs.contains { $0.relativePath.hasPrefix(directory) }
        }
        // The immediate transaction serializes the check and reset across separate JobStore connections.
        try database.transaction {
            let job = try requireRecordUnlocked(id: id)
            guard belongsToMeeting(job) else { throw JobsError.jobNotRetryable("Job does not belong to this Meeting") }
            guard !((try jobsUnlocked()).contains { $0.id != id && belongsToMeeting($0) && ($0.status == .queued || $0.status == .running) }) else {
                throw JobsError.jobNotRetryable("Meeting already has active processing work")
            }
            guard job.status == .failed, let failedStage = job.stages.first(where: { $0.status == .failed }) else { throw JobsError.jobNotRetryable(id) }
            try resetUnlocked(job: job, fromStageID: failedStage.definition.id, logMessage: "Manual retry requested", inTransaction: true)
        }
        try inbox?.removeItem(id: inboxID(jobID: id))
    }

    /// Explicitly reruns a stage and every later stage while retaining prior successful stages.
    public func rerun(id: String, fromStageID stageID: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let job = try requireRecordUnlocked(id: id)
        guard job.status != .running && job.status != .queued,
              job.stages.contains(where: { $0.definition.id == stageID }) else {
            throw JobsError.jobNotRetryable(id)
        }
        try resetUnlocked(job: job, fromStageID: stageID, logMessage: "Rerun requested from stage \(stageID)")
        try inbox?.removeItem(id: inboxID(jobID: id))
    }

    public func dismiss(id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let job = try requireRecordUnlocked(id: id)
        guard job.status == .failed else { throw JobsError.invalidManifest("Only failed jobs can be dismissed") }
        try database.transaction {
            try database.run(
                "UPDATE jobs SET status = ?, updated_at = ? WHERE id = ?",
                bindings: [.text(JobStatus.dismissed.rawValue), .text(now()), .text(id)]
            )
            try appendLogUnlocked(jobID: id, level: "info", message: "Failure dismissed")
        }
        try inbox?.removeItem(id: inboxID(jobID: id))
    }

    fileprivate func beginNextStage(jobID: String) throws -> (JobRecord, JobStageDefinition)? {
        lock.lock()
        defer { lock.unlock() }
        let job = try requireRecordUnlocked(id: jobID)
        guard job.status == .queued || job.status == .running,
              let stage = job.stages.first(where: { $0.status == .pending || $0.status == .failed }) else { return nil }
        let timestamp = now()
        try database.transaction {
            try database.run(
                "UPDATE job_stages SET status = ?, attempt_count = attempt_count + 1, last_error = NULL, started_at = ?, finished_at = NULL WHERE job_id = ? AND stage_id = ?",
                bindings: [.text(JobStageStatus.running.rawValue), .text(timestamp), .text(jobID), .text(stage.definition.id)]
            )
            try database.run(
                "UPDATE jobs SET status = ?, failure_details = NULL, updated_at = ? WHERE id = ?",
                bindings: [.text(JobStatus.running.rawValue), .text(timestamp), .text(jobID)]
            )
            try appendLogUnlocked(jobID: jobID, level: "info", message: "Started stage \(stage.definition.id)")
        }
        return (try requireRecordUnlocked(id: jobID), stage.definition)
    }

    fileprivate func completeStage(jobID: String, stageID: String, messages: [String]) throws {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now()
        try database.transaction {
            for message in messages {
                try appendLogUnlocked(jobID: jobID, level: "info", message: message)
            }
            try database.run(
                "UPDATE job_stages SET status = ?, finished_at = ? WHERE job_id = ? AND stage_id = ?",
                bindings: [.text(JobStageStatus.succeeded.rawValue), .text(timestamp), .text(jobID), .text(stageID)]
            )
            let pending: [Int] = try database.query(
                "SELECT COUNT(*) FROM job_stages WHERE job_id = ? AND status != ?",
                bindings: [.text(jobID), .text(JobStageStatus.succeeded.rawValue)]
            ) { JobSQLiteDatabase.integer($0, column: 0) }
            let status: JobStatus = pending.first == 0 ? .succeeded : .queued
            try database.run(
                "UPDATE jobs SET status = ?, updated_at = ? WHERE id = ?",
                bindings: [.text(status.rawValue), .text(timestamp), .text(jobID)]
            )
            try appendLogUnlocked(jobID: jobID, level: "info", message: "Completed stage \(stageID)")
        }
        if try requireRecordUnlocked(id: jobID).status == .succeeded {
            try inbox?.removeItem(id: inboxID(jobID: jobID))
        }
    }

    fileprivate func failStage(jobID: String, stageID: String, error: Error) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let job = try requireRecordUnlocked(id: jobID)
        guard let stage = job.stages.first(where: { $0.definition.id == stageID }) else {
            throw JobsError.invalidManifest("Unknown stage \(stageID)")
        }
        let message = String(describing: error)
        let willRetry = stage.attemptCount <= job.manifest.maxAutomaticRetries
        let timestamp = now()
        try database.transaction {
            try database.run(
                "UPDATE job_stages SET status = ?, last_error = ?, finished_at = ? WHERE job_id = ? AND stage_id = ?",
                bindings: [
                    .text(willRetry ? JobStageStatus.pending.rawValue : JobStageStatus.failed.rawValue),
                    .text(message), .text(timestamp), .text(jobID), .text(stageID)
                ]
            )
            try database.run(
                "UPDATE jobs SET status = ?, failure_details = ?, updated_at = ? WHERE id = ?",
                bindings: [
                    .text(willRetry ? JobStatus.queued.rawValue : JobStatus.failed.rawValue),
                    .text(message), .text(timestamp), .text(jobID)
                ]
            )
            try appendLogUnlocked(
                jobID: jobID,
                level: willRetry ? "warning" : "error",
                message: willRetry ? "Stage \(stageID) failed; retrying: \(message)" : "Stage \(stageID) failed: \(message)"
            )
        }
        if !willRetry {
            try inbox?.recordFailedJob(
                id: inboxID(jobID: jobID),
                title: "\(job.manifest.title) failed",
                details: message
            )
        }
        return willRetry
    }

    private func validate(_ manifest: JobManifest) throws {
        guard manifest.version == JobManifest.currentVersion else {
            throw JobsError.unsupportedManifestVersion(manifest.version)
        }
        guard !manifest.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw JobsError.invalidManifest("type is required")
        }
        guard !manifest.stages.isEmpty else { throw JobsError.invalidManifest("at least one stage is required") }
        let stageIDs = manifest.stages.map(\.id)
        guard Set(stageIDs).count == stageIDs.count, !stageIDs.contains(where: { $0.isEmpty }) else {
            throw JobsError.invalidManifest("stage ids must be non-empty and unique")
        }
        guard manifest.expectedOutputs.allSatisfy({ stageIDs.contains($0.stageID) }) else {
            throw JobsError.invalidManifest("expected outputs must reference a declared stage")
        }
        let outputKeys = manifest.expectedOutputs.map { "\($0.stageID)\u{0}\($0.relativePath)" }
        guard Set(outputKeys).count == outputKeys.count else {
            throw JobsError.invalidManifest("expected output paths must be unique within a stage")
        }
    }

    private func migrate() throws {
        lock.lock()
        defer { lock.unlock() }
        try database.run("PRAGMA journal_mode = WAL")
        try database.run("PRAGMA foreign_keys = ON")
        try database.transaction {
            try database.run("""
                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY NOT NULL,
                    manifest_json TEXT NOT NULL,
                    status TEXT NOT NULL,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    failure_details TEXT
                )
                """)
            try database.run("""
                CREATE TABLE IF NOT EXISTS job_stages (
                    job_id TEXT NOT NULL,
                    stage_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    status TEXT NOT NULL,
                    attempt_count INTEGER NOT NULL,
                    last_error TEXT,
                    started_at TEXT,
                    finished_at TEXT,
                    PRIMARY KEY (job_id, stage_id),
                    FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE
                )
                """)
            try database.run("""
                CREATE TABLE IF NOT EXISTS job_logs (
                    job_id TEXT NOT NULL,
                    sequence INTEGER NOT NULL,
                    timestamp TEXT NOT NULL,
                    level TEXT NOT NULL,
                    message TEXT NOT NULL,
                    PRIMARY KEY (job_id, sequence),
                    FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE
                )
                """)
            try database.run("CREATE INDEX IF NOT EXISTS jobs_status_index ON jobs (status, created_at)")
        }
    }

    private func recoverInterruptedJobs() throws {
        lock.lock()
        defer { lock.unlock() }
        try database.transaction {
            try database.run(
                "UPDATE job_stages SET status = ?, last_error = ? WHERE status = ?",
                bindings: [.text(JobStageStatus.pending.rawValue), .text("Interrupted before completion"), .text(JobStageStatus.running.rawValue)]
            )
            try database.run(
                "UPDATE jobs SET status = ?, failure_details = ?, updated_at = ? WHERE status = ?",
                bindings: [.text(JobStatus.queued.rawValue), .text("Interrupted before completion"), .text(now()), .text(JobStatus.running.rawValue)]
            )
        }
    }

    private func recordUnlocked(id: String) throws -> JobRecord? {
        let rows: [(String, String, String, String, String?)] = try database.query(
            "SELECT manifest_json, status, created_at, updated_at, failure_details FROM jobs WHERE id = ?",
            bindings: [.text(id)]
        ) { statement in
            (
                JobSQLiteDatabase.text(statement, column: 0),
                JobSQLiteDatabase.text(statement, column: 1),
                JobSQLiteDatabase.text(statement, column: 2),
                JobSQLiteDatabase.text(statement, column: 3),
                JobSQLiteDatabase.optionalText(statement, column: 4)
            )
        }
        guard let row = rows.first else { return nil }
        guard let manifestData = row.0.data(using: .utf8),
              let manifest = try? JSONDecoder().decode(JobManifest.self, from: manifestData) else {
            throw JobsError.invalidStoredValue(column: "manifest_json", value: row.0)
        }
        guard let status = JobStatus(rawValue: row.1) else {
            throw JobsError.invalidStoredValue(column: "job status", value: row.1)
        }
        let stages: [JobStageRecord] = try database.query(
            "SELECT stage_id, title, status, attempt_count, last_error, started_at, finished_at FROM job_stages WHERE job_id = ? ORDER BY position",
            bindings: [.text(id)]
        ) { statement in
            let storedStatus = JobSQLiteDatabase.text(statement, column: 2)
            guard let stageStatus = JobStageStatus(rawValue: storedStatus) else {
                throw JobsError.invalidStoredValue(column: "stage status", value: storedStatus)
            }
            return JobStageRecord(
                definition: JobStageDefinition(
                    id: JobSQLiteDatabase.text(statement, column: 0),
                    title: JobSQLiteDatabase.text(statement, column: 1)
                ),
                status: stageStatus,
                attemptCount: JobSQLiteDatabase.integer(statement, column: 3),
                lastError: JobSQLiteDatabase.optionalText(statement, column: 4),
                startedAt: JobSQLiteDatabase.optionalText(statement, column: 5),
                finishedAt: JobSQLiteDatabase.optionalText(statement, column: 6)
            )
        }
        return JobRecord(
            id: id,
            manifest: manifest,
            status: status,
            stages: stages,
            createdAt: row.2,
            updatedAt: row.3,
            failureDetails: row.4
        )
    }

    private func requireRecordUnlocked(id: String) throws -> JobRecord {
        guard let record = try recordUnlocked(id: id) else { throw JobsError.jobNotFound(id) }
        return record
    }

    private func resetUnlocked(job: JobRecord, fromStageID stageID: String, logMessage: String, inTransaction: Bool = false) throws {
        guard let stageIndex = job.stages.firstIndex(where: { $0.definition.id == stageID }) else {
            throw JobsError.jobNotRetryable(job.id)
        }
        let reset = {
            for stage in job.stages[stageIndex...] {
                try self.database.run(
                    "UPDATE job_stages SET status = ?, last_error = NULL, started_at = NULL, finished_at = NULL WHERE job_id = ? AND stage_id = ?",
                    bindings: [.text(JobStageStatus.pending.rawValue), .text(job.id), .text(stage.definition.id)]
                )
            }
            try self.database.run(
                "UPDATE jobs SET status = ?, failure_details = NULL, updated_at = ? WHERE id = ?",
                bindings: [.text(JobStatus.queued.rawValue), .text(self.now()), .text(job.id)]
            )
            try self.appendLogUnlocked(jobID: job.id, level: "info", message: logMessage)
        }
        if inTransaction { try reset() } else { try database.transaction(reset) }
    }

    private func appendLogUnlocked(jobID: String, level: String, message: String) throws {
        try database.run(
            """
            INSERT INTO job_logs (job_id, sequence, timestamp, level, message)
            VALUES (?, COALESCE((SELECT MAX(sequence) + 1 FROM job_logs WHERE job_id = ?), 1), ?, ?, ?)
            """,
            bindings: [.text(jobID), .text(jobID), .text(now()), .text(level), .text(message)]
        )
    }

    private func inboxID(jobID: String) -> String { "job:\(jobID)" }
}

/// Coordinates persisted jobs while enforcing one heavy stage and a bounded number of lightweight stages.
public final class JobScheduler {
    private let store: JobStore
    private let executor: JobExecuting
    private let lightweightLimit: Int
    private let eligibleJobTypes: Set<String>?
    private let heavyExecutionGate: JobHeavyExecutionGate
    private let heavyGateOwner = UUID()
    private let validators: [String: GeneratedArtifactValidator]
    private let onWorkQueuedWhilePaused: (() -> Void)?
    private let stateQueue = DispatchQueue(label: "Stillmatter.JobScheduler")
    private var activeHeavyJobID: String?
    private var activeLightweightJobIDs: Set<String> = []
    private var isPaused = false

    public init(
        store: JobStore,
        executor: JobExecuting,
        lightweightLimit: Int = 2,
        eligibleJobTypes: Set<String>? = nil,
        heavyExecutionGate: JobHeavyExecutionGate = JobHeavyExecutionGate(),
        validators: [String: GeneratedArtifactValidator] = [
            "json": JSONGeneratedArtifactValidator(),
            "markdown": MarkdownGeneratedArtifactValidator(),
            "webvtt": WebVTTGeneratedArtifactValidator()
        ],
        onWorkQueuedWhilePaused: (() -> Void)? = nil
    ) {
        self.store = store
        self.executor = executor
        self.lightweightLimit = max(1, lightweightLimit)
        self.eligibleJobTypes = eligibleJobTypes
        self.heavyExecutionGate = heavyExecutionGate
        self.validators = validators
        self.onWorkQueuedWhilePaused = onWorkQueuedWhilePaused
    }

    @discardableResult
    public func enqueue(id: String = UUID().uuidString, manifest: JobManifest) throws -> JobRecord {
        let record = try store.enqueue(id: id, manifest: manifest)
        start()
        return record
    }

    public func start() {
        stateQueue.async { [weak self] in
            self?.isPaused = false
            self?.scheduleAvailableWork()
        }
    }

    public func pause() {
        stateQueue.async { [weak self] in self?.isPaused = true }
    }

    public func retry(id: String) throws {
        try store.retry(id: id)
        start()
    }

    public func retry(id: String, meetingRelativePath: String, captureSessionID: String? = nil) throws {
        try store.retry(id: id, meetingRelativePath: meetingRelativePath, captureSessionID: captureSessionID)
        start()
    }

    public func rerun(id: String, fromStageID stageID: String) throws {
        try store.rerun(id: id, fromStageID: stageID)
        start()
    }

    public func openDetails(id: String) throws -> JobDetails {
        try store.details(id: id)
    }

    public func dismiss(id: String) throws {
        try store.dismiss(id: id)
    }

    private func scheduleAvailableWork() {
        guard !isPaused else { return }
        do {
            let queued = try store.jobs(status: .queued)
            for job in queued where eligibleJobTypes?.contains(job.manifest.type) ?? true {
                switch job.manifest.executionClass {
                case .heavy:
                    guard activeHeavyJobID == nil else { continue }
                    guard heavyExecutionGate.acquire(owner: heavyGateOwner, onAvailable: { [weak self] in
                        self?.stateQueue.async { [weak self] in self?.scheduleAvailableWork() }
                    }) else { continue }
                    activeHeavyJobID = job.id
                    executeNextStage(jobID: job.id, executionClass: .heavy)
                case .lightweight:
                    guard activeLightweightJobIDs.count < lightweightLimit else { continue }
                    activeLightweightJobIDs.insert(job.id)
                    executeNextStage(jobID: job.id, executionClass: .lightweight)
                }
            }
        } catch {
            NSLog("Could not schedule Stillmatter jobs: \(error)")
        }
    }

    private func executeNextStage(jobID: String, executionClass: JobExecutionClass) {
        do {
            guard let (job, stage) = try store.beginNextStage(jobID: jobID) else {
                release(jobID: jobID, executionClass: executionClass)
                scheduleAvailableWork()
                return
            }
            // The completion owns the scheduler until the running stage is durably persisted.
            // App reconfiguration may otherwise release a paused scheduler while its executor is active.
            executor.execute(job: job, stage: stage) { [self] result in
                stateQueue.async { [self] in
                    handle(result, job: job, stage: stage, executionClass: executionClass)
                }
            }
        } catch {
            release(jobID: jobID, executionClass: executionClass)
            scheduleAvailableWork()
        }
    }

    private func handle(
        _ result: Result<JobStageResult, Error>,
        job: JobRecord,
        stage: JobStageDefinition,
        executionClass: JobExecutionClass
    ) {
        do {
            switch result {
            case let .success(stageResult):
                try validate(stageResult.artifacts, for: stage.id, manifest: job.manifest)
                try store.completeStage(jobID: job.id, stageID: stage.id, messages: stageResult.logMessages)
                if try store.job(id: job.id)?.status == .queued {
                    if isPaused {
                        release(jobID: job.id, executionClass: executionClass)
                        onWorkQueuedWhilePaused?()
                    } else {
                        executeNextStage(jobID: job.id, executionClass: executionClass)
                    }
                    return
                }
            case let .failure(error):
                let willRetry = try store.failStage(jobID: job.id, stageID: stage.id, error: error)
                if willRetry {
                    if isPaused {
                        release(jobID: job.id, executionClass: executionClass)
                        onWorkQueuedWhilePaused?()
                    } else {
                        executeNextStage(jobID: job.id, executionClass: executionClass)
                    }
                    return
                }
            }
        } catch {
            do {
                let willRetry = try store.failStage(jobID: job.id, stageID: stage.id, error: error)
                if willRetry {
                    if isPaused {
                        release(jobID: job.id, executionClass: executionClass)
                        onWorkQueuedWhilePaused?()
                    } else {
                        executeNextStage(jobID: job.id, executionClass: executionClass)
                    }
                    return
                }
            } catch {
                NSLog("Could not persist Stillmatter job failure: \(error)")
            }
        }
        release(jobID: job.id, executionClass: executionClass)
        scheduleAvailableWork()
    }

    private func validate(_ artifacts: [GeneratedArtifact], for stageID: String, manifest: JobManifest) throws {
        let expected = manifest.expectedOutputs.filter { $0.stageID == stageID }
        let expectedByPath = Dictionary(uniqueKeysWithValues: expected.map { ($0.relativePath, $0) })
        for artifact in artifacts {
            guard let expectation = expectedByPath[artifact.relativePath] else {
                throw JobsError.unexpectedArtifact(artifact.relativePath)
            }
            guard let validator = validators[expectation.validatorID] else {
                throw JobsError.unknownValidator(expectation.validatorID)
            }
            try validator.validate(artifact, expectation: expectation)
        }
        let producedPaths = Set(artifacts.map(\.relativePath))
        for expectation in expected where expectation.required && !producedPaths.contains(expectation.relativePath) {
            throw JobsError.missingArtifact(expectation.relativePath)
        }
    }

    private func release(jobID: String, executionClass: JobExecutionClass) {
        switch executionClass {
        case .heavy:
            activeHeavyJobID = nil
            heavyExecutionGate.release(owner: heavyGateOwner)
        case .lightweight: activeLightweightJobIDs.remove(jobID)
        }
    }
}

private enum JobSQLiteValue {
    case text(String)
    case integer(Int)
    case null
}

private final class JobSQLiteDatabase {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open database"
            if let handle = handle { sqlite3_close(handle) }
            handle = nil
            throw JobsError.sqlite(code: result, message: message)
        }
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle = handle { sqlite3_close(handle) }
    }

    func run(_ sql: String, bindings: [JobSQLiteValue] = []) throws {
        let statement = try prepare(sql, bindings: bindings)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else { throw error(code: result) }
    }

    func query<T>(_ sql: String, bindings: [JobSQLiteValue] = [], row: (OpaquePointer) throws -> T) throws -> [T] {
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

    static func integer(_ statement: OpaquePointer, column: Int32) -> Int {
        Int(sqlite3_column_int64(statement, column))
    }

    private func prepare(_ sql: String, bindings: [JobSQLiteValue]) throws -> OpaquePointer {
        guard let handle = handle else { throw JobsError.sqlite(code: SQLITE_MISUSE, message: "Database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let prepared = statement else { throw error(code: result) }
        do {
            for (offset, binding) in bindings.enumerated() {
                let index = Int32(offset + 1)
                let bindResult: Int32
                switch binding {
                case let .text(value):
                    bindResult = sqlite3_bind_text(prepared, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                case let .integer(value):
                    bindResult = sqlite3_bind_int64(prepared, index, sqlite3_int64(value))
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

    private func error(code: Int32) -> JobsError {
        .sqlite(code: code, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error")
    }
}
