import AVFoundation
import Foundation

/// Prepares private media before publishing the ordinary Meeting doorway and Job.
/// Call recovery once at workspace activation, before accepting new imports.
public final class MeetingImportService {
    private static let activeLock = NSLock()
    private static var activeFolders = Set<String>()
    public enum Phase: String { case copying, extracting, prepared, published, enqueued }
    public struct Result {
        public let bundle: RecordingBundle
        public let job: JobRecord
    }
    public static let supportedExtensions = ["wav", "aiff", "aif", "caf", "mp3", "m4a", "aac", "mp4", "mov"]
    private struct Intent: Codable {
        let owner: String
        let bundle: RecordingBundle
        let title: String
        let occurrence: Date
        let dateSource: String
        let language: TranscriptLanguage
    }
    private let vault: WorkspaceVault
    private let directory: URL
    private let jobs: JobStore
    private let files = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(vault: WorkspaceVault, mediaRootURL: URL, jobStore: JobStore) {
        self.vault = vault
        directory = mediaRootURL.appendingPathComponent("Imports", isDirectory: true)
            .appendingPathComponent(SHA256Hex.digest(Data(vault.rootURL.resolvingSymlinksInPath().path.utf8)), isDirectory: true)
        jobs = jobStore
        encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    }

    @discardableResult
    public func importFile(_ source: URL, language: TranscriptLanguage = .automatic,
                           cancelled: () -> Bool = { false },
                           progress: (Phase) throws -> Void = { _ in }) throws -> Result {
        guard Self.supportedExtensions.contains(source.pathExtension.lowercased()) else {
            throw failure("Unsupported file. Choose WAV, AIFF, CAF, MP3, AAC, M4A, MP4 or MOV with a readable audio track.")
        }
        let values = try URL(fileURLWithPath: source.path).resourceValues(forKeys: [.isRegularFileKey, .creationDateKey, .contentModificationDateKey])
        guard values.isRegularFile == true else { throw failure("Choose a readable audio or video file.") }
        let modified = values.contentModificationDate ?? Date(timeIntervalSince1970: 0)
        let created = values.creationDate
        let useCreation = created.map { $0.timeIntervalSince1970 > 0 && $0 <= modified } ?? false
        let occurrence = useCreation ? created! : modified
        let id = "import-" + UUID().uuidString.lowercased()
        let folder = directory.appendingPathComponent(id, isDirectory: true)
        Self.activeLock.lock()
        Self.activeFolders.insert(folder.path)
        Self.activeLock.unlock()
        defer {
            Self.activeLock.lock()
            Self.activeFolders.remove(folder.path)
            Self.activeLock.unlock()
        }
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let intentURL = folder.appendingPathComponent("import-intent.json")
        do {
            try checkCancellation(cancelled)
            try progress(.copying)
            let copy = folder.appendingPathComponent("source." + source.pathExtension.lowercased())
            try files.copyItem(at: source, to: copy)
            try checkCancellation(cancelled)
            try progress(.extracting)
            let audio = folder.appendingPathComponent("audio.m4a")
            try extract(copy, to: audio, cancelled: cancelled)
            let file = try AVAudioFile(forReading: audio)
            let duration = Double(file.length) / file.processingFormat.sampleRate
            guard duration.isFinite, duration > 0 else { throw failure("This file has no usable audio. Choose another file.") }
            let path = "Meetings/Imports/\(id)/meeting.md"
            let metadataURL = folder.appendingPathComponent("audio.json")
            var metadata = MicTrackRecordingMetadata(captureSessionID: id, meetingRelativePath: path,
                recoveryFilePath: copy.path, finalFilePath: audio.path, metadataFilePath: metadataURL.path,
                startedAt: occurrence, status: .completed, durationSeconds: duration, codec: "aac",
                sampleRate: file.processingFormat.sampleRate, channelCount: Int(file.processingFormat.channelCount),
                diagnostics: ["Imported mixed audio; no microphone-owner identity is implied."])
            metadata.endedAt = occurrence.addingTimeInterval(duration)
            try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
            let finalized = try RecordingBundleFinalizer().finalize(mic: metadata, system: nil, reason: .normalStop)
            let track = finalized.mic
            let imported = RecordingBundleTrack(role: "imported-audio", status: track.status,
                preferredAudioFilePath: track.preferredAudioFilePath, recoveryFilePath: track.recoveryFilePath,
                finalFilePath: track.finalFilePath, metadataFilePath: track.metadataFilePath,
                recoveryFileExists: track.recoveryFileExists, finalFileExists: track.finalFileExists,
                metadataFileExists: track.metadataFileExists, recoveryFileSHA256: track.recoveryFileSHA256,
                finalFileSHA256: track.finalFileSHA256, durationSeconds: track.durationSeconds,
                codec: track.codec, sampleRate: track.sampleRate, channelCount: track.channelCount, diagnostics: track.diagnostics)
            let bundle = RecordingBundle(schemaVersion: finalized.schemaVersion, captureSessionID: id,
                meetingRelativePath: path, bundleFilePath: finalized.bundleFilePath, finalizedAt: finalized.finalizedAt,
                reason: .normalStop, state: .ready, mic: imported, system: nil, diagnostics: metadata.diagnostics)
            try encoder.encode(bundle).write(to: URL(fileURLWithPath: bundle.bundleFilePath), options: .atomic)
            let title = source.deletingPathExtension().lastPathComponent
                .components(separatedBy: .newlines).joined(separator: " ")
            let intent = Intent(owner: vault.rootURL.resolvingSymlinksInPath().path, bundle: bundle,
                title: title, occurrence: occurrence, dateSource: useCreation ? "file_creation" : "file_modification", language: language)
            try encoder.encode(intent).write(to: intentURL, options: .atomic)
            // Recovery owns the operation from here, including a failed publication/enqueue.
            try progress(.prepared)
            let result = try publish(intent, progress: progress)
            try Data().write(to: folder.appendingPathComponent("complete"), options: .atomic)
            try files.removeItem(at: intentURL)
            return result
        } catch {
            if !files.fileExists(atPath: intentURL.path) { try? files.removeItem(at: folder) }
            throw error
        }
    }

