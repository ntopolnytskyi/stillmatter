import Foundation

public enum TranscriptLanguage: String, Codable, CaseIterable, Equatable {
    case english = "en"
    case ukrainian = "uk"

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .ukrainian: return "Ukrainian"
        }
    }
}

public enum TranscriptTrack: String, Codable, Equatable {
    case microphone
    case systemAudio = "system-audio"

    public var speakerLabel: String {
        switch self {
        case .microphone: return "Me"
        case .systemAudio: return "Meeting audio"
        }
    }
}

public struct TranscriptSegment: Codable, Equatable {
    public let id: String
    public let startSeconds: Double
    public let endSeconds: Double
    public let text: String
    public let language: TranscriptLanguage
    public let track: TranscriptTrack
    public let speaker: String

    public init(
        id: String,
        startSeconds: Double,
        endSeconds: Double,
        text: String,
        language: TranscriptLanguage,
        track: TranscriptTrack,
        speaker: String
    ) {
        self.id = id
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.language = language
        self.track = track
        self.speaker = speaker
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startSeconds = "start"
        case endSeconds = "end"
        case text
        case language
        case track
        case speaker
    }
}

public struct TranscriptionEngineResult: Equatable {
    public let segments: [TranscriptSegment]
    public let detectedLanguage: TranscriptLanguage?
    public let diagnostics: [String]

    public init(
        segments: [TranscriptSegment],
        detectedLanguage: TranscriptLanguage? = nil,
        diagnostics: [String] = []
    ) {
        self.segments = segments
        self.detectedLanguage = detectedLanguage
        self.diagnostics = diagnostics
    }
}

public protocol TranscriptionEngine: AnyObject {
    var engineIdentifier: String { get }
    var modelIdentifier: String { get }
    func transcribe(audioURL: URL, language: TranscriptLanguage, track: TranscriptTrack) throws -> TranscriptionEngineResult
}

public struct TranscriptAudioSource: Codable, Equatable {
    public let track: TranscriptTrack
    public let filePath: String
    public let selection: String
}

public struct TranscriptDocument: Codable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let captureSessionID: String
    public let meetingRelativePath: String
    public let language: TranscriptLanguage
    public let detectedLanguages: [TranscriptLanguage]
    public let engine: String
    public let model: String
    public let generatedAt: Date
    public let audioSources: [TranscriptAudioSource]
    public let segments: [TranscriptSegment]
    public let diagnostics: [String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case captureSessionID = "capture_session_id"
        case meetingRelativePath = "meeting_relative_path"
        case language
        case detectedLanguages = "detected_languages"
        case engine
        case model
        case generatedAt = "generated_at"
        case audioSources = "audio_sources"
        case segments
        case diagnostics
    }
}

public struct TranscriptionArtifacts: Equatable {
    public let document: TranscriptDocument
    public let markdownRelativePath: String
    public let jsonRelativePath: String
    public let vttRelativePath: String
    public let markdown: Data
    public let json: Data
    public let vtt: Data

    public var generatedArtifacts: [GeneratedArtifact] {
        [
            GeneratedArtifact(relativePath: markdownRelativePath, data: markdown),
            GeneratedArtifact(relativePath: jsonRelativePath, data: json),
            GeneratedArtifact(relativePath: vttRelativePath, data: vtt)
        ]
    }
}

public enum TranscriptionError: Error, Equatable, CustomStringConvertible {
    case invalidSidecar(String)
    case missingAudio(String)
    case invalidSegment(String)
    case unsupportedJob(String)
    case missingConfiguration(String)
    case engineFailed(String)
    case invalidEngineOutput(String)

    public var description: String {
        switch self {
        case let .invalidSidecar(reason): return "Invalid transcription audio selection: \(reason)"
        case let .missingAudio(path): return "Transcription audio is missing: \(path)"
        case let .invalidSegment(reason): return "Invalid transcript segment: \(reason)"
        case let .unsupportedJob(reason): return "Unsupported transcription job: \(reason)"
        case let .missingConfiguration(reason): return "Transcription is not configured: \(reason)"
        case let .engineFailed(reason): return "Transcription engine failed: \(reason)"
        case let .invalidEngineOutput(reason): return "Invalid transcription engine output: \(reason)"
        }
    }
}

