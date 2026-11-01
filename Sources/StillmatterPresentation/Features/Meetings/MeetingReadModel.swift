import Foundation
import StillmatterCore

/// Stable identity used by the read seam. The path remains canonical; IDs are not aliases.
public struct MeetingReference: Equatable, Hashable {
    public let id: String
    public let meetingRelativePath: String

    public init(id: String, meetingRelativePath: String) {
        self.id = id
        self.meetingRelativePath = meetingRelativePath
    }

    public init(row: MeetingBrowserRow) {
        self.init(id: row.id, meetingRelativePath: row.meetingRelativePath)
    }
}

public struct MeetingBrowserReadResult: Equatable {
    public let visibleRows: [MeetingBrowserRow]
    public let availableRows: [MeetingBrowserRow]

    public init(visibleRows: [MeetingBrowserRow], availableRows: [MeetingBrowserRow]) {
        self.visibleRows = visibleRows
        self.availableRows = availableRows
    }
}

/// Immutable browser value stamped with the workspace and invalidation revision that produced it.
public struct MeetingBrowserSnapshot: Equatable {
    public let workspaceID: String
    public let workspaceGeneration: UInt64
    public let revision: UInt64
    public let filters: MeetingBrowserFilters
    public let visibleRows: [MeetingBrowserRow]
    public let availableRows: [MeetingBrowserRow]

    public init(workspaceID: String, workspaceGeneration: UInt64, revision: UInt64,
                filters: MeetingBrowserFilters, visibleRows: [MeetingBrowserRow],
                availableRows: [MeetingBrowserRow]) {
        self.workspaceID = workspaceID
        self.workspaceGeneration = workspaceGeneration
        self.revision = revision
        self.filters = filters
        self.visibleRows = visibleRows
        self.availableRows = availableRows
    }
}

public enum MeetingReadError: Error {
    case workspaceUnavailable
    case stopped
    case meetingNotInBrowser(MeetingReference)
    case superseded
    case sourceFailure(Error)
}

public enum MeetingChange: Equatable {
    case workspaceChanged(String?)
    case workspaceFilesChanged(paths: [String])
    case appMutation(paths: [String])
    case jobTransition(meetingPaths: [String])
    case captureSessionChanged(paths: [String])
    case rescanRequired(reason: String)
    case monitoringFailed(String)
}

public struct MeetingReadChangeEvent: Equatable {
    public let change: MeetingChange
    public let affectedMeetingIDs: Set<String>
    public let workspaceGeneration: UInt64
    public let revision: UInt64
    public let requiresRescan: Bool

    public init(change: MeetingChange, affectedMeetingIDs: Set<String>, workspaceGeneration: UInt64,
                revision: UInt64, requiresRescan: Bool) {
        self.change = change
        self.affectedMeetingIDs = affectedMeetingIDs
        self.workspaceGeneration = workspaceGeneration
        self.revision = revision
        self.requiresRescan = requiresRescan
    }
}

/// All methods are confined to MeetingReadModel's serial read executor.
public protocol MeetingReadSource: AnyObject {
    func browserProjection() throws -> [MeetingBrowserRow]
    func browserRows(filters: MeetingBrowserFilters, from projection: [MeetingBrowserRow]) throws -> MeetingBrowserReadResult
    func detail(for reference: MeetingReference, browserRow: MeetingBrowserRow) throws -> MeetingBrowserDetail
    func updateSearchIndex(_ index: SearchIndex?)
    func updateCaptureSnapshot(_ snapshot: CaptureSnapshot?)
}

public extension MeetingReadSource {
    func updateSearchIndex(_ index: SearchIndex?) {}
    func updateCaptureSnapshot(_ snapshot: CaptureSnapshot?) {}
}

/// Production adapter around the canonical MeetingManagementService read path.
/// Construct and call it only on the read executor; its WorkspaceVault belongs to that executor.
public final class MeetingManagementReadSource: MeetingReadSource {
    public typealias ServiceFactory = (SearchIndex?, CaptureSnapshot?) -> MeetingManagementService

    private let serviceFactory: ServiceFactory
    private var searchIndex: SearchIndex?
    private var captureSnapshot: CaptureSnapshot?

    public init(searchIndex: SearchIndex? = nil, captureSnapshot: CaptureSnapshot? = nil,
                serviceFactory: @escaping ServiceFactory) {
        self.searchIndex = searchIndex
        self.captureSnapshot = captureSnapshot
        self.serviceFactory = serviceFactory
    }

