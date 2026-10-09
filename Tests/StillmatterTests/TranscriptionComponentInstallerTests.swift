import Foundation
import XCTest
@testable import StillmatterCore

final class TranscriptionComponentInstallerTests: XCTestCase {
    func testInstallPublishesProgressAndReadyOnlyAfterCompleteModelPromotion() throws {
        let fixture = try InstallerFixture(acquirer: FixtureAcquirer())
        let ready = expectation(description: "ready")
        var states: [TranscriptionComponentState] = []
        _ = fixture.installer.observe { state in
            states.append(state)
            if case .ready = state { ready.fulfill() }
        }

        fixture.installer.install()
        wait(for: [ready], timeout: 3)

        XCTAssertTrue(states.contains { if case .installing = $0 { return true }; return false })
        XCTAssertEqual(fixture.installer.installedModelURL(), fixture.paths.modelURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.readinessMarkerURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.paths.modelURL.appendingPathComponent("model/model.bin").path))
    }

    func testRapidProgressIsThrottledBeforeObserverPublication() throws {
        let fixture = try InstallerFixture(acquirer: FixtureAcquirer(progressUpdates: 1_000))
        let ready = expectation(description: "ready")
        var installingUpdates = 0
        _ = fixture.installer.observe { state in
            if case .installing = state { installingUpdates += 1 }
            if case .ready = state { ready.fulfill() }
        }

        fixture.installer.install()
        wait(for: [ready], timeout: 3)

        XCTAssertLessThan(installingUpdates, 10)
    }

    func testFailedDownloadRemovesStagingAndDoesNotBecomeReady() throws {
        let fixture = try InstallerFixture(acquirer: FixtureAcquirer(error: FixtureError.downloadFailed))
        let failed = expectation(description: "failed")
        _ = fixture.installer.observe { state in
            if case .failed = state { failed.fulfill() }
        }

        fixture.installer.install()
        wait(for: [failed], timeout: 3)

        XCTAssertNil(fixture.installer.installedModelURL())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.readinessMarkerURL.path))
        let stagingContents = (try? FileManager.default.contentsOfDirectory(atPath: fixture.paths.stagingRootURL.path)) ?? []
        XCTAssertTrue(stagingContents.isEmpty)
    }

    func testPriorPartialInstallIsNeverReportedReady() throws {
        let fixture = try InstallerFixture(acquirer: FixtureAcquirer())
        try FileManager.default.createDirectory(at: fixture.paths.modelURL, withIntermediateDirectories: true)
        try Data("incomplete".utf8).write(to: fixture.paths.modelURL.appendingPathComponent("config.json"))

        XCTAssertEqual(fixture.installer.state(), .partial)
        XCTAssertNil(fixture.installer.installedModelURL())
    }

    func testIncompleteDownloadIsPartialNeverReady() throws {
        let fixture = try InstallerFixture(acquirer: FixtureAcquirer(omitEntry: "model/model.bin"))
        let failed = expectation(description: "failed")
        _ = fixture.installer.observe { state in
            if case .failed = state { failed.fulfill() }
        }

        fixture.installer.install()
        wait(for: [failed], timeout: 3)

        XCTAssertNil(fixture.installer.installedModelURL())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.paths.readinessMarkerURL.path))
    }

    func testCancellationCleansInterruptedDownload() throws {
        let acquirer = BlockingAcquirer()
        let fixture = try InstallerFixture(acquirer: acquirer)
        let failed = expectation(description: "cancelled")
        _ = fixture.installer.observe { state in
            if case let .failed(message) = state, message.contains("cancelled") { failed.fulfill() }
        }

        fixture.installer.install()
        XCTAssertEqual(acquirer.started.wait(timeout: .now() + 2), .success)
        fixture.installer.cancel()
        wait(for: [failed], timeout: 3)

        XCTAssertNil(fixture.installer.installedModelURL())
        let stagingContents = (try? FileManager.default.contentsOfDirectory(atPath: fixture.paths.stagingRootURL.path)) ?? []
        XCTAssertTrue(stagingContents.isEmpty)
    }

    func testModelCompatibilitySupportsIntelAndAppleSiliconMacs() {
        for hardwareModel in ["MacBookPro18,3", "Mac14,7", "MacPro7,1", "x86_64", "unknown"] {
            XCTAssertTrue(TranscriptionModelCompatibility.isSupported(.recommended, hardwareModel: hardwareModel))
            XCTAssertTrue(TranscriptionModelCompatibility.isSupported(.full, hardwareModel: hardwareModel))
        }
        XCTAssertEqual(TranscriptionModelChoice.allCases.first, .recommended)
        XCTAssertEqual(TranscriptionModelChoice.recommended.repository, "dropbox-dash/faster-whisper-large-v3-turbo")
        XCTAssertEqual(TranscriptionModelChoice.full.repository, "Systran/faster-whisper-large-v3")
    }

    func testCancelledReplacementKeepsCurrentInstalledModelActive() throws {
        let fixture = try InstallerFixture(acquirer: FixtureAcquirer())
        fixture.installer.install(model: .recommended)
        waitUntil { fixture.installer.installedModelChoice() == .recommended }
        let blocking = BlockingAcquirer()
        let replacementInstaller = TranscriptionComponentInstaller(
            paths: fixture.paths,
            acquirer: blocking,
            availableCapacity: { _ in Int64.max }
        )

        replacementInstaller.install(model: .full)
        XCTAssertEqual(blocking.started.wait(timeout: .now() + 2), .success)
        replacementInstaller.cancel()
        waitUntil {
            if case .failed = replacementInstaller.state() { return true }
            return false
        }

        XCTAssertEqual(replacementInstaller.installedModelChoice(), .recommended)
        XCTAssertEqual(replacementInstaller.installedModelURL(), fixture.paths.modelURL(for: .recommended))
    }

    func testFailedReplacementKeepsCurrentInstalledModelActive() throws {
        let acquirer = FixtureAcquirer()
        let fixture = try InstallerFixture(acquirer: acquirer)
        fixture.installer.install(model: .recommended)
        waitUntil { fixture.installer.installedModelChoice() == .recommended }
        acquirer.error = FixtureError.downloadFailed

        fixture.installer.install(model: .full)
        waitUntil {
            if case .failed = fixture.installer.state() { return true }
            return false
        }

        XCTAssertEqual(fixture.installer.installedModelChoice(), .recommended)
        XCTAssertEqual(fixture.installer.installedModelURL(), fixture.paths.modelURL(for: .recommended))
    }

    func testSwitchingModelsActivatesNewChoiceWithoutDeletingValidCurrentModel() throws {
        let fixture = try InstallerFixture(acquirer: FixtureAcquirer())
        fixture.installer.install(model: .recommended)
        waitUntil { fixture.installer.installedModelChoice() == .recommended }
        let recommendedURL = fixture.paths.modelURL(for: .recommended)

        fixture.installer.install(model: .full)
        waitUntil { fixture.installer.installedModelChoice() == .full }

        XCTAssertTrue(FileManager.default.fileExists(atPath: recommendedURL.path))
        XCTAssertEqual(fixture.installer.installedModelURL(), fixture.paths.modelURL(for: .full))
    }

    func testDeveloperCLIOverrideWinsWithoutAffectingAppManagedDefault() throws {
        let appSupport = URL(fileURLWithPath: "/tmp/Stillmatter Test Support")
        let configuration = TranscriptionComponentPaths.developerCLIConfiguration(
            environment: [
                "STILLMATTER_WHISPER_CLI": "/developer/whisper-cli",
                "STILLMATTER_WHISPER_MODEL": "/developer/model.bin"
            ],
            applicationSupportURL: appSupport
        )

        XCTAssertEqual(configuration?.executableURL.path, "/developer/whisper-cli")
        XCTAssertEqual(configuration?.modelURL.path, "/developer/model.bin")
        XCTAssertNil(TranscriptionComponentPaths.developerCLIConfiguration(environment: [:], applicationSupportURL: appSupport))
        XCTAssertEqual(TranscriptionComponentPaths(applicationSupportURL: appSupport).modelURL.path,
                       "/tmp/Stillmatter Test Support/Transcription/faster-whisper-large-v3-turbo/faster-whisper-large-v3-turbo")
    }

    func testDiagnosticExposesInstallProgressRetryAndReadyUIState() {
        let missing = TranscriptionComponentDiagnostic.item(for: .notInstalled)
        XCTAssertEqual(missing.status, .missing)
        XCTAssertEqual(missing.actionTitle, "Install")
        XCTAssertEqual(missing.affectedFeatures, ["local meeting transcription"])

        let installing = TranscriptionComponentDiagnostic.item(for: .installing(
            TranscriptionInstallProgress(phase: "Downloading…", completedBytes: 50, totalBytes: 100)
        ))
        XCTAssertEqual(installing.actionTitle, "Cancel")
        XCTAssertTrue(installing.explanation.contains("50%"))

        let failed = TranscriptionComponentDiagnostic.item(for: .failed("network unavailable"))
        XCTAssertEqual(failed.actionTitle, "Retry")
        XCTAssertTrue(failed.explanation.contains("network unavailable"))

        let ready = TranscriptionComponentDiagnostic.item(for: .ready(URL(fileURLWithPath: "/model")))
        XCTAssertEqual(ready.status, .granted)
        XCTAssertNil(ready.actionTitle)
        XCTAssertTrue(ready.affectedFeatures.isEmpty)

        let switching = TranscriptionComponentDiagnostic.item(
            for: .ready(URL(fileURLWithPath: "/recommended")),
            selectedModel: .full,
            installedModel: .recommended
        )
        XCTAssertEqual(switching.actionTitle, "Install Selected")
        XCTAssertEqual(switching.status, .granted)

        let failedReplacement = TranscriptionComponentDiagnostic.item(
            for: .failed("offline"),
            selectedModel: .full,
            installedModel: .recommended
        )
        XCTAssertEqual(failedReplacement.status, .granted)
        XCTAssertTrue(failedReplacement.affectedFeatures.isEmpty)
        XCTAssertTrue(failedReplacement.explanation.contains("remains ready"))
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for installer state")
    }
}

