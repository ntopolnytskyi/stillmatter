import Foundation
import StillmatterCore

public enum FasterWhisperRuntimeSupport {
    public static func deviceName() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
}

private struct FasterWhisperOutput: Decodable {
    struct Segment: Decodable {
        var start: Double
        var end: Double
        var text: String
    }

    var language: String?
    var segments: [Segment]
}

private enum FasterWhisperRuntimeError: LocalizedError {
    case pythonUnavailable
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .pythonUnavailable:
            return "faster-whisper setup requires Python 3.9 through 3.13 because ONNX Runtime is not available for newer Python versions on macOS. Install a compatible Python, or set STILLMATTER_PYTHON to one, then choose Retry."
        case let .commandFailed(message):
            return message
        }
    }
}

enum FasterWhisperPythonSelector {
    static func isSupported(major: Int, minor: Int) -> Bool {
        major == 3 && (9...13).contains(minor)
    }

    static func select(
        candidates: [URL],
        isExecutable: (URL) -> Bool,
        version: (URL) -> (major: Int, minor: Int)?
    ) -> URL? {
        for candidate in candidates where isExecutable(candidate) {
            guard let version = version(candidate),
                  isSupported(major: version.major, minor: version.minor) else { continue }
            return candidate
        }
        return nil
    }
}

