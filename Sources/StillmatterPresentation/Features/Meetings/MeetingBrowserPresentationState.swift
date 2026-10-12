import Foundation
import StillmatterCore

/// Feature-level browser selection behavior, independent of AppKit controls.
public struct MeetingBrowserPresentationState: Equatable {
    public private(set) var selectedMeetingID: String?
    public private(set) var selectedMeetingIDs: Set<String>

    public init(selectedMeetingID: String? = nil, selectedMeetingIDs: Set<String> = []) {
        self.selectedMeetingID = selectedMeetingID
        self.selectedMeetingIDs = selectedMeetingIDs
    }

    /// Keeps a valid selection after a reload and otherwise selects the first visible row.
    @discardableResult
    public mutating func reconcile(visibleMeetingIDs: [String], selectedMeetingIDs: Set<String> = []) -> String? {
        guard !visibleMeetingIDs.isEmpty else {
            self.selectedMeetingID = nil
            self.selectedMeetingIDs = []
            return nil
        }
        let retainedID = selectedMeetingID.flatMap { visibleMeetingIDs.contains($0) ? $0 : nil }
        let nextID = retainedID ?? visibleMeetingIDs[0]
        self.selectedMeetingID = nextID
        self.selectedMeetingIDs = selectedMeetingIDs.intersection(Set(visibleMeetingIDs))
        if self.selectedMeetingIDs.isEmpty { self.selectedMeetingIDs = [nextID] }
        return nextID
    }

    public mutating func select(_ meetingID: String, alsoSelected meetingIDs: Set<String>) {
        selectedMeetingID = meetingID
        selectedMeetingIDs = meetingIDs.union([meetingID])
    }

    public mutating func clear() {
        selectedMeetingID = nil
        selectedMeetingIDs = []
    }
}

public struct MeetingPresentationMetricsSnapshot: Codable, Equatable {
    public let meetingReadCount: Int
    public let browserReloadCount: Int
    public let totalMeetingReadDuration: TimeInterval
    public let viewUpdateCount: Int

    public init(meetingReadCount: Int, browserReloadCount: Int = 0,
                totalMeetingReadDuration: TimeInterval, viewUpdateCount: Int) {
        self.meetingReadCount = meetingReadCount
        self.browserReloadCount = browserReloadCount
        self.totalMeetingReadDuration = totalMeetingReadDuration
        self.viewUpdateCount = viewUpdateCount
    }
}

/// Optional, in-memory instrumentation for deterministic tests; it never writes to the console.
public final class MeetingPresentationMetrics {
    private let lock = NSLock()
    private var reads = 0
    private var reloads = 0
    private var readDuration: TimeInterval = 0
    private var updates = 0
    private let now: () -> TimeInterval
    private let onChange: ((MeetingPresentationMetricsSnapshot) -> Void)?

    public init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onChange: ((MeetingPresentationMetricsSnapshot) -> Void)? = nil
    ) {
        self.now = now
        self.onChange = onChange
    }

    @discardableResult
    public func measureMeetingRead<T>(_ load: () throws -> T) rethrows -> T {
        let started = now()
        defer { recordMeetingRead(duration: max(0, now() - started)) }
        return try load()
    }

    public func measureBrowserReload<T>(_ load: () throws -> T) rethrows -> T {
        let started = now()
        defer { recordBrowserReload(duration: max(0, now() - started)) }
        return try load()
    }

    public func recordBrowserReload(duration: TimeInterval) {
        lock.lock()
        reads += 1
        reloads += 1
        readDuration += max(0, duration)
        let current = snapshotWhileLocked
        lock.unlock()
        onChange?(current)
    }

    public func recordMeetingRead(duration: TimeInterval) {
        lock.lock()
        reads += 1
        readDuration += max(0, duration)
        let current = snapshotWhileLocked
        lock.unlock()
        onChange?(current)
    }

    public func recordViewUpdate() {
        lock.lock()
        updates += 1
        let current = snapshotWhileLocked
        lock.unlock()
        onChange?(current)
    }

    public var snapshot: MeetingPresentationMetricsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotWhileLocked
    }

    private var snapshotWhileLocked: MeetingPresentationMetricsSnapshot {
        MeetingPresentationMetricsSnapshot(meetingReadCount: reads, browserReloadCount: reloads,
            totalMeetingReadDuration: readDuration, viewUpdateCount: updates)
    }
}
