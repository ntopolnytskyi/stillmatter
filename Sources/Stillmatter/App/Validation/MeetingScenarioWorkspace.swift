import Foundation
import StillmatterCore

#if DEBUG
/// Disposable canonical Meeting artifacts consumed through the real read and mutation providers.
final class MeetingScenarioWorkspace {
    let root: URL
    let vault: WorkspaceVault

    init(audioFile: URL, temporaryRoot: URL) throws {
        root = temporaryRoot.appendingPathComponent("Stillmatter-MeetingSelection-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            vault = WorkspaceVault(workspaceRootURL: root, appSupportRootURL: root.appendingPathComponent("Support"))
            for id in ["first", "second"] {
                let recordingRoot = root.appendingPathComponent(id, isDirectory: true)
                try FileManager.default.createDirectory(at: recordingRoot, withIntermediateDirectories: true)
                let audioURL = recordingRoot.appendingPathComponent("\(id).caf")
                try FileManager.default.copyItem(at: audioFile, to: audioURL)
                let metadataURL = recordingRoot.appendingPathComponent("\(id).json")
                try Data("{}".utf8).write(to: metadataURL)
                var microphone = MicTrackRecordingMetadata(
                    captureSessionID: id,
                    meetingRelativePath: "Meetings/\(id)/meeting.md",
                    recoveryFilePath: audioURL.path,
                    finalFilePath: recordingRoot.appendingPathComponent("\(id).m4a").path,
                    metadataFilePath: metadataURL.path,
                    startedAt: Date(),
                    sampleRate: 48_000,
                    channelCount: 1
                )
                microphone.status = .partial
                microphone.durationSeconds = 1
                let bundle = try RecordingBundleFinalizer().finalize(mic: microphone, system: nil, reason: .recovery)
                _ = try vault.writeMarkdown(
                    Data("---\ntitle: \(id)\ncapture_session_id: \(id)\nrecording_bundle: \(bundle.bundleFilePath)\n---\n# \(id)\n".utf8),
                    relativePath: "Meetings/\(id)/meeting.md",
                    expectedVersion: nil
                )
                let transcript = #"{"schema_version":1,"capture_session_id":"\#(id)","meeting_relative_path":"Meetings/\#(id)/meeting.md","language":"en","detected_languages":["en"],"engine":"fixture","model":"fixture","generated_at":"2026-01-01T00:00:00Z","audio_sources":[],"segments":[{"id":"s1","start":0.1,"end":0.4,"text":"Evidence \#(id)","language":"en","track":"microphone","speaker":"Me"}],"diagnostics":[]}"#
                _ = try vault.writeMarkdown(Data(transcript.utf8), relativePath: "Meetings/\(id)/transcript.json", expectedVersion: nil)
                let extraction = #"{"schema_version":1,"meeting":"Meetings/\#(id)/meeting.md","transcript":"Meetings/\#(id)/transcript.json","decisions":[{"id":"d1","text":"Decision \#(id)","citations":[{"segment_id":"s1","start_seconds":0.1,"end_seconds":0.4}]}],"my_action_items":[],"other_action_items":[],"open_questions":[]}"#
                _ = try vault.writeMarkdown(Data(extraction.utf8), relativePath: "Meetings/\(id)/summary-extraction.json", expectedVersion: nil)
            }
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
#endif