/// Produces the canonical Markdown/JSON/VTT transcript set from a validated Recording Bundle.
/// Engine calls are deliberately synchronous; JobScheduler runs this pipeline as serial heavy work.
public final class TranscriptionPipeline {
    private let workspaceRootURL: URL
    private let bundleValidator: RecordingBundleFinalizing
    private let engine: TranscriptionEngine
    private let searchIndex: SearchIndex?
    private let fileManager: FileManager
    private let now: () -> Date

    public init(
        workspaceRootURL: URL,
        bundleValidator: RecordingBundleFinalizing,
        engine: TranscriptionEngine,
        searchIndex: SearchIndex? = nil,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        self.workspaceRootURL = workspaceRootURL.standardizedFileURL
        self.bundleValidator = bundleValidator
        self.engine = engine
        self.searchIndex = searchIndex
        self.fileManager = fileManager
        self.now = now
    }

    public func generate(
        from bundle: RecordingBundle,
        selection: TranscriptionAudioSidecar?,
        language: TranscriptLanguage,
        onPublished: ((TranscriptionArtifacts) throws -> Void)? = nil
    ) throws -> TranscriptionArtifacts {
        try bundleValidator.validate(bundle)
        let microphone = try microphoneSource(bundle: bundle, selection: selection)
        var sources = [microphone]
        if let system = bundle.system, fileManager.fileExists(atPath: system.preferredAudioFilePath) {
            sources.append(TranscriptAudioSource(
                track: .systemAudio,
                filePath: system.preferredAudioFilePath,
                selection: "original-system-audio"
            ))
        }

        var segments: [TranscriptSegment] = []
        var diagnostics = selection?.diagnostics ?? []
        var detectedLanguages: [TranscriptLanguage] = []
        for source in sources {
            guard fileManager.fileExists(atPath: source.filePath) else {
                throw TranscriptionError.missingAudio(source.filePath)
            }
            let result = try engine.transcribe(
                audioURL: URL(fileURLWithPath: source.filePath),
                language: language,
                track: source.track
            )
            try validate(result.segments, expectedTrack: source.track)
            segments.append(contentsOf: result.segments)
            diagnostics.append(contentsOf: result.diagnostics.map { "\(source.track.rawValue): \($0)" })
            if let detected = result.detectedLanguage, !detectedLanguages.contains(detected) {
                detectedLanguages.append(detected)
            }
        }

        let ordered = segments.sorted {
            if $0.startSeconds == $1.startSeconds { return $0.track.rawValue < $1.track.rawValue }
            return $0.startSeconds < $1.startSeconds
        }.enumerated().map { offset, segment in
            TranscriptSegment(
                id: String(format: "segment-%05d", offset + 1),
                startSeconds: segment.startSeconds,
                endSeconds: segment.endSeconds,
                text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                language: segment.language,
                track: segment.track,
                speaker: segment.speaker
            )
        }
        let generatedAt = now()
        let document = TranscriptDocument(
            schemaVersion: TranscriptDocument.currentSchemaVersion,
            captureSessionID: bundle.captureSessionID,
            meetingRelativePath: bundle.meetingRelativePath,
            language: language,
            detectedLanguages: detectedLanguages,
            engine: engine.engineIdentifier,
            model: engine.modelIdentifier,
            generatedAt: generatedAt,
            audioSources: sources,
            segments: ordered,
            diagnostics: diagnostics
        )
        let paths = Self.artifactPaths(meetingRelativePath: bundle.meetingRelativePath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(document)
        let markdown = Data(renderMarkdown(document).utf8)
        let vtt = Data(renderVTT(document).utf8)
        let artifacts = TranscriptionArtifacts(
            document: document,
            markdownRelativePath: paths.markdown,
            jsonRelativePath: paths.json,
            vttRelativePath: paths.vtt,
            markdown: markdown,
            json: json,
            vtt: vtt
        )
        // Use the same validators as JobScheduler before replacing any existing transcript.
        let expectations = TranscriptionJob.manifest(title: "", bundle: bundle, selection: selection, language: language).expectedOutputs
        for artifact in artifacts.generatedArtifacts {
            guard let expectation = expectations.first(where: { $0.relativePath == artifact.relativePath }) else {
                throw JobsError.unexpectedArtifact(artifact.relativePath)
            }
            switch expectation.validatorID {
            case "markdown": try MarkdownGeneratedArtifactValidator().validate(artifact, expectation: expectation)
            case "json": try JSONGeneratedArtifactValidator().validate(artifact, expectation: expectation)
            case "webvtt": try WebVTTGeneratedArtifactValidator().validate(artifact, expectation: expectation)
            default: throw JobsError.unknownValidator(expectation.validatorID)
            }
        }
        let vault = WorkspaceVault(workspaceRootURL: workspaceRootURL,
            appSupportRootURL: fileManager.temporaryDirectory.appendingPathComponent("Stillmatter-TranscriptionSnapshots"),
            fileManager: fileManager)
        let replacements = try artifacts.generatedArtifacts.map { artifact in
            WorkspaceMarkdownReplacement(relativePath: artifact.relativePath, data: artifact.data,
                expectedVersion: try vault.versionOfMarkdown(relativePath: artifact.relativePath))
        }
        do {
            try vault.replaceMarkdownTransaction(replacements) {
                try self.searchIndex?.update(relativePath: paths.json)
                try onPublished?(artifacts)
            }
        } catch {
            // If publication was undone after indexing, restore the old JSON chunks too.
            if let searchIndex {
                do { try searchIndex.update(relativePath: paths.json) }
                catch { throw WorkspaceVaultError.transactionRollbackFailed("Transcript rollback could not restore search index: \(error)") }
            }
            throw error
        }
        return artifacts
    }

    public static func artifactPaths(meetingRelativePath: String) -> (markdown: String, json: String, vtt: String) {
        let directory = (meetingRelativePath as NSString).deletingLastPathComponent
        let prefix = directory.isEmpty ? "" : directory + "/"
        return (prefix + "transcript.md", prefix + "transcript.json", prefix + "transcript.vtt")
    }

    private func microphoneSource(
        bundle: RecordingBundle,
        selection: TranscriptionAudioSidecar?
    ) throws -> TranscriptAudioSource {
        guard let selection = selection else {
            return TranscriptAudioSource(
                track: .microphone,
                filePath: bundle.mic.preferredAudioFilePath,
                selection: TranscriptionAudioSelection.originalMicrophone.rawValue
            )
        }
        guard selection.captureSessionID == bundle.captureSessionID else {
            throw TranscriptionError.invalidSidecar("capture session does not match the Recording Bundle")
        }
        guard URL(fileURLWithPath: selection.recordingBundlePath).standardizedFileURL.path
                == URL(fileURLWithPath: bundle.bundleFilePath).standardizedFileURL.path else {
            throw TranscriptionError.invalidSidecar("Recording Bundle path does not match")
        }
        let selectedPath = URL(fileURLWithPath: selection.selectedAudioFilePath).standardizedFileURL.path
        let allowedPaths = [
            URL(fileURLWithPath: bundle.mic.preferredAudioFilePath).standardizedFileURL.path,
            selection.echoCancelledFilePath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        ].compactMap { $0 }
        guard allowedPaths.contains(selectedPath) else {
            throw TranscriptionError.invalidSidecar("selected audio is neither the bundle microphone nor its echo-cancelled sidecar")
        }
        return TranscriptAudioSource(
            track: .microphone,
            filePath: selectedPath,
            selection: selection.selection.rawValue
        )
    }

    private func validate(_ segments: [TranscriptSegment], expectedTrack: TranscriptTrack) throws {
        for segment in segments {
            guard segment.track == expectedTrack else {
                throw TranscriptionError.invalidSegment("engine returned \(segment.track.rawValue) for \(expectedTrack.rawValue) input")
            }
            guard segment.startSeconds >= 0, segment.endSeconds >= segment.startSeconds else {
                throw TranscriptionError.invalidSegment("timestamps must be ordered and non-negative")
            }
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranscriptionError.invalidSegment("text is empty")
            }
        }
    }

