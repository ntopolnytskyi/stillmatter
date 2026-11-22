import Foundation
import StillmatterCore

/// Owns both phases of Search navigation. The native adapter supplies committed
/// browser/detail reads and applies selection, Tab and playback destinations.
/// Like the Meeting presentation state, this is owned by the main thread.
public final class MeetingSearchNavigation {
    public struct Selection {
        public let meetingID: String
        fileprivate let requestID: UUID
    }

    public struct Destination {
        public let page: MeetingDetailPage
        public let segment: MeetingTranscriptSegment?
        public let seconds: Double?
        public let clearTimeline: Bool
    }

    private struct Route {
        let id = UUID()
        let sourcePath: String
        let result: SearchResult?
        var awaitingBrowser = true
    }

    private weak var owner: AnyObject?
    private var route: Route?
    public private(set) var message: String?
    public var isPending: Bool { route != nil }

    public init() {}

    public func begin(sourcePath: String, result: SearchResult? = nil, owner: AnyObject?) {
        self.owner = owner
        route = Route(sourcePath: sourcePath, result: result)
        message = nil
    }

    public func cancel(clearMessage: Bool = false) {
        route = nil
        owner = nil
        if clearMessage { message = nil }
    }

    public func validateOwner(_ currentOwner: AnyObject?) {
        if isPending, owner !== currentOwner { cancel() }
    }

    /// Loading or an old filtered snapshot cannot decide that a source disappeared.
    /// Each request produces at most one native selection, even for equal snapshots.
    public func selection(rows: [MeetingBrowserRow], isLoaded: Bool, filtersMatch: Bool,
                          owner currentOwner: AnyObject?) -> Selection? {
        validateOwner(currentOwner)
        guard let route, route.awaitingBrowser, isLoaded, filtersMatch else { return nil }
        let directory = (route.sourcePath as NSString).deletingLastPathComponent
        guard let row = rows.first(where: {
            ($0.meetingRelativePath as NSString).deletingLastPathComponent == directory
        }) else {
            cancel()
            message = "Search source is no longer available. Search again."
            return nil
        }
        self.route?.awaitingBrowser = false
        return Selection(meetingID: row.id, requestID: route.id)
    }

    /// Recheck immediately before a queued native selection executes.
    public func isCurrent(_ selection: Selection, owner currentOwner: AnyObject?) -> Bool {
        validateOwner(currentOwner)
        return route?.id == selection.requestID
    }

    public func destination(for detail: MeetingBrowserDetail, owner currentOwner: AnyObject?) -> Destination? {
        validateOwner(currentOwner)
        guard let route, !route.awaitingBrowser,
              (route.sourcePath as NSString).deletingLastPathComponent ==
                (detail.row.meetingRelativePath as NSString).deletingLastPathComponent else { return nil }
        cancel()
        guard let result = route.result else { return nil }
        let filename = (result.sourcePath as NSString).lastPathComponent
        let page: MeetingDetailPage
        switch filename {
        case "my-notes.md", "notes.md": page = .notes
        case "action-items.md": page = .actionItems
        case "open-items.md": page = .openItems
        case "transcript.json", "transcript.txt", "transcript.vtt": page = .transcript
        default: page = .summary
        }
        var segment: MeetingTranscriptSegment?
        if page == .transcript, let seconds = result.transcriptStartSeconds {
            segment = detail.transcript.first {
                $0.startSeconds <= seconds && $0.endSeconds > seconds &&
                    $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == result.body
            }
            if segment == nil {
                message = "The searched utterance changed or is no longer retained. Search again."
            }
        }
        return Destination(page: page, segment: segment, seconds: result.transcriptStartSeconds,
                           clearTimeline: page == .transcript && result.transcriptStartSeconds != nil && segment == nil)
    }
}
