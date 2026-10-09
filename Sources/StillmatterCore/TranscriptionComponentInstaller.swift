import Foundation

public enum TranscriptionModelChoice: String, Codable, CaseIterable {
    case recommended = "large-v3-turbo"
    case full = "large-v3"

    public var variant: String { rawValue }
    public var modelDirectoryName: String { "faster-whisper-\(variant)" }

    public var repository: String {
        switch self {
        case .recommended: return "dropbox-dash/faster-whisper-large-v3-turbo"
        case .full: return "Systran/faster-whisper-large-v3"
        }
    }

    public var revision: String {
        switch self {
        case .recommended: return "0a363e9161cbc7ed1431c9597a8ceaf0c4f78fcf"
        case .full: return "edaa852ec7e145841d8ffdb056a99866b5f0a478"
        }
    }

    public var displayName: String {
        switch self {
        case .recommended: return "Recommended — Large v3 Turbo"
        case .full: return "Full quality — Large v3"
        }
    }

    public var downloadBytes: Int64 {
        switch self {
        case .recommended: return 1_620_000_000
        case .full: return 3_100_000_000
        }
    }

    public var requiredFreeBytes: Int64 {
        switch self {
        case .recommended: return 4_000_000_000
        case .full: return 7_000_000_000
        }
    }
}

public struct TranscriptionModelCompatibility {
    /// faster-whisper uses CTranslate2 CPU wheels on both Intel and Apple-silicon Macs.
    public static func isSupported(_ choice: TranscriptionModelChoice, hardwareModel: String) -> Bool {
        true
    }
}

public struct TranscriptionComponentPaths {
    public static let runtimeVersion = "faster-whisper-1.2.1"

    public let applicationSupportURL: URL

    public init(applicationSupportURL: URL) {
        self.applicationSupportURL = applicationSupportURL
    }

    public var rootURL: URL {
        applicationSupportURL.appendingPathComponent("Transcription", isDirectory: true)
    }

    public func installedVersionURL(for choice: TranscriptionModelChoice) -> URL {
        rootURL.appendingPathComponent("faster-whisper-\(choice.variant)", isDirectory: true)
    }

    public func modelURL(for choice: TranscriptionModelChoice) -> URL {
        installedVersionURL(for: choice).appendingPathComponent(choice.modelDirectoryName, isDirectory: true)
    }

    public var installedVersionURL: URL { installedVersionURL(for: .recommended) }
    public var modelURL: URL { modelURL(for: .recommended) }

    public var readinessMarkerURL: URL {
        rootURL.appendingPathComponent("installed.json")
    }

    public var stagingRootURL: URL {
        rootURL.appendingPathComponent("Staging", isDirectory: true)
    }

    public static func developerCLIConfiguration(
        environment: [String: String],
        applicationSupportURL: URL,
        fileManager: FileManager = .default
    ) -> (executableURL: URL, modelURL: URL)? {
        guard let executablePath = environment["STILLMATTER_WHISPER_CLI"], !executablePath.isEmpty else {
            return nil
        }
        let executableURL = URL(fileURLWithPath: executablePath)
        let modelURL = environment["STILLMATTER_WHISPER_MODEL"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? applicationSupportURL.appendingPathComponent("Models/ggml-large-v3-turbo.bin")
        return (executableURL, modelURL)
    }
}

public struct TranscriptionInstallProgress: Equatable {
    public var phase: String
    public var completedBytes: Int64
    public var totalBytes: Int64?

    public init(phase: String, completedBytes: Int64, totalBytes: Int64?) {
        self.phase = phase
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fractionCompleted: Double? {
        guard let totalBytes = totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }
}

public enum TranscriptionComponentState: Equatable {
    case notInstalled
    case partial
    case installing(TranscriptionInstallProgress)
    case cancelling
    case ready(URL)
    case failed(String)

