#if STILLMATTER_CAPTURE_PROBE
import AppKit
import CoreGraphics
import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Compiled only into the disposable, locally signed synthetic-call probe.
/// The normal Stillmatter app has no CLI capture path.
enum TeamsCallAudioProbe {
    static func run(_ command: String) -> Int32 {
        let _ = NSApplication.shared
        if command == "--permission" {
            print("TEAMS_SCOPE_PROBE_PERMISSION screenCaptureAuthorized=\(CGPreflightScreenCaptureAccess())")
            return 0
        }
        guard command == "--capture" else {
            fputs("Expected --permission or --capture\n", stderr)
            return 2
        }
        let approval = URL(fileURLWithPath: "/private/tmp/stillmatter-teams-synthetic-call-approval")
        guard let data = try? String(contentsOf: approval, encoding: .utf8) else {
            fputs("One-use synthetic call approval is missing; no capture started.\n", stderr)
            return 2
        }
        // Consume the approval before touching any recording API.
        try? FileManager.default.removeItem(at: approval)
        let lines = data.split(separator: "\n")
        guard lines.count == 2, lines[0] == "AUTHORIZE_SYNTHETIC_TEAMS_AUDIO" else {
            fputs("Invalid synthetic call approval; no capture started.\n", stderr)
            return 2
        }
        let path = String(lines[1])
        guard path.range(of: #"^/private/tmp/stillmatter-teams-call\.[A-Za-z0-9]{6}$"#,
                         options: .regularExpression) != nil else {
            fputs("Invalid disposable output path; no capture started.\n", stderr)
            return 2
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            fputs("Disposable output directory is missing; no capture started.\n", stderr)
            return 2
        }
        guard CGPreflightScreenCaptureAccess() else {
            fputs("Screen Recording is not authorized for this signed Stillmatter app; no capture started.\n", stderr)
            return 2
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        let recovery = output.appendingPathComponent("teams-audio.caf")
        let final = output.appendingPathComponent("teams-audio.m4a")
        guard !FileManager.default.fileExists(atPath: recovery.path),
              !FileManager.default.fileExists(atPath: final.path) else {
            fputs("Capture output already exists; no capture started.\n", stderr)
            return 2
        }
        do {
            let recorder = MacSystemAudioTrackRecorder()
            _ = try recorder.startWritingRecovery(to: recovery, scope: .teamsApplication)
            try Data("capture-live".utf8).write(to: output.appendingPathComponent("capture-started"), options: .atomic)
            Thread.sleep(forTimeInterval: 20)
            let released = try recorder.stopWritingRecovery(to: recovery)
            let completed = try recorder.finalizeRecovery(from: recovery, to: final,
                audioClockSpans: released.audioClockSpans)
            guard completed.durationSeconds > 0 else {
                fputs("No system-audio frames retained.\n", stderr)
                return 1
            }
            print("TEAMS_SCOPE_PROBE_AUDIO=\(final.path)")
            return 0
        } catch {
            fputs("Teams scope probe failed: \(error)\n", stderr)
            return 1
        }
    }
}
#endif
