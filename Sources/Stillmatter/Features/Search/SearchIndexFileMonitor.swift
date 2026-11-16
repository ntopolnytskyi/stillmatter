import CoreServices
import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Bridges recursive macOS filesystem events into SearchIndex's incremental update seam.
final class SearchIndexFileMonitor {
    private let rootURL: URL
    private let index: SearchIndex
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "works.stillmatter.search-index-events", qos: .utility)
    private var stream: FSEventStreamRef?
    // Accessed only on queue, including the FSEvents callback.
    private var pendingPaths: Set<String> = []
    private var needsScan = false
    private var pendingFlush: DispatchWorkItem?

    init(rootURL: URL, index: SearchIndex, onChange: @escaping () -> Void = {}) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.index = index
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, eventCount, eventPaths, flags, _ in
            guard let info = info else { return }
            let monitor = Unmanaged<SearchIndexFileMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            for offset in 0..<min(eventCount, paths.count) {
                monitor.handle(path: paths[offset], flags: flags[offset])
            }
        }
        stream = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        )
        guard let stream = stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream = stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync {
            pendingFlush?.cancel()
            pendingFlush = nil
            pendingPaths.removeAll()
            needsScan = false
        }
    }

    deinit {
        stop()
    }

    private func handle(path: String, flags: FSEventStreamEventFlags) {
        // Foundation may leave /var unresolved when the deleted leaf no longer
        // exists. Resolve an existing ancestor, then reattach the removed suffix.
        var ancestor = URL(fileURLWithPath: path).standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        let normalizedPath = resolved.path
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        guard normalizedPath.hasPrefix(rootPath) else { return }
        let relativePath = String(normalizedPath.dropFirst(rootPath.count))
        guard !relativePath.isEmpty else { return }
        if flags & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0 {
            needsScan = true
        } else {
            pendingPaths.insert(relativePath)
        }
        pendingFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in self?.flushChanges() }
        pendingFlush = flush
        queue.asyncAfter(deadline: .now() + 0.5, execute: flush)
    }

    private func flushChanges() {
        pendingFlush = nil
        let paths = pendingPaths
        let scan = needsScan
        pendingPaths.removeAll()
        needsScan = false
        do {
            if scan { try index.startupScan() }
            else {
                for path in paths { try index.update(relativePath: path) }
            }
            onChange()
        } catch {
            NSLog("Could not update search index: %@", String(describing: error))
        }
    }
}