    public var isBusy: Bool {
        switch self {
        case .installing, .cancelling: return true
        case .notInstalled, .partial, .ready, .failed: return false
        }
    }
}

public final class TranscriptionInstallCancellation {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

public enum TranscriptionComponentInstallError: LocalizedError, Equatable {
    case cancelled
    case incompleteModel(String)
    case insufficientDiskSpace(required: Int64, available: Int64)

    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Setup was cancelled. Temporary download files were removed; choose Retry when ready."
        case let .incompleteModel(path):
            return "The downloaded model is incomplete or invalid (missing \(path))."
        case let .insufficientDiskSpace(required, available):
            return "Local transcription needs at least \(Self.gigabytes(required)) GB free during setup; only \(Self.gigabytes(available)) GB is available."
        }
    }

    private static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f", Double(bytes) / 1_000_000_000)
    }
}

public protocol TranscriptionModelAcquiring {
    /// Downloads into `stagingURL`, validates the downloaded snapshot is loadable, and returns its model folder.
    func acquireModel(
        _ model: TranscriptionModelChoice,
        in stagingURL: URL,
        cancellation: TranscriptionInstallCancellation,
        progress: @escaping (TranscriptionInstallProgress) -> Void
    ) throws -> URL
}

public final class TranscriptionComponentInstaller {
    public typealias Observer = (TranscriptionComponentState) -> Void

    private struct Marker: Codable {
        var schemaVersion: Int
        var variant: String
        var runtimeVersion: String
        var modelDirectory: String
    }

    public static let requiredModelEntries = [
        "runtime/bin/python3",
        "transcribe.py",
        "model/config.json",
        "model/model.bin",
        "model/tokenizer.json"
    ]

    public let paths: TranscriptionComponentPaths
    private let acquirer: TranscriptionModelAcquiring
    private let fileManager: FileManager
    private let queue: DispatchQueue
    private let availableCapacity: (URL) -> Int64?
    private let lock = NSLock()
    private var transientState: TranscriptionComponentState?
    private var cancellation: TranscriptionInstallCancellation?
    private var observers: [UUID: Observer] = [:]
    private var lastProgressPublication = Date.distantPast

    public init(
        paths: TranscriptionComponentPaths,
        acquirer: TranscriptionModelAcquiring,
        fileManager: FileManager = .default,
        queue: DispatchQueue = DispatchQueue(label: "Stillmatter.TranscriptionComponentInstaller", qos: .userInitiated),
        availableCapacity: @escaping (URL) -> Int64? = TranscriptionComponentInstaller.defaultAvailableCapacity
    ) {
        self.paths = paths
        self.acquirer = acquirer
        self.fileManager = fileManager
        self.queue = queue
        self.availableCapacity = availableCapacity
    }

    @discardableResult
    public func observe(_ observer: @escaping Observer) -> UUID {
        let id = UUID()
        lock.lock()
        observers[id] = observer
        lock.unlock()
        observer(state())
        return id
    }

    public func removeObserver(_ id: UUID) {
        lock.lock()
        observers.removeValue(forKey: id)
        lock.unlock()
    }

    public func state() -> TranscriptionComponentState {
        lock.lock()
        let transient = transientState
        lock.unlock()
        return transient ?? installedState()
    }

    public func install(model: TranscriptionModelChoice = .recommended) {
        lock.lock()
        guard cancellation == nil else {
            lock.unlock()
            return
        }
        let token = TranscriptionInstallCancellation()
        cancellation = token
        lock.unlock()
        publish(.installing(TranscriptionInstallProgress(phase: "Preparing download…", completedBytes: 0, totalBytes: nil)))

        queue.async { [weak self] in
            self?.performInstall(model: model, cancellation: token)
        }
    }

    public func cancel() {
        lock.lock()
        let token = cancellation
        lock.unlock()
        guard let token = token else { return }
        token.cancel()
        publish(.cancelling)
    }

    public func installedModelURL() -> URL? {
        if case let .ready(url) = installedState() { return url }
        return nil
    }

    public func installedModelChoice() -> TranscriptionModelChoice? {
        guard let marker = try? readMarker(),
              marker.schemaVersion == 1,
              let choice = TranscriptionModelChoice.allCases.first(where: { $0.variant == marker.variant }),
              marker.runtimeVersion == TranscriptionComponentPaths.runtimeVersion,
              marker.modelDirectory == choice.modelDirectoryName,
              (try? validateModel(at: paths.modelURL(for: choice))) != nil else { return nil }
        return choice
    }

