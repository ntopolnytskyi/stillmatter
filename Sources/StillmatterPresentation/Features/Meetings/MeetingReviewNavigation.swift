import Foundation
import StillmatterCore

/// Routes a Today review reminder through committed browser and detail reads.
/// Selection, Tab changes and opening the Workbench remain native effects.
/// Like MeetingSearchNavigation, this module is owned by the main thread.
public final class MeetingReviewNavigation {
    public struct Selection {
        public let meetingID: String
        public let meetingPath: String
        fileprivate let requestID: UUID
    }

    public enum DetailDisposition { case display, wait, openActionItems }
    private enum Phase { case browser, queued, detail }
    private struct Request {
        let id = UUID()
        let path: String
        let unavailable: () -> Void
        var phase = Phase.browser
    }

    private weak var owner: AnyObject?
    private var request: Request?
    public var isPending: Bool { request != nil }

    public init() {}

    public func begin(meetingPath: String, owner: AnyObject?, unavailable: @escaping () -> Void) {
        self.owner = owner
        request = Request(path: meetingPath, unavailable: unavailable)
    }

    public func cancel() { request = nil; owner = nil }

    public func selection(rows: [MeetingBrowserRow], state: MeetingDetailLoadState,
                          filtersMatch: Bool, owner: AnyObject?) -> Selection? {
        validateOwner(owner)
        guard let request, request.phase == .browser, state == .loaded, filtersMatch else { return nil }
        guard let row = rows.first(where: { $0.meetingRelativePath == request.path && !$0.isArchived }) else {
            fail(); return nil
        }
        self.request?.phase = .queued
        return Selection(meetingID: row.id, meetingPath: request.path, requestID: request.id)
    }

    /// Recheck both request ownership and target membership at the queued native effect.
    public func beginSelection(_ selection: Selection, rows: [MeetingBrowserRow], owner: AnyObject?) -> Bool {
        validateOwner(owner)
        guard request?.id == selection.requestID, request?.phase == .queued else { return false }
        guard rows.contains(where: { $0.id == selection.meetingID && $0.meetingRelativePath == selection.meetingPath && !$0.isArchived }) else {
            fail(); return false
        }
        request?.phase = .detail
        return true
    }

    public func disposition(for detail: MeetingBrowserDetail, owner: AnyObject?) -> DetailDisposition {
        validateOwner(owner)
        guard let request else { return .display }
        guard request.phase == .detail, detail.row.meetingRelativePath == request.path else { return .wait }
        cancel()
        return .openActionItems
    }

    public func browserStateChanged(_ state: MeetingDetailLoadState, owner: AnyObject?) {
        validateOwner(owner)
        if case .failed = state { fail() }
        if case .unavailable = state { fail() }
    }

    public func detailStateChanged(_ state: MeetingDetailLoadState, owner: AnyObject?) {
        validateOwner(owner)
        guard request?.phase == .detail else { return }
        if case .failed = state { fail() }
        if case .unavailable = state { fail() }
    }

    private func validateOwner(_ current: AnyObject?) {
        if isPending, owner !== current { cancel() }
    }

    private func fail() {
        let unavailable = request?.unavailable
        cancel()
        unavailable?()
    }
}
