#if DEBUG
import AppKit
import StillmatterCore
import StillmatterPresentation

/// Explicit provider assembly for the six native Meeting fixture views. Never used by the app shell.
/// TODO(Task 09): compile only into a dedicated debug harness when the inline Meeting
/// assertion walkthroughs have been extracted from the executable view.
@MainActor
enum MeetingFixtureProviders {
    static func make(
        serviceProvider: @escaping () -> MeetingManagementService?,
        presentConfirmationAlert: @escaping (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }
    ) -> MeetingManagementView {
        let readModel = MeetingReadModel(workspaceID: "meeting-fixture-\(UUID().uuidString)") {
            guard let service = serviceProvider() else { throw MeetingManagementError.unavailable }
            return MeetingManagementReadSource(serviceProvider: { service })
        }
        let mutationExecutor = MeetingMutationExecutor(searchIndex: nil, captureSnapshot: nil) { _, _ in
            serviceProvider()
        }
        // Production services notify the workspace read model after durable writes.
        // These disposable services have no file monitor; supply that notification here.
        let fixtureExecutor = MeetingFixtureMutationExecutor(base: mutationExecutor, readModel: readModel)
        let playbackController = MeetingAudioPlaybackController()
        return MeetingManagementView(
            readModelProvider: { readModel },
            mutationExecutorProvider: { fixtureExecutor },
            playbackTransportProvider: { playbackController },
            openRecording: {}, openWorkspaceFile: { _ in },
            presentConfirmationAlert: presentConfirmationAlert
        )
    }
}

private final class MeetingFixtureMutationExecutor: MeetingMutationExecuting {
    private let base: MeetingMutationExecutor
    private let readModel: MeetingReadModel

    init(base: MeetingMutationExecutor, readModel: MeetingReadModel) {
        self.base = base
        self.readModel = readModel
    }

    func execute(_ mutation: MeetingMutation,
                 completion: @escaping (Result<MeetingMutationOutput, Error>) -> Void) {
        base.execute(mutation) { [readModel] result in
            if case .success = result {
                readModel.invalidate(.rescanRequired(reason: "Disposable fixture mutation committed"))
            }
            completion(result)
        }
    }
}

#endif