    private func renderMarkdown(_ document: TranscriptDocument) -> String {
        let formatter = ISO8601DateFormatter()
        let detected = document.detectedLanguages.map(\.rawValue).joined(separator: ", ")
        let body = document.segments.map { segment in
            "- [`\(Self.timestamp(segment.startSeconds))`] **\(segment.speaker):** \(segment.text)"
        }.joined(separator: "\n")
        return """
        ---
        type: transcript
        schema_version: \(document.schemaVersion)
        meeting: \(document.meetingRelativePath)
        capture_session_id: \(document.captureSessionID)
        language: \(document.language.rawValue)
        detected_languages: \(detected)
        engine: \(document.engine)
        model: \(document.model)
        generated_at: \(formatter.string(from: document.generatedAt))
        ---

        # Transcript

        \(body)
        """ + "\n"
    }

    private func renderVTT(_ document: TranscriptDocument) -> String {
        let cues = document.segments.map { segment in
            "\(segment.id)\n\(Self.vttTimestamp(segment.startSeconds)) --> \(Self.vttTimestamp(segment.endSeconds))\n<v \(segment.speaker)>\(segment.text)</v>"
        }.joined(separator: "\n\n")
        return "WEBVTT\n\n\(cues)\n"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
    }

    private static func vttTimestamp(_ seconds: Double) -> String {
        let milliseconds = max(0, Int((seconds * 1_000).rounded()))
        return String(
            format: "%02d:%02d:%02d.%03d",
            milliseconds / 3_600_000,
            (milliseconds / 60_000) % 60,
            (milliseconds / 1_000) % 60,
            milliseconds % 1_000
        )
    }
}

