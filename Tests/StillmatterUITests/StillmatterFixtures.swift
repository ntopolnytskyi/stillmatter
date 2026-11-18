import Foundation
import XCTest
import StillmatterCore
import AVFoundation
import CryptoKit

extension StillmatterFlowsUITests {
    var notesURL: URL { meetingURL.deletingLastPathComponent().appendingPathComponent("my-notes.md") }
    func notesText() throws -> String { try String(contentsOf: notesURL, encoding: .utf8) }

    var editor: XCUIElement { app.textViews["meeting-text-editor"] }
    var meetingURL: URL { fixtureRoot.appendingPathComponent("workspace/Meetings/ui-fixture/meeting.md") }

    func openEditor(_ field: String) {
        app.radioButtons[field == "notes" ? "My Notes" : "Summary"].click()
        let button = app.buttons["meeting-overview-edit-\(field)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: button)
        waitForExpectations(timeout: 10)
        button.click()
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
    }

    func replaceEditorText(_ text: String) {
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(text)
    }

    func waitForEditorToClose() {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor)
        waitForExpectations(timeout: 10)
    }

    func meetingText() throws -> String { try String(contentsOf: meetingURL, encoding: .utf8) }

    func relaunch() {
        app.terminate()
        app.launch()
        XCTAssertTrue(app.windows["Stillmatter"].waitForExistence(timeout: 15), app.debugDescription)
    }

