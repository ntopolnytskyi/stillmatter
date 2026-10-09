import Foundation
import XCTest
@testable import StillmatterCore

final class PiCodexWorkerTests: XCTestCase {
    func testIntegrationCheckDetectsPiAndRunsBoundedCodexProbe() throws {
        let runner = RecordingPiCommandRunner(results: [
            PiCommandResult(exitCode: 0, standardOutput: "0.42.0\n", standardError: ""),
            PiCommandResult(exitCode: 0, standardOutput: "STILLMATTER_PI_OK\n", standardError: "")
        ])
        let integration = PiIntegration(
            executableLocator: { URL(fileURLWithPath: "/opt/homebrew/bin/pi") },
            commandRunner: runner
        )

        let result = integration.testCodex()

        XCTAssertEqual(result, .available(executablePath: "/opt/homebrew/bin/pi", version: "0.42.0"))
        XCTAssertEqual(runner.commands.count, 2)
        XCTAssertEqual(runner.commands[1].executable.path, "/opt/homebrew/bin/pi")
        XCTAssertTrue(runner.commands[1].arguments.contains("openai-codex"))
        XCTAssertEqual(runner.commands[1].arguments.drop(while: { $0 != "--model" }).dropFirst().first, PiIntegration.codexModel)
        XCTAssertTrue(runner.commands[1].arguments.contains("--no-tools"))
        XCTAssertTrue(runner.commands[1].arguments.contains("--no-session"))
        XCTAssertEqual(runner.commands[1].timeout, 30)
    }