    /// Convenience initializer for fixed test services.
    public convenience init(serviceProvider: @escaping () -> MeetingManagementService) {
        self.init(serviceFactory: { _, _ in serviceProvider() })
    }

    public func updateSearchIndex(_ index: SearchIndex?) { searchIndex = index }
    public func updateCaptureSnapshot(_ snapshot: CaptureSnapshot?) { captureSnapshot = snapshot }

    public func browserProjection() throws -> [MeetingBrowserRow] {
        try serviceFactory(searchIndex, captureSnapshot).browserProjection()
    }

    public func browserRows(filters: MeetingBrowserFilters,
                            from projection: [MeetingBrowserRow]) throws -> MeetingBrowserReadResult {
        let result = try serviceFactory(searchIndex, captureSnapshot).browserRows(filters: filters, from: projection)
        return MeetingBrowserReadResult(visibleRows: result.visible, availableRows: result.available)
    }

    public func detail(for reference: MeetingReference, browserRow: MeetingBrowserRow) throws -> MeetingBrowserDetail {
        guard browserRow.id == reference.id, browserRow.meetingRelativePath == reference.meetingRelativePath else {
            throw MeetingManagementError.notFound(reference.meetingRelativePath)
        }
        return try serviceFactory(searchIndex, captureSnapshot).detail(for: browserRow)
    }
}

/// Cancellation is best-effort: queued work is skipped; already-running reads may finish, but their
/// completion is suppressed. Call `cancel()` when the consumer no longer owns the request.
public final class MeetingReadRequest {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    fileprivate var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public final class MeetingChangeObservation {
    private let state: ObservationState
    private let cancelHandler: () -> Void

    fileprivate init(state: ObservationState, cancelHandler: @escaping () -> Void) {
        self.state = state
        self.cancelHandler = cancelHandler
    }

    public func cancel() {
        guard state.deactivate() else { return }
        cancelHandler()
    }

    deinit { cancel() }
}

private final class ObservationState {
    private let lock = NSLock()
    private var active = true
    func deactivate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        active = false
        return true
    }
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
}

/// Owns the workspace read source, cache, and invalidation revisions on one serial executor.
/// Results and change callbacks are delivered on the main queue. Replacing a workspace or
/// invalidating a request suppresses any result from its older generation/revision.
public final class MeetingReadModel {
    private struct FilterKey: Hashable {
        let query: String
        let startDate: Date?
        let endDate: Date?
        let project: String?
        let processing: String
        let archived: Bool
        init(_ filters: MeetingBrowserFilters) {
            query = filters.query
            startDate = filters.startDate
            endDate = filters.endDate
            project = filters.project
            processing = String(reflecting: filters.processing)
            archived = filters.archived
        }
    }

    private struct CachedBrowser {
        let revision: UInt64
        let snapshot: MeetingBrowserSnapshot
        var accessOrder: UInt64
    }

    private struct Observer {
        let state: ObservationState
        let handler: (MeetingReadChangeEvent) -> Void
    }

    private let stateLock = NSRecursiveLock()
    private let scheduleRead: (@escaping () -> Void) -> Void
    private let deliver: (@escaping () -> Void) -> Void
    private var workspaceID: String?
    private var workspaceGeneration: UInt64 = 1
    private var revision: UInt64 = 0
    private var stopped = false
    private var nextRequestID: UInt64 = 0
    private var latestBrowserRequestID: UInt64 = 0
    private var browserProjectionReadCount = 0

    /// Diagnostic count of actual source browser projections (cache hits excluded).
    public var browserProjectionReadCountForValidation: Int {
        stateLock.withLock { browserProjectionReadCount }
    }
    private var latestDetailRequestID: UInt64 = 0
    private var detailRevisions: [String: UInt64] = [:]
    private var latestRows: [String: MeetingBrowserRow] = [:]
    private var observers: [UUID: Observer] = [:]
    private var captureMeetingPath: String?

    // Source and cache are only accessed by scheduleRead operations.
    private var sourceFactory: (() throws -> MeetingReadSource)?
    private var source: MeetingReadSource?
    private var sourceFailure: Error?
    private var browserProjection: [MeetingBrowserRow]?
    private var browserCache: [FilterKey: CachedBrowser] = [:]
    private var browserCacheAccessOrder: UInt64 = 0
    private let browserCacheLimit = 16

