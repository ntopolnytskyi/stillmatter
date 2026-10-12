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
        Task { @MainActor in
            await MeetingFixtureProviders.make(serviceProvider: { nil }).validateExplicitProviderFixtures()
            Darwin.exit(EXIT_SUCCESS)
        }
        return true
    }
}
#endif
