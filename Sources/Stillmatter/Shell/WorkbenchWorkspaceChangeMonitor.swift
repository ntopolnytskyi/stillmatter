import CoreServices
import Foundation
#if SWIFT_PACKAGE
import StillmatterPresentation
#endif

/// Coalesced, path-scoped external workspace changes for non-Meeting features.
/// The Meeting read model keeps its own independent monitor and revisions.
final class WorkbenchWorkspaceChangeMonitor {
    private let root: URL
    private let onChange: (ShellChange) -> Void
    private let queue = DispatchQueue(label: "works.stillmatter.workbench-events", qos: .utility)
    private var stream: FSEventStreamRef?
    private var pending: Set<ShellChange> = []
    private var flush: DispatchWorkItem?

    init(root: URL, onChange: @escaping (ShellChange) -> Void) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let monitor = Unmanaged<WorkbenchWorkspaceChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            monitor.handle(names: names, flags: flags, count: count)
        }
        guard let created = FSEventStreamCreate(nil, callback, &context, [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)) else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else { stop(); return }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
        queue.sync { flush?.cancel(); flush = nil; pending.removeAll() }
    }

    deinit { stop() }

    private func handle(names: [String], flags: UnsafePointer<FSEventStreamEventFlags>, count: Int) {
        let prefix = root.path + "/"
        let overflow = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs |
            kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
            kFSEventStreamEventFlagRootChanged)
        for i in 0..<min(names.count, count) {
            if flags[i] & overflow != 0 {
                pending.formUnion([.tasks])
                continue
            }
            let path = URL(fileURLWithPath: names[i]).standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            let relative = String(path.dropFirst(prefix.count))
            pending.formUnion(ShellChange.workspaceChanges(for: relative))
        }
        guard !pending.isEmpty else { return }
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let events = self.pending
            self.pending.removeAll()
            self.flush = nil
            DispatchQueue.main.async { [weak self] in
                guard let self, self.stream != nil else { return }
                events.forEach(self.onChange)
            }
        }
        flush = work
        queue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }
}