    public convenience init(workspaceID: String?, sourceFactory: (() throws -> MeetingReadSource)?) {
        let queue = DispatchQueue(label: "works.stillmatter.meeting-read-model", qos: .userInitiated)
        self.init(workspaceID: workspaceID, sourceFactory: sourceFactory,
                  scheduleRead: { queue.async(execute: $0) },
                  deliver: { DispatchQueue.main.async(execute: $0) })
    }

    /// Executor injection is internal so tests can order completions without sleeps.
    init(workspaceID: String?, sourceFactory: (() throws -> MeetingReadSource)?,
         scheduleRead: @escaping (@escaping () -> Void) -> Void,
         deliver: @escaping (@escaping () -> Void) -> Void) {
        self.workspaceID = workspaceID
        self.sourceFactory = sourceFactory
        self.scheduleRead = scheduleRead
        self.deliver = deliver
        if workspaceID != nil, sourceFactory != nil {
            let generation = workspaceGeneration
            scheduleRead { [weak self] in self?.configureSource(factory: sourceFactory, generation: generation) }
        }
    }

    @discardableResult
    public func readBrowser(filters: MeetingBrowserFilters,
                            completion: @escaping (Result<MeetingBrowserSnapshot, MeetingReadError>) -> Void) -> MeetingReadRequest {
        let request = MeetingReadRequest()
        let context: (UInt64, UInt64, UInt64, String?) = stateLock.withLock {
            nextRequestID += 1
            latestBrowserRequestID = nextRequestID
            return (nextRequestID, workspaceGeneration, revision, workspaceID)
        }
        let (requestID, generation, requestedRevision, requestedWorkspace) = context
        guard requestedWorkspace != nil else {
            deliver { [weak self] in
                guard let self, !request.isCancelled, self.isActiveBrowserRequest(requestID, generation: generation, revision: requestedRevision) else { return }
                completion(.failure(.workspaceUnavailable))
            }
            return request
        }
        scheduleRead { [weak self] in
            guard let self, !request.isCancelled,
                  self.isActiveBrowserRequest(requestID, generation: generation, revision: requestedRevision) else { return }
            let key = FilterKey(filters)
            if var cached = self.browserCache[key], cached.revision == requestedRevision {
                self.browserCacheAccessOrder += 1
                cached.accessOrder = self.browserCacheAccessOrder
                self.browserCache[key] = cached
                self.deliverBrowser(.success(cached.snapshot), request: request, requestID: requestID,
                                    generation: generation, revision: requestedRevision, completion: completion)
                return
            }
            do {
                let source = try self.requiredSource()
                let projection: [MeetingBrowserRow]
                if let cachedProjection = self.browserProjection {
                    projection = cachedProjection
                } else {
                    self.stateLock.withLock { self.browserProjectionReadCount += 1 }
                    projection = try source.browserProjection()
                    self.browserProjection = projection
                }
                let result = try source.browserRows(filters: filters, from: projection)
                guard self.isActiveBrowserRequest(requestID, generation: generation, revision: requestedRevision) else { return }
                let snapshot = MeetingBrowserSnapshot(workspaceID: requestedWorkspace!,
                    workspaceGeneration: generation, revision: requestedRevision, filters: filters,
                    visibleRows: result.visibleRows, availableRows: result.availableRows)
                self.browserCacheAccessOrder += 1
                self.browserCache[key] = CachedBrowser(revision: requestedRevision, snapshot: snapshot,
                                                       accessOrder: self.browserCacheAccessOrder)
                if self.browserCache.count > self.browserCacheLimit,
                   let oldest = self.browserCache.min(by: { $0.value.accessOrder < $1.value.accessOrder })?.key {
                    self.browserCache.removeValue(forKey: oldest)
                }
                self.stateLock.withLock {
                    guard !self.stopped, self.workspaceGeneration == generation,
                          self.revision == requestedRevision else { return }
                    self.latestRows = (result.visibleRows + result.availableRows).reduce(into: [:]) {
                        $0[$1.meetingRelativePath] = $1
                    }
                }
                self.deliverBrowser(.success(snapshot), request: request, requestID: requestID,
                                    generation: generation, revision: requestedRevision, completion: completion)
            } catch {
                self.deliverBrowser(.failure(Self.readError(error)), request: request, requestID: requestID,
                                    generation: generation, revision: requestedRevision, completion: completion)
            }
        }
        return request
    }

    #if DEBUG
    public var task05LatestRows: [String: String] {
        stateLock.withLock { latestRows.mapValues(\.id) }
    }
    #endif