public enum TranscriptionJob {
    public static let type = "meeting.transcription"
    public static let stageID = "transcribe"

    public static func manifest(
        title: String,
        bundle: RecordingBundle,
        selection: TranscriptionAudioSidecar?,
        language: TranscriptLanguage = .english
    ) -> JobManifest {
        let paths = TranscriptionPipeline.artifactPaths(meetingRelativePath: bundle.meetingRelativePath)
        var sourceArtifacts = [
            JobArtifactReference(relativePath: bundle.meetingRelativePath, role: "meeting-doorway"),
            JobArtifactReference(relativePath: bundle.bundleFilePath, role: "recording-bundle")
        ]
        if let selection = selection {
            sourceArtifacts += [
                JobArtifactReference(relativePath: selection.metadataFilePath, role: "transcription-audio-selection"),
                JobArtifactReference(relativePath: selection.selectedAudioFilePath, role: "transcription-microphone-audio")
            ]
        }
        if let system = bundle.system {
            sourceArtifacts.append(JobArtifactReference(relativePath: system.preferredAudioFilePath, role: "transcription-system-audio"))
        }
        return JobManifest(
            type: type,
            title: "Transcribe \(title)",
            executionClass: .heavy,
            stages: [JobStageDefinition(id: stageID, title: "Transcribe English/Ukrainian audio and index timestamped chunks")],
            sourceArtifacts: sourceArtifacts,
            expectedOutputs: [
                GeneratedArtifactExpectation(
                    stageID: stageID,
                    relativePath: paths.markdown,
                    validatorID: "markdown",
                    requiredFrontmatterFields: ["schema_version", "language", "engine", "model", "generated_at"],
                    requiredHeadings: ["Transcript"]
                ),
                GeneratedArtifactExpectation(stageID: stageID, relativePath: paths.json, validatorID: "json"),
                GeneratedArtifactExpectation(stageID: stageID, relativePath: paths.vtt, validatorID: "webvtt")
            ],
            metadata: [
                "capture_session_id": bundle.captureSessionID,
                "recording_bundle_path": bundle.bundleFilePath,
                "transcription_audio_selection_path": selection?.metadataFilePath ?? "",
                "language": language.rawValue
            ],
            maxAutomaticRetries: 1
        )
    }
}