private final class ProcessRunner {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func run(
        executable: URL,
        arguments: [String],
        cancellation: TranscriptionInstallCancellation? = nil,
        environment: [String: String]? = nil
    ) throws -> String {
        let stderrURL = fileManager.temporaryDirectory.appendingPathComponent("Stillmatter-faster-whisper-\(UUID().uuidString).log")
        fileManager.createFile(atPath: stderrURL.path, contents: nil)
        defer { try? fileManager.removeItem(at: stderrURL) }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stderr
        process.standardError = stderr
        if let environment { process.environment = environment }
        try process.run()
        while process.isRunning {
            if cancellation?.isCancelled == true {
                process.terminate()
                process.waitUntilExit()
                throw TranscriptionComponentInstallError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try stderr.synchronize()
        let output = (try? String(contentsOf: stderrURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw FasterWhisperRuntimeError.commandFailed(output.isEmpty
                ? "faster-whisper exited with status \(process.terminationStatus)."
                : output)
        }
        return output
    }
}

public final class FasterWhisperModelAcquirer: TranscriptionModelAcquiring {
    public static let packageVersion = "1.2.1"

    private let fileManager: FileManager
    private let environment: [String: String]
    private let runner: ProcessRunner

    public init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.runner = ProcessRunner(fileManager: fileManager)
    }

    public func acquireModel(
        _ model: TranscriptionModelChoice,
        in stagingURL: URL,
        cancellation: TranscriptionInstallCancellation,
        progress: @escaping (TranscriptionInstallProgress) -> Void
    ) throws -> URL {
        let python = try pythonExecutable()
        let componentURL = stagingURL.appendingPathComponent(model.modelDirectoryName, isDirectory: true)
        let runtimeURL = componentURL.appendingPathComponent("runtime", isDirectory: true)
        let modelURL = componentURL.appendingPathComponent("model", isDirectory: true)
        try fileManager.createDirectory(at: componentURL, withIntermediateDirectories: true)

        progress(.init(phase: "Creating isolated Python runtime…", completedBytes: 0, totalBytes: nil))
        _ = try runner.run(executable: python, arguments: ["-m", "venv", runtimeURL.path], cancellation: cancellation)
        let runtimePython = runtimeURL.appendingPathComponent("bin/python3")

        progress(.init(phase: "Installing faster-whisper \(Self.packageVersion)…", completedBytes: 0, totalBytes: nil))
        _ = try runner.run(
            executable: runtimePython,
            arguments: ["-m", "pip", "install", "--disable-pip-version-check", "--no-input", "--no-cache-dir"] + Self.pythonPackageRequirements,
            cancellation: cancellation
        )

        let setupScriptURL = componentURL.appendingPathComponent("setup.py")
        try Self.setupScript.data(using: .utf8)!.write(to: setupScriptURL, options: .atomic)
        progress(.init(phase: "Downloading \(model.displayName)…", completedBytes: 0, totalBytes: model.downloadBytes))
        _ = try runner.run(
            executable: runtimePython,
            arguments: [setupScriptURL.path, model.repository, model.revision, modelURL.path],
            cancellation: cancellation,
            environment: pythonEnvironment(cacheURL: componentURL.appendingPathComponent("cache", isDirectory: true))
        )
        try fileManager.removeItem(at: setupScriptURL)
        try? fileManager.removeItem(at: componentURL.appendingPathComponent("cache", isDirectory: true))

        let transcriptionScriptURL = componentURL.appendingPathComponent("transcribe.py")
        try Self.transcriptionScript.data(using: .utf8)!.write(to: transcriptionScriptURL, options: .atomic)
        progress(.init(phase: "Checking faster-whisper model…", completedBytes: model.downloadBytes, totalBytes: model.downloadBytes))
        _ = try runner.run(
            executable: runtimePython,
            arguments: [transcriptionScriptURL.path, "--check", modelURL.path],
            cancellation: cancellation,
            environment: pythonEnvironment(cacheURL: componentURL.appendingPathComponent("cache", isDirectory: true))
        )
        return componentURL
    }

    private func pythonExecutable() throws -> URL {
        let candidates: [URL]
        if let configured = environment["STILLMATTER_PYTHON"], !configured.isEmpty {
            candidates = [URL(fileURLWithPath: configured)]
        } else {
            let homebrewRoots = ["/opt/homebrew/bin", "/usr/local/bin"]
            candidates = homebrewRoots.flatMap { root in
                (9...13).reversed().map { URL(fileURLWithPath: "\(root)/python3.\($0)") }
                    + [URL(fileURLWithPath: "\(root)/python3")]
            } + [URL(fileURLWithPath: "/usr/bin/python3")]
        }
        guard let executable = FasterWhisperPythonSelector.select(
            candidates: candidates,
            isExecutable: { fileManager.isExecutableFile(atPath: $0.path) },
            version: { candidate in
                guard let output = try? runner.run(
                    executable: candidate,
                    arguments: ["-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"]
                ) else { return nil }
                let parts = output.split(separator: ".").compactMap { Int($0) }
                guard parts.count >= 2 else { return nil }
                return (parts[0], parts[1])
            }
        ) else {
            throw FasterWhisperRuntimeError.pythonUnavailable
        }
        return executable
    }

    private func pythonEnvironment(cacheURL: URL) -> [String: String] {
        var result = environment
        result["HF_HOME"] = cacheURL.path
        result["PYTHONNOUSERSITE"] = "1"
        return result
    }

    // faster-whisper 1.2.1 passes metadata_errors to av.open; PyAV 19 removed it.
    public static let pythonPackageRequirements = ["faster-whisper==\(packageVersion)", "av>=11,<19"]

    private static let setupScript = #"""
import sys
from huggingface_hub import snapshot_download
snapshot_download(repo_id=sys.argv[1], revision=sys.argv[2], local_dir=sys.argv[3])
"""#

    public static let transcriptionScript = #"""
import json
import sys
from faster_whisper import WhisperModel

if sys.argv[1] == "--check":
    import tempfile
    import wave
    from faster_whisper.audio import decode_audio
    with tempfile.NamedTemporaryFile(suffix=".wav") as sample:
        with wave.open(sample.name, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16000)
            audio.writeframes(b"\x00\x00" * 1600)
        decode_audio(sample.name)
    WhisperModel(sys.argv[2], device="cpu", compute_type="int8")
    raise SystemExit(0)

model_path, audio_path, language, output_path = sys.argv[1:5]
model = WhisperModel(model_path, device="cpu", compute_type="int8")
segments, info = model.transcribe(audio_path, language=language, vad_filter=True)
result = {
    "language": info.language,
    "segments": [
        {"start": segment.start, "end": segment.end, "text": segment.text}
        for segment in segments
    ],
}
with open(output_path, "w", encoding="utf-8") as output:
    json.dump(result, output, ensure_ascii=False)
"""#
}

public final class FasterWhisperTranscriptionEngine: TranscriptionEngine {
    public let engineIdentifier = "faster-whisper"
    public let modelIdentifier: String

    private let componentURL: URL
    private let fileManager: FileManager
    private let runner: ProcessRunner

    public init(componentURL: URL, modelIdentifier: String, fileManager: FileManager = .default) {
        self.componentURL = componentURL
        self.modelIdentifier = modelIdentifier
        self.fileManager = fileManager
        self.runner = ProcessRunner(fileManager: fileManager)
    }

    public func transcribe(
        audioURL: URL,
        language: TranscriptLanguage,
        track: TranscriptTrack
    ) throws -> TranscriptionEngineResult {
        let pythonURL = componentURL.appendingPathComponent("runtime/bin/python3")
        let scriptURL = componentURL.appendingPathComponent("transcribe.py")
        let modelURL = componentURL.appendingPathComponent("model", isDirectory: true)
        guard fileManager.isExecutableFile(atPath: pythonURL.path),
              fileManager.fileExists(atPath: scriptURL.path),
              fileManager.fileExists(atPath: modelURL.appendingPathComponent("model.bin").path) else {
            throw TranscriptionError.missingConfiguration("The faster-whisper component is incomplete.")
        }
        let outputURL = fileManager.temporaryDirectory.appendingPathComponent("Stillmatter-faster-whisper-\(UUID().uuidString).json")
        defer { try? fileManager.removeItem(at: outputURL) }
        let diagnostics = try runner.run(
            executable: pythonURL,
            arguments: [scriptURL.path, modelURL.path, audioURL.path, language.rawValue, outputURL.path]
        )
        let output = try JSONDecoder().decode(FasterWhisperOutput.self, from: Data(contentsOf: outputURL))
        let segments = output.segments.enumerated().compactMap { index, segment -> TranscriptSegment? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return TranscriptSegment(
                id: "faster-whisper-\(index + 1)",
                startSeconds: segment.start,
                endSeconds: segment.end,
                text: text,
                language: language,
                track: track,
                speaker: track.speakerLabel
            )
        }
        return TranscriptionEngineResult(
            segments: segments,
            detectedLanguage: output.language.flatMap(TranscriptLanguage.init(rawValue:)),
            diagnostics: diagnostics.isEmpty ? [] : [diagnostics]
        )
    }
}