    @discardableResult
    public func readDetail(for reference: MeetingReference,
                           completion: @escaping (Result<MeetingBrowserDetail, MeetingReadError>) -> Void) -> MeetingReadRequest {
        let request = MeetingReadRequest()
        let context: (UInt64, UInt64, UInt64, MeetingBrowserRow?) = stateLock.withLock {
            nextRequestID += 1
            latestDetailRequestID = nextRequestID
            return (nextRequestID, workspaceGeneration,
                    detailRevisions[reference.meetingRelativePath, default: 0],
                    latestRows[reference.meetingRelativePath])
        }
        let (requestID, generation, detailRevision, row) = context
        guard let row, row.id == reference.id else {
            deliver { [weak self] in
                guard let self, !request.isCancelled, self.isActiveDetailRequest(requestID, generation: generation, reference: reference, detailRevision: detailRevision) else { return }
                completion(.failure(.meetingNotInBrowser(reference)))
            }
            return request
        }
        scheduleRead { [weak self] in
            guard let self else { return }
            guard !request.isCancelled else { return }
            guard self.isCurrentDetailRequest(requestID, generation: generation) else { return }
            guard self.isCurrentDetailRevision(reference, detailRevision: detailRevision) else {
                self.deliver { completion(.failure(.superseded)) }
                return
            }
            do {
                let detail = try self.requiredSource().detail(for: reference, browserRow: row)
                self.deliverDetail(.success(detail), request: request, requestID: requestID,
                                   generation: generation, reference: reference,
                                   detailRevision: detailRevision, completion: completion)
            } catch {
                self.deliverDetail(.failure(Self.readError(error)), request: request, requestID: requestID,
                                   generation: generation, reference: reference,
                                   detailRevision: detailRevision, completion: completion)
            }
        }
        return request
    }

    public func invalidate(_ change: MeetingChange) {
        let event: MeetingReadChangeEvent? = stateLock.withLock {
            guard !stopped else { return nil }
            let rows = Array(latestRows.values)
            switch change {
            case let .workspaceFilesChanged(paths), let .appMutation(paths), let .captureSessionChanged(paths):
                return invalidatePaths(paths, rows: rows, originalChange: change)
            case let .jobTransition(paths):
                return invalidatePaths(paths, rows: rows, originalChange: change)
            case let .rescanRequired(reason):
                return invalidateAll(.rescanRequired(reason: reason), rows: rows)
            case let .monitoringFailed(message):
                return invalidateAll(.monitoringFailed(message), rows: rows)
            case .workspaceChanged:
                return nil
            }
        }
        guard let event else { return }
        scheduleRead { [weak self] in
            self?.browserCache.removeAll()
            self?.browserProjection = nil
        }
        notifyObservers(event)
    }

    public func forceRescan() { invalidate(.rescanRequired(reason: "Explicit refresh requested")) }

    public func updateSearchIndex(_ index: SearchIndex?) {
        scheduleRead { [weak self] in
            guard let self, !self.isStopped else { return }
            self.source?.updateSearchIndex(index)
        }
        forceRescan()
    }

    public func updateCaptureSnapshot(_ snapshot: CaptureSnapshot?) {
        let paths: [String] = stateLock.withLock {
            let oldPath = captureMeetingPath
            let newPath = snapshot?.meetingRelativePath
            captureMeetingPath = newPath
            return Set([oldPath, newPath].compactMap { $0 }).sorted()
        }
        scheduleRead { [weak self] in
            guard let self, !self.isStopped else { return }
            self.source?.updateCaptureSnapshot(snapshot)
        }
        if !paths.isEmpty { invalidate(.captureSessionChanged(paths: paths)) }
    }

    @discardableResult
    public func observeChanges(_ handler: @escaping (MeetingReadChangeEvent) -> Void) -> MeetingChangeObservation {
        let id = UUID()
        let state = ObservationState()
        stateLock.withLock {
            if stopped { _ = state.deactivate() }
            else { observers[id] = Observer(state: state, handler: handler) }
        }
        return MeetingChangeObservation(state: state) { [weak self] in
            guard let self else { return }
            _ = self.stateLock.withLock { self.observers.removeValue(forKey: id) }
        }
    }

