import Foundation
import Darwin

#if DEBUG
/// Standalone signed-app entry; normal startup and release never assemble these providers.
@MainActor
enum MeetingFixtureLaunch {
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["STILLMATTER_TASK09_MEETING_FIXTURES"] == "1" else { return false }
        precondition(["STILLMATTER_VALIDATION_WORKSPACE_ROOT", "STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT",
                      "STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT", "HOME", "TMPDIR"].allSatisfy {
            ProcessInfo.processInfo.environment[$0]?.isEmpty == false
        }, "Meeting fixtures require disposable roots")
        if let resultPath = ProcessInfo.processInfo.environment["STILLMATTER_TASK09_MEETING_RESULT_PATH"] {
            try? Data("fixture launch started\n".utf8).write(to: URL(fileURLWithPath: resultPath), options: .atomic)
        }
        Task { @MainActor in
            await MeetingFixtureProviders.make(serviceProvider: { nil }).validateExplicitProviderFixtures()
            if let resultPath = ProcessInfo.processInfo.environment["STILLMATTER_TASK09_MEETING_RESULT_PATH"] {
                try? Data("ticket 17 Meeting state fixtures passed\n".utf8)
                    .write(to: URL(fileURLWithPath: resultPath), options: .atomic)
            }
            Darwin.exit(EXIT_SUCCESS)
        }
        return true
    }
}
#endif