    private func performInstall(model: TranscriptionModelChoice, cancellation token: TranscriptionInstallCancellation) {
        let stagingURL = paths.stagingRootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? fileManager.removeItem(at: stagingURL)
            lock.lock()
            cancellation = nil
            lock.unlock()
        }
        do {
            try fileManager.createDirectory(at: paths.rootURL, withIntermediateDirectories: true)
            try removeAbandonedStaging(except: stagingURL)
            if let capacity = availableCapacity(paths.rootURL), capacity < model.requiredFreeBytes {
                throw TranscriptionComponentInstallError.insufficientDiskSpace(required: model.requiredFreeBytes, available: capacity)
            }
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            let modelURL = try acquirer.acquireModel(model, in: stagingURL, cancellation: token) { [weak self] progress in
                guard !token.isCancelled else { return }
                self?.publishProgress(progress)
            }
            try throwIfCancelled(token)
            publish(.installing(TranscriptionInstallProgress(phase: "Validating model…", completedBytes: 0, totalBytes: nil)))
            try validateModel(at: modelURL)
            try throwIfCancelled(token)
            try promote(modelURL: modelURL, model: model, cancellation: token)
            lock.lock()
            cancellation = nil
            lock.unlock()
            publish(.ready(paths.modelURL(for: model)))
        } catch {
            let message: String
            if token.isCancelled || (error as? TranscriptionComponentInstallError) == .cancelled {
                message = TranscriptionComponentInstallError.cancelled.localizedDescription
            } else {
                message = error.localizedDescription
            }
            publish(.failed(message))
        }
    }

    private func promote(modelURL: URL, model: TranscriptionModelChoice, cancellation token: TranscriptionInstallCancellation) throws {
        let candidateVersionURL = paths.rootURL.appendingPathComponent(".candidate-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: candidateVersionURL) }
        try fileManager.createDirectory(at: candidateVersionURL, withIntermediateDirectories: true)
        let candidateModelURL = candidateVersionURL.appendingPathComponent(model.modelDirectoryName, isDirectory: true)
        try fileManager.moveItem(at: modelURL, to: candidateModelURL)
        try validateModel(at: candidateModelURL)
        try throwIfCancelled(token)

        let previousURL = paths.rootURL.appendingPathComponent(".previous-\(UUID().uuidString)", isDirectory: true)
        let installedVersionURL = paths.installedVersionURL(for: model)
        let hadPrevious = fileManager.fileExists(atPath: installedVersionURL.path)
        if hadPrevious {
            try fileManager.moveItem(at: installedVersionURL, to: previousURL)
        }
        do {
            try fileManager.moveItem(at: candidateVersionURL, to: installedVersionURL)
            let marker = Marker(
                schemaVersion: 1,
                variant: model.variant,
                runtimeVersion: TranscriptionComponentPaths.runtimeVersion,
                modelDirectory: model.modelDirectoryName
            )
            let markerData = try JSONEncoder().encode(marker)
            try markerData.write(to: paths.readinessMarkerURL, options: .atomic)
            try? fileManager.removeItem(at: previousURL)
        } catch {
            try? fileManager.removeItem(at: installedVersionURL)
            if hadPrevious { try? fileManager.moveItem(at: previousURL, to: installedVersionURL) }
            throw error
        }
    }

    private func installedState() -> TranscriptionComponentState {
        guard fileManager.fileExists(atPath: paths.readinessMarkerURL.path) else {
            let rootEntries = (try? fileManager.contentsOfDirectory(atPath: paths.rootURL.path)) ?? []
            let hasPartial = rootEntries.contains { $0.hasPrefix("faster-whisper-") || $0.hasPrefix(".candidate-") }
                || fileManager.fileExists(atPath: paths.stagingRootURL.path)
            return hasPartial ? .partial : .notInstalled
        }
        do {
            let marker = try readMarker()
            guard marker.schemaVersion == 1,
                  let choice = TranscriptionModelChoice.allCases.first(where: { $0.variant == marker.variant }),
                  marker.runtimeVersion == TranscriptionComponentPaths.runtimeVersion,
                  marker.modelDirectory == choice.modelDirectoryName else {
                return .partial
            }
            let modelURL = paths.modelURL(for: choice)
            try validateModel(at: modelURL)
            return .ready(modelURL)
        } catch {
            return .partial
        }
    }

    private func readMarker() throws -> Marker {
        try JSONDecoder().decode(Marker.self, from: Data(contentsOf: paths.readinessMarkerURL))
    }

    private func validateModel(at url: URL) throws {
        for entry in Self.requiredModelEntries {
            let entryURL = url.appendingPathComponent(entry)
            guard fileManager.fileExists(atPath: entryURL.path) else {
                throw TranscriptionComponentInstallError.incompleteModel(entry)
            }
        }
    }

    private func removeAbandonedStaging(except currentURL: URL) throws {
        guard fileManager.fileExists(atPath: paths.stagingRootURL.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: paths.stagingRootURL, includingPropertiesForKeys: nil) where url != currentURL {
            try? fileManager.removeItem(at: url)
        }
    }

    private func throwIfCancelled(_ token: TranscriptionInstallCancellation) throws {
        if token.isCancelled { throw TranscriptionComponentInstallError.cancelled }
    }

    private func publishProgress(_ progress: TranscriptionInstallProgress) {
        lock.lock()
        let now = Date()
        guard now.timeIntervalSince(lastProgressPublication) >= 0.2 else {
            lock.unlock()
            return
        }
        lastProgressPublication = now
        lock.unlock()
        publish(.installing(progress))
    }

    private func publish(_ state: TranscriptionComponentState) {
        lock.lock()
        transientState = state
        let callbacks = Array(observers.values)
        lock.unlock()
        DispatchQueue.main.async {
            callbacks.forEach { $0(state) }
        }
    }

    public static func defaultAvailableCapacity(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage { return important }
        if let available = values?.volumeAvailableCapacity { return Int64(available) }
        return nil
    }
}

