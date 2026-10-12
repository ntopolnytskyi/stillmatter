import Foundation
import StillmatterCore

/// Named, deterministic workbench states. Media is represented only by metadata, never recordings.
enum MeetingFixtureCase: CaseIterable, Equatable {
    case noWorkspace, emptyWorkspace, readyMeeting, liveMeeting, processingMeeting, degradedAudio
    case failedTranscription, pendingActionReview, longUkrainianEnglishText, externalFileEdit
    case malformedArtifact, thousandMeetingHistory, longTranscript

    var expectedFileCount: Int {
        switch self {
        case .noWorkspace, .emptyWorkspace: return 0
        case .readyMeeting: return 3
        case .liveMeeting, .processingMeeting, .degradedAudio, .failedTranscription, .pendingActionReview,
             .longUkrainianEnglishText, .externalFileEdit, .malformedArtifact: return 2
        case .thousandMeetingHistory: return 1_000
        case .longTranscript: return 2
        }
    }
}

struct MeetingFixture {
    let root: URL
    let vault: WorkspaceVault
    let createdAt: Date
    let workspaceConfigured: Bool

    func remove() { try? FileManager.default.removeItem(at: root) }
}

enum MeetingFixtureFactory {
    static let fixedDate = ISO8601DateFormatter().date(from: "2026-10-19T12:00:00Z")!

    static func make(_ fixtureCase: MeetingFixtureCase) throws -> MeetingFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StillmatterPresentationFixtures", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let vault = WorkspaceVault(workspaceRootURL: root, appSupportRootURL: root.appendingPathComponent("Support"))
        let files = try content(for: fixtureCase)
        do {
            for (path, text) in files.sorted(by: { $0.key < $1.key }) {
                _ = try vault.writeMarkdown(Data(text.utf8), relativePath: path, expectedVersion: nil)
            }
            return MeetingFixture(root: root, vault: vault, createdAt: fixedDate,
                                  workspaceConfigured: fixtureCase != .noWorkspace)
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    private static func content(for fixtureCase: MeetingFixtureCase) throws -> [String: String] {
        func meeting(_ id: String, title: String, state: String = "stopped") -> String {
            """
            ---
            title: \(title)
            started_at: 2026-10-19T12:00:00Z
            capture_session_id: \(id)
            fixture_state: \(state)
            ---
            # \(title)
            \n## Notes
            Fixture note.
            """
        }
        switch fixtureCase {
        case .noWorkspace, .emptyWorkspace:
            return [:]
        case .readyMeeting:
            return ["Meetings/ready/meeting.md": meeting("ready", title: "Ready meeting"),
                    "Meetings/ready/transcript.md": "A canonical fixture transcript.\n",
                    "Meetings/ready/summary.md": "## Summary\n\nA ready fixture.\n"]
        case .liveMeeting: return ["Meetings/live/meeting.md": meeting("live", title: "Live meeting", state: "live"), "Meetings/live/state.json": "{\"state\":\"recording\"}\n"]
        case .processingMeeting: return ["Meetings/processing/meeting.md": meeting("processing", title: "Processing meeting", state: "processing"), "Meetings/processing/job.json": "{\"status\":\"running\"}\n"]
        case .degradedAudio: return ["Meetings/degraded/meeting.md": meeting("degraded", title: "Degraded audio"), "Meetings/degraded/audio-metadata.json": "{\"microphone\":\"available\",\"system\":\"degraded\"}\n"]
        case .failedTranscription: return ["Meetings/failed/meeting.md": meeting("failed", title: "Failed transcription"), "Meetings/failed/job.json": "{\"status\":\"failed\",\"error\":\"fixture failure\"}\n"]
        case .pendingActionReview: return ["Meetings/review/meeting.md": meeting("review", title: "Pending action review"), "Meetings/review/extraction.json": "{\"review\":\"pending\"}\n"]
        case .longUkrainianEnglishText:
            return ["Meetings/long-text/meeting.md": meeting("long-text", title: "Ukrainian English text"), "Meetings/long-text/summary.md": String(repeating: "Український текст with English context. ", count: 500)]
        case .externalFileEdit: return ["Meetings/external/meeting.md": meeting("external", title: "External edit"), "Meetings/external/notes.md": "Changed outside the app.\n"]
        case .malformedArtifact: return ["Meetings/malformed/meeting.md": meeting("malformed", title: "Malformed artifact"), "Meetings/malformed/transcript.json": "{ malformed\n"]
        case .thousandMeetingHistory:
            return Dictionary(uniqueKeysWithValues: (0..<1_000).map { number in
                let id = String(format: "%04d", number)
                return ("Meetings/history-\(id)/meeting.md", meeting("history-\(id)", title: "History meeting \(id)"))
            })
        case .longTranscript: return ["Meetings/transcript/meeting.md": meeting("transcript", title: "Long transcript"), "Meetings/transcript/transcript.md": String(repeating: "[00:00:01] Speaker: transcript words.\n", count: 10_000)]
        }
    }
}