    func testWorkerBuildsReadOnlyWholeVaultCommandAndReturnsDeclaredArtifacts() throws {
        let fixture = try PiWorkerFixture()
        try fixture.write("# Transcript\nA decision was made.", to: "Meetings/kickoff/transcript.md")
        let response = """
        {
          "schema_version": 1,
          "artifacts": [
            {"relative_path":"Generated/kickoff-summary.md","content":"---\\nschema_version: 1\\n---\\n# Summary\\nDecision made."},
            {"relative_path":"Generated/kickoff-proposals.json","content":"{\\"schema_version\\":1,\\"proposals\\":[]}"}
          ]
        }
        """
        let runner = RecordingPiCommandRunner(results: [
            PiCommandResult(exitCode: 0, standardOutput: response, standardError: "")
        ])
        let worker = PiCodexWorker(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
            vaultRootURL: fixture.vaultURL,
            commandRunner: runner
        )
        let manifest = fixture.manifest()

        let result = try worker.run(manifest: manifest)

        XCTAssertEqual(result.artifacts.map(\.relativePath), [
            "Generated/kickoff-summary.md",
            "Generated/kickoff-proposals.json"
        ])
        XCTAssertTrue(result.logMessages.contains("Primary source: Meetings/kickoff/transcript.md"))
        XCTAssertTrue(result.logMessages.contains("Intended output: Generated/kickoff-summary.md"))
        XCTAssertTrue(result.logMessages.contains("Intended output: Generated/kickoff-proposals.json"))

        let command = try XCTUnwrap(runner.commands.first)
        XCTAssertEqual(command.workingDirectory, fixture.vaultURL)
        XCTAssertEqual(command.timeout, 120)
        XCTAssertEqual(command.arguments.drop(while: { $0 != "--model" }).dropFirst().first, PiIntegration.codexModel)
        XCTAssertTrue(command.arguments.contains("read,grep,find,ls"))
        XCTAssertFalse(command.arguments.contains("write"))
        XCTAssertFalse(command.arguments.contains("edit"))
        XCTAssertTrue(command.arguments.contains("--no-context-files"))
        XCTAssertTrue(command.arguments.last?.contains("Do not mutate") == true)
        XCTAssertEqual(try fixture.contents(of: "Meetings/kickoff/transcript.md"), "# Transcript\nA decision was made.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultURL.appendingPathComponent("Generated/kickoff-summary.md").path))
    }

    func testWorkerRejectsUndeclaredOrMalformedOutputsWithoutWritingVault() throws {
        let fixture = try PiWorkerFixture()
        let response = """
        {"schema_version":1,"artifacts":[{"relative_path":"Todos/todo.md","content":"hidden mutation"}]}
        """
        let runner = RecordingPiCommandRunner(results: [
            PiCommandResult(exitCode: 0, standardOutput: response, standardError: "")
        ])
        let worker = PiCodexWorker(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
            vaultRootURL: fixture.vaultURL,
            commandRunner: runner
        )

        XCTAssertThrowsError(try worker.run(manifest: fixture.manifest())) { error in
            XCTAssertEqual(error as? PiWorkerError, .unexpectedOutput("Todos/todo.md"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultURL.appendingPathComponent("Todos/todo.md").path))
    }

    func testJobManifestCarriesExplicitPiWorkflowContractAndExecutorUsesIt() throws {
        let fixture = try PiWorkerFixture()
        let runner = RecordingPiCommandRunner(results: [
            PiCommandResult(
                exitCode: 0,
                standardOutput: "{\"schema_version\":1,\"artifacts\":[{\"relative_path\":\"Generated/kickoff-summary.md\",\"content\":\"---\\nschema_version: 1\\n---\\n# Summary\\nDone\"},{\"relative_path\":\"Generated/kickoff-proposals.json\",\"content\":\"{\\\"schema_version\\\":1,\\\"proposals\\\":[]}\"}]}",
                standardError: ""
            )
        ])
        let worker = PiCodexWorker(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
            vaultRootURL: fixture.vaultURL,
            commandRunner: runner
        )
        let executor = PiCodexJobExecutor(worker: worker)
        let workflow = fixture.manifest()
        let jobManifest = try workflow.jobManifest(title: "Summarize kickoff")
        let job = JobRecord(
            id: "pi-1",
            manifest: jobManifest,
            status: .running,
            stages: [],
            createdAt: "2026-01-19T09:00:00Z",
            updatedAt: "2026-01-19T09:00:00Z",
            failureDetails: nil
        )
        let completion = expectation(description: "worker completed")

        executor.execute(job: job, stage: jobManifest.stages[0]) { result in
            switch result {
            case let .success(stageResult):
                XCTAssertEqual(stageResult.artifacts.count, 2)
            case let .failure(error):
                XCTFail("Unexpected failure: \(error)")
            }
            completion.fulfill()
        }

        wait(for: [completion], timeout: 2)
        let encodedContract = try XCTUnwrap(jobManifest.metadata[PiWorkflowManifest.metadataKey])
        let decoded = try JSONDecoder().decode(PiWorkflowManifest.self, from: Data(encodedContract.utf8))
        XCTAssertEqual(decoded.task, workflow.task)
        XCTAssertEqual(decoded.primarySources, workflow.primarySources)
        XCTAssertEqual(decoded.relatedContext, workflow.relatedContext)
        XCTAssertEqual(decoded.expectedOutputs, workflow.expectedOutputs)
        XCTAssertEqual(decoded.forbiddenMutations, workflow.forbiddenMutations)
    }
}

private final class RecordingPiCommandRunner: PiCommandRunning {
    private(set) var commands: [PiCommand] = []
    private var results: [PiCommandResult]

    init(results: [PiCommandResult]) {
        self.results = results
    }

    func run(_ command: PiCommand) throws -> PiCommandResult {
        commands.append(command)
        return results.removeFirst()
    }
}

private final class PiWorkerFixture {
    let rootURL: URL
    let vaultURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        vaultURL = rootURL.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func manifest() -> PiWorkflowManifest {
        PiWorkflowManifest(
            task: "Summarize the kickoff transcript and propose follow-up actions.",
            primarySources: [JobArtifactReference(relativePath: "Meetings/kickoff/transcript.md", role: "transcript")],
            relatedContext: ["Projects/**", "People/**"],
            expectedOutputs: [
                PiWorkflowOutput(
                    relativePath: "Generated/kickoff-summary.md",
                    kind: .markdown,
                    requiredFrontmatterFields: ["schema_version"],
                    requiredHeadings: ["Summary"]
                ),
                PiWorkflowOutput(relativePath: "Generated/kickoff-proposals.json", kind: .proposalJSON)
            ],
            forbiddenMutations: ["Todos/todo.md", "Activities/**", "Meetings/**"],
            timeoutSeconds: 120
        )
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = vaultURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func contents(of relativePath: String) throws -> String {
        try String(contentsOf: vaultURL.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