public final class TranscriptionJobExecutor: JobExecuting {
    private let pipeline: TranscriptionPipeline
    private let queue: DispatchQueue
    private let onTranscriptGenerated: (JobRecord, TranscriptionArtifacts) throws -> Void
    private let decoder: JSONDecoder

    public init(
        pipeline: TranscriptionPipeline,
        queue: DispatchQueue = DispatchQueue(label: "Stillmatter.Transcription"),
        onTranscriptGenerated: @escaping (JobRecord, TranscriptionArtifacts) throws -> Void = { _, _ in }
    ) {
        self.pipeline = pipeline
        self.queue = queue
        self.onTranscriptGenerated = onTranscriptGenerated
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func execute(
        job: JobRecord,
        stage: JobStageDefinition,
        completion: @escaping (Result<JobStageResult, Error>) -> Void
    ) {
        queue.async { [pipeline, decoder, onTranscriptGenerated] in
            do {
                guard job.manifest.type == TranscriptionJob.type, stage.id == TranscriptionJob.stageID else {
                    throw TranscriptionError.unsupportedJob("\(job.manifest.type)/\(stage.id)")
                }
                guard let bundlePath = job.manifest.metadata["recording_bundle_path"], !bundlePath.isEmpty else {
                    throw TranscriptionError.unsupportedJob("recording_bundle_path is missing")
                }
                let bundle = try decoder.decode(RecordingBundle.self, from: Data(contentsOf: URL(fileURLWithPath: bundlePath)))
                let selection: TranscriptionAudioSidecar?
                if let path = job.manifest.metadata["transcription_audio_selection_path"], !path.isEmpty {
                    selection = try decoder.decode(TranscriptionAudioSidecar.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
                } else {
                    selection = nil
                }
                guard let language = TranscriptLanguage(rawValue: job.manifest.metadata["language"] ?? "") else {
                    throw TranscriptionError.unsupportedJob("language must be en or uk")
                }
                let artifacts = try pipeline.generate(from: bundle, selection: selection, language: language) { artifacts in
                    try onTranscriptGenerated(job, artifacts)
                }
                completion(.success(JobStageResult(
                    artifacts: artifacts.generatedArtifacts,
                    logMessages: [
                        "Generated Markdown, JSON, and WebVTT transcript artifacts",
                        "Indexed \(artifacts.document.segments.count) timestamped transcript segments",
                        "Language: \(language.displayName); engine: \(artifacts.document.engine); model: \(artifacts.document.model)"
                    ]
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }
}

/// Local whisper.cpp adapter. It invokes whisper-cli with JSON output enabled and normalizes
/// both current `transcription` output and older `segments` output into Stillmatter segments.
public final class WhisperCLITranscriptionEngine: TranscriptionEngine {
    public let engineIdentifier = "whisper.cpp"
    public let modelIdentifier: String
    private let executableURL: URL
    private let modelURL: URL
    private let fileManager: FileManager

    public init(executableURL: URL, modelURL: URL, fileManager: FileManager = .default) {
        self.executableURL = executableURL
        self.modelURL = modelURL
        self.modelIdentifier = modelURL.deletingPathExtension().lastPathComponent
        self.fileManager = fileManager
    }

    public func transcribe(
        audioURL: URL,
        language: TranscriptLanguage,
        track: TranscriptTrack
    ) throws -> TranscriptionEngineResult {
        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            throw TranscriptionError.missingConfiguration("whisper-cli is not executable at \(executableURL.path)")
        }
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw TranscriptionError.missingConfiguration("Whisper model is missing at \(modelURL.path)")
        }
        let directory = fileManager.temporaryDirectory.appendingPathComponent("Stillmatter-Whisper-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }
        let prefix = directory.appendingPathComponent("transcript")
        let preparedAudioURL = try prepareAudioInput(audioURL, in: directory)
        let stderrURL = directory.appendingPathComponent("whisper-stderr.log")
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            "-m", modelURL.path,
            "-f", preparedAudioURL.path,
            "-l", language.rawValue,
            "-oj",
            "-of", prefix.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle
        try process.run()
        process.waitUntilExit()
        try stderrHandle.synchronize()
        let stderrText = (try? String(contentsOf: stderrURL)) ?? ""
        guard process.terminationStatus == 0 else {
            throw TranscriptionError.engineFailed(stderrText.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let outputURL = URL(fileURLWithPath: prefix.path + ".json")
        guard fileManager.fileExists(atPath: outputURL.path) else {
            throw TranscriptionError.invalidEngineOutput("whisper-cli did not create \(outputURL.path)")
        }
        let parsed = try parse(data: Data(contentsOf: outputURL), language: language, track: track)
        let diagnostic = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionEngineResult(
            segments: parsed.segments,
            detectedLanguage: parsed.detectedLanguage,
            diagnostics: diagnostic.isEmpty ? [] : [diagnostic]
        )
    }

    private func prepareAudioInput(_ audioURL: URL, in directory: URL) throws -> URL {
        guard audioURL.pathExtension.lowercased() != "wav" else { return audioURL }
        let converterURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        guard fileManager.isExecutableFile(atPath: converterURL.path) else {
            throw TranscriptionError.missingConfiguration("afconvert is required to prepare non-WAV recordings")
        }
        let outputURL = directory.appendingPathComponent("input.wav")
        let process = Process()
        process.executableURL = converterURL
        process.arguments = ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audioURL.path, outputURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, fileManager.fileExists(atPath: outputURL.path) else {
            throw TranscriptionError.engineFailed("afconvert could not decode \(audioURL.path)")
        }
        return outputURL
    }

    private func parse(
        data: Data,
        language: TranscriptLanguage,
        track: TranscriptTrack
    ) throws -> (segments: [TranscriptSegment], detectedLanguage: TranscriptLanguage?) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.invalidEngineOutput("root JSON value is not an object")
        }
        let rows = (root["transcription"] as? [[String: Any]]) ?? (root["segments"] as? [[String: Any]]) ?? []
        let segments = try rows.enumerated().map { offset, row -> TranscriptSegment in
            guard let text = row["text"] as? String else {
                throw TranscriptionError.invalidEngineOutput("segment \(offset + 1) has no text")
            }
            let offsets = row["offsets"] as? [String: Any]
            let start = Self.number(row["start"] ?? row["start_sec"])
                ?? Self.number(offsets?["from"]).map { $0 / 1_000 }
            let end = Self.number(row["end"] ?? row["end_sec"])
                ?? Self.number(offsets?["to"]).map { $0 / 1_000 }
            guard let startSeconds = start, let endSeconds = end else {
                throw TranscriptionError.invalidEngineOutput("segment \(offset + 1) has no timestamps")
            }
            let segmentLanguage = TranscriptLanguage(rawValue: row["language"] as? String ?? "") ?? language
            return TranscriptSegment(
                id: "engine-\(offset + 1)",
                startSeconds: startSeconds,
                endSeconds: endSeconds,
                text: text,
                language: segmentLanguage,
                track: track,
                speaker: track.speakerLabel
            )
        }
        let result = root["result"] as? [String: Any]
        let detectedCode = (result?["language"] as? String) ?? (root["language"] as? String)
        return (segments, detectedCode.flatMap(TranscriptLanguage.init(rawValue:)))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
