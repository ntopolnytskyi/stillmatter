import Foundation
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

/// Serializes canonical Meeting mutations. Its service factory is called on this queue so each
/// WorkspaceVault is created and used under one owner, rather than transferred from AppKit.
final class MeetingMutationExecutor: MeetingMutationExecuting {
    typealias ServiceFactory = (SearchIndex?, CaptureSnapshot?) -> MeetingManagementService?

    private let queue = DispatchQueue(label: "works.stillmatter.meeting-mutations", qos: .userInitiated)
    private let serviceFactory: ServiceFactory
    private var searchIndex: SearchIndex?
    private var captureSnapshot: CaptureSnapshot?

    init(searchIndex: SearchIndex?, captureSnapshot: CaptureSnapshot?, serviceFactory: @escaping ServiceFactory) {
        self.searchIndex = searchIndex
        self.captureSnapshot = captureSnapshot
        self.serviceFactory = serviceFactory
    }

    func updateSearchIndex(_ index: SearchIndex?) {
        queue.async { self.searchIndex = index }
    }

    func updateCaptureSnapshot(_ snapshot: CaptureSnapshot?) {
        queue.async { self.captureSnapshot = snapshot }
    }

    func execute(_ mutation: MeetingMutation,
                 completion: @escaping (Result<MeetingMutationOutput, Error>) -> Void) {
        queue.async {
            let result = Result { () throws -> MeetingMutationOutput in
                guard let service = self.serviceFactory(self.searchIndex, self.captureSnapshot) else {
                    throw MeetingManagementError.unavailable
                }
                switch mutation {
                case let .saveNotes(meetingID, text, baseVersion):
                    return .detail(try service.saveHumanNotes(text, for: meetingID, expectedVersion: baseVersion))
                case let .saveSummary(meetingID, sections, baseVersion):
                    return .detail(try service.saveSummary(sections, for: meetingID, expectedVersion: baseVersion))
                case let .saveActionDraft(id, title, comment):
                    try service.saveActionDraft(id: id, title: title, comment: comment)
                    return .none
                case let .reviewAction(id, accept):
                    try service.reviewAction(id: id, accept: accept)
                    return .none
                case let .archive(meetingID):
                    try service.archive(meetingID: meetingID)
                    return .none
                case let .restore(meetingID):
                    try service.restore(meetingID: meetingID)
                    return .none
                case let .rename(meetingID, title, baseVersion):
                    return .detail(try service.rename(meetingID: meetingID, title: title, expectedVersion: baseVersion))
                case let .remove(meetingID):
                    try service.remove(meetingID: meetingID)
                    return .none
                case let .retry(meetingID, jobID):
                    try service.retryFailedJob(meetingID: meetingID, jobID: jobID)
                    return .none
                case let .reprocess(meetingID, language):
                    return .job(try service.reprocess(meetingID: meetingID, language: language))
                }
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
