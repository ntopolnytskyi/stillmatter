import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Owns the index, its filesystem observation, and superseded asynchronous builds.
/// UI and processing subscribers receive nil before a new workspace is installed.
final class SearchIndexRuntime {
    private let databaseURL: URL
    private let builder = SearchIndexBuilder()
    private let onChange: (SearchIndex?, Int) -> Void
    private var monitor: SearchIndexFileMonitor?
    private var buildTask: Task<Void, Never>?
    private var configurationKey: String?
    private(set) var index: SearchIndex?
    private(set) var generation = 0
    private var stopped = false

    init(databaseURL: URL, onChange: @escaping (SearchIndex?, Int) -> Void) {
        self.databaseURL = databaseURL
        self.onChange = onChange
    }

    func configure(_ settings: AppSettings) {
        guard !stopped else { return }
        guard let root = settings.stillmatterRootURL else {
            invalidate()
            configurationKey = nil
            onChange(nil, generation)
            return
        }
        let patterns = excludedPatterns(settings, root: root)
        let key = ([root.standardizedFileURL.path] + patterns.sorted()).joined(separator: "\n")
        guard key != configurationKey else { return }
        build(root: root, patterns: patterns, key: key, recovering: false)
    }

    func recover(_ settings: AppSettings, completion: @escaping (Result<Void, Error>) -> Void) {
        guard !stopped, let root = settings.stillmatterRootURL else {
            completion(.failure(Self.error(1, "Choose a Stillmatter root first.")))
            return
        }
        let patterns = excludedPatterns(settings, root: root)
        build(root: root, patterns: patterns,
              key: ([root.standardizedFileURL.path] + patterns.sorted()).joined(separator: "\n"),
              recovering: true, completion: completion)
    }

    func stop() {
        stopped = true
        invalidate()
        configurationKey = nil
    }

    private func invalidate() {
        generation += 1
        buildTask?.cancel()
        buildTask = nil
        monitor?.stop()
        monitor = nil
        index = nil
    }

    private func build(root: URL, patterns: [String], key: String, recovering: Bool,
                       completion: ((Result<Void, Error>) -> Void)? = nil) {
        invalidate()
        configurationKey = key
        onChange(nil, generation)
        let expected = generation
        buildTask = Task.detached(priority: .utility) { [weak self, builder, databaseURL] in
            let result: Result<SearchIndex, Error>
            do {
                result = .success(try await builder.build(databaseURL: databaseURL,
                    rootURL: root, excludedPatterns: patterns, recovering: recovering))
            } catch { result = .failure(error) }
            await MainActor.run { [weak self] in
                guard let self, !self.stopped, self.generation == expected else {
                    completion?(.failure(Self.error(2, "Index build superseded by newer settings.")))
                    return
                }
                self.buildTask = nil
                switch result {
                case let .success(index):
                    let monitor = SearchIndexFileMonitor(rootURL: root, index: index)
                    monitor.start()
                    self.index = index
                    self.monitor = monitor
                    self.onChange(index, expected)
                    completion?(.success(()))
                case let .failure(error):
                    self.configurationKey = nil
                    NSLog("Could not build Stillmatter search index: \(error)")
                    completion?(.failure(error))
                    self.onChange(nil, expected)
                }
            }
        }
    }

    private func excludedPatterns(_ settings: AppSettings, root: URL) -> [String] {
        var patterns = settings.searchExcludedPatterns
        if let media = settings.recordingMediaURL {
            let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
            let mediaPath = media.standardizedFileURL.resolvingSymlinksInPath().path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            if mediaPath.hasPrefix(prefix) {
                patterns.append(String(mediaPath.dropFirst(prefix.count)) + "/**")
            }
        }
        return patterns
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "Stillmatter.SearchIndex", code: code,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    #if DEBUG || STILLMATTER_NATIVE_PROBES
    /// Narrow setup hook for the opt-in signed Task 04 probe; never used by normal release.
    func installFixtureIndex(databaseURL: URL, root: URL) throws {
        invalidate()
        index = try SearchIndex(databaseURL: databaseURL, workspaceRootURL: root)
    }
    #endif
}