public struct TranscriptionComponentDiagnostic {
    public static func item(
        for state: TranscriptionComponentState,
        selectedModel: TranscriptionModelChoice = .recommended,
        installedModel: TranscriptionModelChoice? = nil
    ) -> DiagnosticItem {
        let status: DiagnosticStatus
        let explanation: String
        let action: String?
        switch state {
        case .notInstalled:
            status = .missing
            explanation = "Install \(selectedModel.displayName) for local English and Ukrainian transcription. No Homebrew or Terminal is required."
            action = "Install"
        case .partial:
            status = .missing
            explanation = "Local transcription setup is incomplete. Repair downloads into temporary storage and only activates a fully validated model."
            action = "Repair"
        case let .installing(progress):
            status = .unknown
            if let fraction = progress.fractionCompleted {
                explanation = "\(progress.phase) \(Int(fraction * 100))% (\(progress.completedBytes / 1_000_000) MB downloaded)."
            } else {
                explanation = "\(progress.phase) \(progress.completedBytes / 1_000_000) MB downloaded."
            }
            action = "Cancel"
        case .cancelling:
            status = installedModel == nil ? .unknown : .granted
            explanation = installedModel == nil
                ? "Cancelling setup and removing temporary files…"
                : "Cancelling replacement setup and keeping \(installedModel!.displayName) active…"
            action = nil
        case let .ready(url):
            status = .granted
            if let installedModel = installedModel, installedModel != selectedModel {
                explanation = "\(installedModel.displayName) remains ready at \(url.path). Install the selected \(selectedModel.displayName) to switch after validation."
                action = "Install Selected"
            } else {
                explanation = "Local English and Ukrainian transcription is ready at \(url.path)."
                action = nil
            }
        case let .failed(message):
            if let installedModel = installedModel {
                status = .granted
                explanation = "\(installedModel.displayName) remains ready. Replacement setup needs attention: \(message)"
            } else {
                status = .missing
                explanation = "Setup needs attention: \(message)"
            }
            action = "Retry"
        }
        return DiagnosticItem(
            id: "localTranscription",
            title: "Local transcription",
            status: status,
            explanation: explanation,
            affectedFeatures: installedModel != nil || status == .granted ? [] : ["local meeting transcription"],
            actionTitle: action
        )
    }
}