    func openFixtureMeeting() {
        app.buttons["sidebar-meetings"].click()
        app.buttons["Recorded"].click()
        let row = app.tables["Meetings"].staticTexts["UI fixture meeting"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.click()
        XCTAssertTrue(app.buttons["meeting-overview-edit-summary"].waitForExistence(timeout: 10))
    }

    func seedMeeting(transcript: Bool = false, notes: String = "Original notes.",
                     myActionItem: String? = nil) throws {
        let directory = meetingURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "---\ntitle: UI fixture meeting\ncapture_session_id: ui-fixture\n---\n# UI fixture meeting\n\n## Notes\n\n\(notes)\n"
            .write(to: meetingURL, atomically: true, encoding: .utf8)
        try "## Summary\n\nOriginal summary.\n".write(to: directory.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        if transcript {
            try "# Transcript\n\nSynthetic evidence\n".write(to: directory.appendingPathComponent("transcript.md"), atomically: true, encoding: .utf8)
            let document: [String: Any] = ["schema_version": 1, "capture_session_id": "ui-fixture",
                "meeting_relative_path": "Meetings/ui-fixture/meeting.md", "language": "en", "detected_languages": ["en"],
                "engine": "fixture", "model": "fixture", "generated_at": "2026-01-01T00:00:00Z",
                "audio_sources": [], "diagnostics": [], "segments": [
                    ["id": "s0", "start": 0.0, "end": 1.0, "text": "Synthetic evidence", "language": "en", "track": "microphone", "speaker": "Me"]]]
            try JSONSerialization.data(withJSONObject: document).write(to: directory.appendingPathComponent("transcript.json"))
            let actions = myActionItem.map { [MeetingOutcome(id: "action-fixture", text: $0, citations: [])] } ?? []
            let extraction = MeetingSummaryExtraction(meeting: "Meetings/ui-fixture/meeting.md", transcript: "Meetings/ui-fixture/transcript.json",
                decisions: [], myActionItems: actions, otherActionItems: [], openQuestions: [])
            try JSONEncoder().encode(extraction).write(to: directory.appendingPathComponent("summary-extraction.json"))
        }
        relaunch()
    }

}

extension StillmatterFlowsUITests {
    func seedPlayableTranscript() throws -> (transcript: URL, audio: URL) {
        let directory = fixtureRoot.appendingPathComponent("workspace/Meetings/audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let oldMedia = fixtureRoot.appendingPathComponent("media/audio")
        try FileManager.default.createDirectory(at: oldMedia, withIntermediateDirectories: true)
        let audio = oldMedia.appendingPathComponent("mic.caf")
        let metadata = oldMedia.appendingPathComponent("mic.json")
        let bundle = oldMedia.appendingPathComponent("recording-bundle.json")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        do {
            let writer = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for frame in 0..<48_000 { buffer.floatChannelData?[0][frame] = Float(sin(Double(frame) * 0.1)) * 0.1 }
            for _ in 0..<8 { try writer.write(from: buffer) }
        }
        try Data("{}".utf8).write(to: metadata)
        let hash = SHA256.hash(data: try Data(contentsOf: audio)).map { String(format: "%02x", $0) }.joined()
        let track: [String: Any] = ["role": "microphone", "status": "partial", "preferredAudioFilePath": audio.path,
            "recoveryFilePath": audio.path, "finalFilePath": oldMedia.appendingPathComponent("missing.m4a").path,
            "metadataFilePath": metadata.path, "recoveryFileExists": true, "finalFileExists": false,
            "metadataFileExists": true, "recoveryFileSHA256": hash, "durationSeconds": 8.0,
            "codec": "caf", "sampleRate": 48_000.0, "channelCount": 1, "diagnostics": []]
        let systemAudio = oldMedia.appendingPathComponent("system.caf")
        let systemMetadata = oldMedia.appendingPathComponent("system.json")
        do {
            let writer = try AVAudioFile(forWriting: systemAudio, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for frame in 0..<48_000 { buffer.floatChannelData?[0][frame] = Float(sin(Double(frame) * 0.3)) * 0.4 }
            for _ in 0..<8 { try writer.write(from: buffer) }
        }
        try Data("{}".utf8).write(to: systemMetadata)
        var systemTrack = track
        systemTrack["role"] = "system-audio"
        systemTrack["preferredAudioFilePath"] = systemAudio.path
        systemTrack["recoveryFilePath"] = systemAudio.path
        systemTrack["finalFilePath"] = oldMedia.appendingPathComponent("missing-system.m4a").path
        systemTrack["metadataFilePath"] = systemMetadata.path
        systemTrack["recoveryFileSHA256"] = SHA256.hash(data: try Data(contentsOf: systemAudio)).map { String(format: "%02x", $0) }.joined()
        let sidecar: [String: Any] = ["schemaVersion": 1, "captureSessionID": "audio",
            "meetingRelativePath": "Meetings/audio/meeting.md", "bundleFilePath": bundle.path,
            "finalizedAt": "2026-10-07T17:35:00Z", "reason": "recovery", "state": "partial",
            "mic": track, "system": systemTrack, "diagnostics": []]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: bundle)
        try Data("---\ntitle: Playable meeting\ncapture_session_id: audio\nrecording_bundle: \(bundle.path)\n---\n# Playable meeting\n".utf8)
            .write(to: directory.appendingPathComponent("meeting.md"))
        let transcript: [String: Any] = ["schema_version": 1, "capture_session_id": "audio",
            "meeting_relative_path": "Meetings/audio/meeting.md", "language": "en", "detected_languages": ["en"],
            "engine": "fixture", "model": "fixture", "generated_at": "2026-01-01T00:00:00Z",
            "audio_sources": [], "diagnostics": [], "segments": [
                ["id": "early", "start": 2.0, "end": 3.0, "text": "Early synthetic speech", "language": "en", "track": "microphone", "speaker": "Me"],
                ["id": "late", "start": 6.0, "end": 7.0, "text": "Later synthetic speech", "language": "en", "track": "system-audio", "speaker": "Guest"]]]
        let transcriptURL = directory.appendingPathComponent("transcript.json")
        try JSONSerialization.data(withJSONObject: transcript).write(to: transcriptURL)
        // Use the public serialized extraction format, with all four marker categories.
        let evidence: [String: Any] = ["segment_id": "early", "start_seconds": 2.0, "end_seconds": 3.0]
        let outcome: [String: Any] = ["id": "marker", "text": "Fixture annotation", "citations": [evidence]]
        let extraction: [String: Any] = ["schema_version": 1, "meeting": "Meetings/audio/meeting.md", "transcript": "Meetings/audio/transcript.json",
            "decisions": [outcome], "my_action_items": [outcome], "other_action_items": [], "open_questions": [outcome]]
        try JSONSerialization.data(withJSONObject: extraction).write(to: directory.appendingPathComponent("summary-extraction.json"))
        return (transcriptURL, audio)
    }
}

extension StillmatterFlowsUITests {
    func seedPersonalQueue() throws -> URL {
        let workspace = fixtureRoot.appendingPathComponent("workspace")
        let source = workspace.appendingPathComponent("Meetings/task/my-notes.md")
        let queue = workspace.appendingPathComponent("Todos/todo.md")
        for directory in [source.deletingLastPathComponent(), queue.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let metadata = #"{"v":1,"id":"ee935d20-e388-4ccf-b6bd-1f5dc785fd01","owner":"me","review":"approved","origin":"notes","citations":[]}"#
        try "# Notes\n- [ ] Personal task <!-- sm-item:\(metadata) -->\n".write(to: source, atomically: true, encoding: .utf8)
        try "## Queue\n- [[item:ee935d20-e388-4ccf-b6bd-1f5dc785fd01|Personal task]]\n- [ ] Second\n- [ ] Third\n\n## Done\n".write(to: queue, atomically: true, encoding: .utf8)
        return queue
    }
}