    /// Replaces the workspace-owned source on the serial executor. Incremented generations
    /// suppress old reads even if their filesystem work completes after this call.
    public func switchWorkspace(to workspaceID: String?, sourceFactory: (() throws -> MeetingReadSource)?) {
        let context: (UInt64, MeetingReadChangeEvent?) = stateLock.withLock {
            guard !stopped else { return (workspaceGeneration, nil) }
            workspaceGeneration += 1
            revision += 1
            latestBrowserRequestID = nextRequestID + 1
            latestDetailRequestID = nextRequestID + 1
            self.workspaceID = workspaceID
            latestRows.removeAll()
            detailRevisions.removeAll()
            captureMeetingPath = nil
            let event = MeetingReadChangeEvent(change: .workspaceChanged(workspaceID), affectedMeetingIDs: [],
                                               workspaceGeneration: workspaceGeneration, revision: revision,
                                               requiresRescan: true)
            return (workspaceGeneration, event)
        }
        scheduleRead { [weak self] in
            guard let self else { return }
            self.source = nil
            self.sourceFailure = nil
            self.browserCache.removeAll()
            self.browserProjection = nil
            self.sourceFactory = sourceFactory
            if workspaceID != nil, let sourceFactory {
                self.configureSource(factory: sourceFactory, generation: context.0)
            }
        }
        if let event = context.1 { notifyObservers(event) }
    }

    /// Ends this workspace lifetime, cancels observers, and suppresses late callbacks.
    public func stop() {
        stateLock.withLock {
            guard !stopped else { return }
            stopped = true
            workspaceGeneration += 1
            latestBrowserRequestID = nextRequestID + 1
            latestDetailRequestID = nextRequestID + 1
            latestRows.removeAll()
            for observer in observers.values { _ = observer.state.deactivate() }
            observers.removeAll()
        }
        scheduleRead { [weak self] in
            self?.source = nil
            self?.sourceFactory = nil
            self?.browserCache.removeAll()
            self?.browserProjection = nil
        }
    }

    private func configureSource(factory: (() throws -> MeetingReadSource)?, generation: UInt64) {
        guard isCurrentWorkspace(generation) else { return }
        guard let factory else { source = nil; sourceFailure = nil; return }
        do { source = try factory(); sourceFailure = nil }
        catch { source = nil; sourceFailure = error }
    }

    private func requiredSource() throws -> MeetingReadSource {
        if let source { return source }
        if let sourceFailure { throw MeetingReadError.sourceFailure(sourceFailure) }
        guard let sourceFactory else { throw MeetingReadError.workspaceUnavailable }
        do {
            let made = try sourceFactory()
            source = made
            sourceFailure = nil
            return made
        } catch {
            sourceFailure = error
            throw MeetingReadError.sourceFailure(error)
        }
    }

    private func deliverBrowser(_ result: Result<MeetingBrowserSnapshot, MeetingReadError>, request: MeetingReadRequest,
                                requestID: UInt64, generation: UInt64, revision: UInt64,
                                completion: @escaping (Result<MeetingBrowserSnapshot, MeetingReadError>) -> Void) {
        deliver { [weak self] in
            guard let self, !request.isCancelled,
                  self.isActiveBrowserRequest(requestID, generation: generation, revision: revision) else { return }
            completion(result)
        }
    }

    private func deliverDetail(_ result: Result<MeetingBrowserDetail, MeetingReadError>, request: MeetingReadRequest,
                               requestID: UInt64, generation: UInt64, reference: MeetingReference,
                               detailRevision: UInt64,
                               completion: @escaping (Result<MeetingBrowserDetail, MeetingReadError>) -> Void) {
        deliver { [weak self] in
            guard let self else { return }
            guard !request.isCancelled else { return }
            guard self.isCurrentDetailRequest(requestID, generation: generation) else { return }
            guard self.isCurrentDetailRevision(reference, detailRevision: detailRevision) else {
                completion(.failure(.superseded))
                return
            }
            completion(result)
        }
    }

    private func notifyObservers(_ event: MeetingReadChangeEvent) {
        let recipients: [(ObservationState, (MeetingReadChangeEvent) -> Void)] = stateLock.withLock {
            observers.values.map { ($0.state, $0.handler) }
        }
        for (state, handler) in recipients {
            deliver { [weak self] in
                guard let self, state.isActive, self.isCurrentWorkspace(generation: event.workspaceGeneration) else { return }
                handler(event)
            }
        }
    }