    /// Returns failures independently: one bad import cannot prevent another's recovery.
    public func recover() throws -> [String] {
        guard files.fileExists(atPath: directory.path) else { return [] }
        var errors: [String] = []
        for folder in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            Self.activeLock.lock()
            let active = Self.activeFolders.contains(folder.path)
            Self.activeLock.unlock()
            if active { continue }
            let url = folder.appendingPathComponent("import-intent.json")
            do {
                if files.fileExists(atPath: url.path) {
                    let intent = try decoder.decode(Intent.self, from: Data(contentsOf: url))
                    guard intent.owner == vault.rootURL.resolvingSymlinksInPath().path else { continue }
                    _ = try publish(intent, progress: { _ in })
                    try Data().write(to: folder.appendingPathComponent("complete"), options: .atomic)
                    try files.removeItem(at: url)
                } else if !files.fileExists(atPath: folder.appendingPathComponent("complete").path) {
                    try files.removeItem(at: folder)
                }
            } catch { errors.append("Could not recover \(folder.lastPathComponent): \(error.localizedDescription)") }
        }
        return errors
    }

    private func publish(_ intent: Intent, progress: (Phase) throws -> Void) throws -> Result {
        try RecordingBundleFinalizer().validate(intent.bundle)
        let path = intent.bundle.meetingRelativePath
        if try vault.versionOfMarkdown(relativePath: path) == nil {
            let markdown = """
            ---
            schema_version: 1
            type: meeting
            title: \(MeetingCalendarContext.titleLine(intent.title))
            started_at: \(ISO8601DateFormatter().string(from: intent.occurrence))
            occurrence_source: \(intent.dateSource)
            capture_session_id: \(intent.bundle.captureSessionID)
            meeting_source: imported
            capture: stopped
            recording_bundle: \(intent.bundle.bundleFilePath)
            ---
            # \(MeetingCalendarContext.titleLine(intent.title))

            ## Processing

            - [x] Imported audio prepared
            - [ ] Transcription and summary

            ## Live notes

            """
            _ = try vault.writeMarkdown(Data(markdown.utf8), relativePath: path, expectedVersion: nil)
        }
        try progress(.published)
        let manifest = try MeetingWorkflowJob.manifest(transcription: TranscriptionJob.manifest(
            title: intent.title, bundle: intent.bundle, selection: nil, language: intent.language))
        let job = try CaptureProcessingHandoff.enqueueOnce(manifest: manifest, sessionID: intent.bundle.captureSessionID,
            meetingRelativePath: path, workspaceRootURL: vault.rootURL, jobStore: jobs)
        try progress(.enqueued)
        return Result(bundle: intent.bundle, job: job)
    }

    private func extract(_ source: URL, to destination: URL, cancelled: () -> Bool) throws {
        let asset = AVURLAsset(url: source)
        guard !asset.tracks(withMediaType: .audio).isEmpty,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw failure("This file has no supported audio track or is corrupt. Choose another audio/video file.")
        }
        export.outputURL = destination
        export.outputFileType = .m4a
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously { done.signal() }
        let deadline = Date().addingTimeInterval(3600)
        while done.wait(timeout: .now() + 0.1) == .timedOut {
            if cancelled() || Date() >= deadline {
                export.cancelExport()
                done.wait()
                throw failure("Import cancelled or timed out. The original file is unchanged; you can retry.")
            }
        }
        guard export.status == .completed else {
            throw failure("Audio preparation failed. Choose another file or retry. \(export.error?.localizedDescription ?? "")")
        }
    }

    private func checkCancellation(_ cancelled: () -> Bool) throws {
        if cancelled() { throw failure("Import cancelled. The original file is unchanged.") }
    }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Stillmatter.Import", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
