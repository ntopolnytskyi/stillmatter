import Foundation

/// Read-only doorway metadata shared by Meeting reads and canonical rename planning.
struct MeetingDoorwayMetadata {
    var title: String?
    var startedAt: Date?
    var sessionID: String?
    var project: String?
    var bundlePath: String?

    private init() {}

    init(_ text: String?) {
        self = Self.read(text)
    }

    /// A Capture Session match or a retained artifact reference establishes Job ownership.
    static func owns(_ job: JobRecord, session: String?, path: String) -> Bool {
        if let session, job.manifest.metadata["capture_session_id"] == session { return true }
        let directory = (path as NSString).deletingLastPathComponent + "/"
        return job.manifest.sourceArtifacts.contains {
            $0.relativePath == path || $0.relativePath.hasPrefix(directory)
        } || job.manifest.expectedOutputs.contains { $0.relativePath.hasPrefix(directory) }
    }

    private static func read(_ text: String?) -> Self {
        var fields = Self()
        guard let text else { return fields }
        let lines = text.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" { break }
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                switch key {
                case "title": fields.title = value
                case "project": fields.project = value
                case "capture_session_id", "session_id": fields.sessionID = value
                case "started_at": fields.startedAt = ISO8601DateFormatter().date(from: value)
                case "recording_bundle": fields.bundlePath = value
                default: break
                }
            }
        }
        if fields.title == nil {
            fields.title = lines.first(where: { $0.hasPrefix("# ") }).map { String($0.dropFirst(2)) }
        }
        if let context = try? MeetingCalendarContext.read(from: text),
           fields.title == MeetingCalendarContext.titleLine(context.appliedTitle).trimmingCharacters(in: .whitespaces) {
            fields.title = context.appliedTitle
        }
        return fields
    }
}
