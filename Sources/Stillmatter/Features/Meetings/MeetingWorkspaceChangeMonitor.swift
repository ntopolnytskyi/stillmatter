import CoreServices
import Foundation
#if SWIFT_PACKAGE
import StillmatterPresentation
#endif

/// Independent FSEvents observation for the Meetings read model. It does not depend on
/// SearchIndex construction or successful indexing, so external edits still invalidate reads.
final class MeetingWorkspaceChangeMonitor {
    private let rootURL: URL
    private let onChange: (MeetingChange) -> Void
    private let queue = DispatchQueue(label: "works.stillmatter.meeting-workspace-events", qos: .utility)
    private var stream: FSEventStreamRef?
    // Accessed only on queue, including from the FSEvents callback.
    private var pending = MeetingWorkspaceChangeBatch()
    private var pendingFlush: DispatchWorkItem?

    init(rootURL: URL, onChange: @escaping (MeetingChange) -> Void) {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
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
            guard let info else { return }
            let monitor = Unmanaged<MeetingWorkspaceChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            monitor.handle(paths: paths, flags: flags, eventCount: eventCount)
        }
        guard let created = FSEventStreamCreate(
            nil,
            callback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        ) else {
            onChange(.monitoringFailed("Could not create the Meeting filesystem monitor."))
            return
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            stop()
            onChange(.monitoringFailed("Could not start the Meeting filesystem monitor."))
            return
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync {
            pendingFlush?.cancel()
            pendingFlush = nil
            pending = MeetingWorkspaceChangeBatch()
        }
    }

    deinit { stop() }

    private func handle(paths: [String], flags: UnsafePointer<FSEventStreamEventFlags>, eventCount: Int) {
        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let overflowFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged)
        for index in 0..<min(paths.count, eventCount) {
            let flag = flags[index]
            if flag & overflowFlags != 0 {
                pending.record(relativePath: "Meetings", mustRescan: true)
                continue
            }
            let normalized = URL(fileURLWithPath: paths[index]).standardizedFileURL.path
            guard normalized.hasPrefix(rootPath) else { continue }
            let relative = String(normalized.dropFirst(rootPath.count))
            pending.record(
                relativePath: relative,
                isDirectory: flag & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0,
                mustRescan: flag & overflowFlags != 0
            )
        }
        guard pending.change != nil else { return }
        pendingFlush?.cancel()
        let flush = DispatchWorkItem { [weak self] in self?.flushChanges() }
        pendingFlush = flush
        queue.asyncAfter(deadline: .now() + 0.5, execute: flush)
    }

    private func flushChanges() {
        pendingFlush = nil
        let change = pending.change
        pending = MeetingWorkspaceChangeBatch()
        if let change { onChange(change) }
    }
}