private enum FixtureError: LocalizedError {
    case downloadFailed
    var errorDescription: String? { "fixture download failed" }
}

private final class FixtureAcquirer: TranscriptionModelAcquiring {
    var error: Error?
    let omitEntry: String?
    let progressUpdates: Int

    init(error: Error? = nil, omitEntry: String? = nil, progressUpdates: Int = 2) {
        self.error = error
        self.omitEntry = omitEntry
        self.progressUpdates = progressUpdates
    }

    func acquireModel(
        _ model: TranscriptionModelChoice,
        in stagingURL: URL,
        cancellation: TranscriptionInstallCancellation,
        progress: @escaping (TranscriptionInstallProgress) -> Void
    ) throws -> URL {
        for offset in 0..<progressUpdates {
            progress(TranscriptionInstallProgress(
                phase: "Downloading fixture…",
                completedBytes: Int64(offset),
                totalBytes: Int64(progressUpdates)
            ))
        }
        if let error = error { throw error }
        let modelURL = stagingURL.appendingPathComponent("downloaded-model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        for entry in TranscriptionComponentInstaller.requiredModelEntries where entry != omitEntry {
            let url = modelURL.appendingPathComponent(entry)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: url)
        }
        return modelURL
    }
}

private final class BlockingAcquirer: TranscriptionModelAcquiring {
    let started = DispatchSemaphore(value: 0)

    func acquireModel(
        _ model: TranscriptionModelChoice,
        in stagingURL: URL,
        cancellation: TranscriptionInstallCancellation,
        progress: @escaping (TranscriptionInstallProgress) -> Void
    ) throws -> URL {
        try Data("partial".utf8).write(to: stagingURL.appendingPathComponent("partial-download"))
        started.signal()
        while !cancellation.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
        throw TranscriptionComponentInstallError.cancelled
    }
}

private final class InstallerFixture {
    let rootURL: URL
    let paths: TranscriptionComponentPaths
    let installer: TranscriptionComponentInstaller

    init(acquirer: TranscriptionModelAcquiring) throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterInstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        paths = TranscriptionComponentPaths(applicationSupportURL: rootURL)
        installer = TranscriptionComponentInstaller(
            paths: paths,
            acquirer: acquirer,
            availableCapacity: { _ in Int64.max }
        )
    }

    deinit { try? FileManager.default.removeItem(at: rootURL) }
}