    private func invalidatePaths(_ paths: [String], rows: [MeetingBrowserRow],
                                 originalChange: MeetingChange) -> MeetingReadChangeEvent? {
        let normalized = Set(paths.map(Self.normalizePath))
        let meetingPaths = normalized.filter { $0 == "Meetings" || $0.hasPrefix("Meetings/") }
        guard !meetingPaths.isEmpty else { return nil }
        var affected: [MeetingBrowserRow] = []
        var requiresRescan = false
        for path in meetingPaths {
            let matches = rows.filter { row in
                let directory = (row.meetingRelativePath as NSString).deletingLastPathComponent
                return path == row.meetingRelativePath || path == directory || path.hasPrefix(directory + "/")
            }
            if matches.isEmpty { requiresRescan = true }
            affected.append(contentsOf: matches)
        }
        if requiresRescan {
            return invalidateAll(.rescanRequired(reason: "Meeting paths changed outside the current browser snapshot"), rows: rows)
        }
        // A file event and its parent directory can both identify the same Meeting.
        // Keep one row per Meeting path so its detail revision advances only once.
        var unique: [String: MeetingBrowserRow] = [:]
        for row in affected { unique[row.meetingRelativePath] = row }
        let values = Array(unique.values)
        guard !values.isEmpty else { return nil }
        revision += 1
        let ids = Set(values.map(\.id))
        for row in values {
            detailRevisions[row.meetingRelativePath, default: 0] += 1
        }
        return MeetingReadChangeEvent(change: originalChange, affectedMeetingIDs: ids,
                                      workspaceGeneration: workspaceGeneration, revision: revision,
                                      requiresRescan: false)
    }

    private func invalidateAll(_ change: MeetingChange, rows: [MeetingBrowserRow]) -> MeetingReadChangeEvent {
        revision += 1
        for row in rows { detailRevisions[row.meetingRelativePath, default: 0] += 1 }
        latestRows.removeAll()
        return MeetingReadChangeEvent(change: change, affectedMeetingIDs: Set(rows.map(\.id)),
                                      workspaceGeneration: workspaceGeneration, revision: revision,
                                      requiresRescan: true)
    }

    private func isActiveBrowserRequest(_ id: UInt64, generation: UInt64, revision requestedRevision: UInt64) -> Bool {
        stateLock.withLock {
            !stopped && workspaceGeneration == generation && revision == requestedRevision && latestBrowserRequestID == id
        }
    }

    private func isActiveDetailRequest(_ id: UInt64, generation: UInt64, reference: MeetingReference,
                                       detailRevision: UInt64) -> Bool {
        stateLock.withLock {
            !stopped && workspaceGeneration == generation && latestDetailRequestID == id &&
                detailRevisions[reference.meetingRelativePath, default: 0] == detailRevision
        }
    }

    private func isCurrentDetailRequest(_ id: UInt64, generation: UInt64) -> Bool {
        stateLock.withLock { !stopped && workspaceGeneration == generation && latestDetailRequestID == id }
    }

    private func isCurrentDetailRevision(_ reference: MeetingReference, detailRevision: UInt64) -> Bool {
        stateLock.withLock { detailRevisions[reference.meetingRelativePath, default: 0] == detailRevision }
    }

    private func isCurrentWorkspace(_ generation: UInt64) -> Bool {
        stateLock.withLock { !stopped && workspaceGeneration == generation }
    }

    private func isCurrentWorkspace(generation: UInt64) -> Bool {
        stateLock.withLock { !stopped && workspaceGeneration == generation }
    }

    private var isStopped: Bool { stateLock.withLock { stopped } }

    private static func readError(_ error: Error) -> MeetingReadError {
        (error as? MeetingReadError) ?? .sourceFailure(error)
    }

    private static func normalizePath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// Accumulates one FSEvents debounce window. Directory moves and dropped event history
/// require a full rescan; unrelated workspace files do not invalidate Meetings.
public struct MeetingWorkspaceChangeBatch: Equatable {
    public private(set) var changedPaths: Set<String> = []
    public private(set) var requiresRescan = false
    private var rescanReason = "Filesystem structure changed"

    public init() {}

    public mutating func record(relativePath: String, isDirectory: Bool = false, mustRescan: Bool = false) {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path == "Meetings" || path.hasPrefix("Meetings/") else { return }
        if mustRescan {
            requiresRescan = true
            rescanReason = "Filesystem event history was dropped"
        } else if isDirectory {
            requiresRescan = true
            if rescanReason != "Filesystem event history was dropped" {
                rescanReason = "Filesystem structure changed"
            }
        } else {
            changedPaths.insert(path)
        }
    }

    public var change: MeetingChange? {
        if requiresRescan { return .rescanRequired(reason: rescanReason) }
        guard !changedPaths.isEmpty else { return nil }
        return .workspaceFilesChanged(paths: changedPaths.sorted())
    }
}

private extension NSRecursiveLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
