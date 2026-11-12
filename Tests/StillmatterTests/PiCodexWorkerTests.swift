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

    func testFoundationPiRunnerTimesOutAndTerminatesTheChildProcess() throws {
        let fixture = try PiWorkerFixture()
        let executable = fixture.rootURL.appendingPathComponent("slow-pi.sh")
        try "#!/bin/sh\ntrap '' TERM\nwhile :; do /bin/sleep 1; done\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let command = PiCommand(executable: executable, arguments: [], timeout: 0.1)

        XCTAssertThrowsError(try FoundationPiCommandRunner().run(command)) { error in
            XCTAssertEqual(error as? PiCommandError, .timedOut(0.1))
        }
    }

    func testFoundationPiRunnerRejectsCompletionAfterCancellation() throws {
        let cancellation = JobExecutionCancellation()
        XCTAssertFalse(cancellation.cancelAndWait())
        let command = PiCommand(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], timeout: 2)

        XCTAssertThrowsError(try FoundationPiCommandRunner().run(command, cancellation: cancellation)) { error in
            XCTAssertEqual(error as? JobsError, .executionCancelled)
        }
    }

    func testFoundationPiRPCCommandRunnerSendsPromptAndWaitsForSettledStream() throws {
        let fixture = try PiWorkerFixture()
        let executable = fixture.rootURL.appendingPathComponent("fake-rpc-pi.sh")
        let script = """
        #!/bin/sh
        IFS= read -r request || exit 2
        case "$request" in *synthetic*prompt*) ;; *) exit 3 ;; esac
        printf '%s\\n' 'synthetic diagnostic' >&2
        printf '%s\\n' '{"type":"agent_settled","aborted":false}'
        cat >/dev/null
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let result = try FoundationPiRPCCommandRunner().runRPC(
            PiCommand(executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin"], timeout: 2),
            prompt: "synthetic prompt",
            cancellation: nil
        )

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.standardOutput.contains("agent_settled"))
        XCTAssertEqual(result.standardError.trimmingCharacters(in: .whitespacesAndNewlines), "synthetic diagnostic")
    }

    func testFoundationPiRPCCommandRunnerRejectsExitTimeoutAndOversizedOutput() throws {
        let fixture = try PiWorkerFixture()
        let exitsEarly = fixture.rootURL.appendingPathComponent("exits-early.sh")
        try "#!/bin/sh\nIFS= read -r request\nexit 0\n".write(to: exitsEarly, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exitsEarly.path)
        XCTAssertThrowsError(try FoundationPiRPCCommandRunner().runRPC(
            PiCommand(executable: exitsEarly, arguments: [], timeout: 2), prompt: "synthetic", cancellation: nil
        )) { error in
            XCTAssertEqual(error as? PiWorkerError, .invalidResponse("Pi RPC exited before the agent settled"))
        }

        let waitsForever = fixture.rootURL.appendingPathComponent("waits-forever.sh")
        try "#!/bin/sh\nIFS= read -r request\nwhile :; do /bin/sleep 1; done\n".write(to: waitsForever, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: waitsForever.path)
        XCTAssertThrowsError(try FoundationPiRPCCommandRunner().runRPC(
            PiCommand(executable: waitsForever, arguments: [], timeout: 0.1), prompt: "synthetic", cancellation: nil
        )) { error in
            XCTAssertEqual(error as? PiCommandError, .timedOut(0.1))
        }

        let tooMuchOutput = fixture.rootURL.appendingPathComponent("oversized.py")
        let oversizedScript = """
        #!/usr/bin/python3
        import sys
        sys.stdout.write("x" * 1025)
        sys.stdout.flush()
        """
        try oversizedScript.write(to: tooMuchOutput, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tooMuchOutput.path)
        XCTAssertThrowsError(try FoundationPiRPCCommandRunner(maximumOutputBytes: 1024).runRPC(
            PiCommand(executable: tooMuchOutput, arguments: [], timeout: 5), prompt: "synthetic", cancellation: nil
        )) { error in
            XCTAssertEqual(error as? PiCommandError, .outputExceeded(1024))
            XCTAssertTrue(String(describing: error).contains("byte limit"))
        }
    }

    func testFoundationPiRPCCommandRunnerCancelsAnUnsettledGeneration() throws {
        let fixture = try PiWorkerFixture()
        let executable = fixture.rootURL.appendingPathComponent("waits-for-cancel.sh")
        try "#!/bin/sh\nIFS= read -r request\nwhile :; do /bin/sleep 1; done\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let cancellation = JobExecutionCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { _ = cancellation.cancelAndWait() }

        XCTAssertThrowsError(try FoundationPiRPCCommandRunner().runRPC(
            PiCommand(executable: executable, arguments: [], timeout: 3), prompt: "synthetic", cancellation: cancellation
        )) { error in
            XCTAssertEqual(error as? JobsError, .executionCancelled)
        }
    }

    func testFoundationPiRPCCommandRunnerCanCancelOrTimeOutDuringShutdown() throws {
        let fixture = try PiWorkerFixture()
        let executable = fixture.rootURL.appendingPathComponent("slow-shutdown.py")
        let script = """
        #!/usr/bin/python3
        import sys, time
        sys.stdin.readline()
        print('{"type":"agent_settled","aborted":false}', flush=True)
        time.sleep(2)
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let timeoutCommand = PiCommand(executable: executable, arguments: [], timeout: 1)
        XCTAssertThrowsError(try FoundationPiRPCCommandRunner().runRPC(
            timeoutCommand, prompt: "synthetic", cancellation: nil
        )) { error in
            XCTAssertEqual(error as? PiCommandError, .timedOut(1))
        }

        let cancellation = JobExecutionCancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { _ = cancellation.cancelAndWait() }
        let cancellationCommand = PiCommand(executable: executable, arguments: [], timeout: 3)
        XCTAssertThrowsError(try FoundationPiRPCCommandRunner().runRPC(
            cancellationCommand, prompt: "synthetic", cancellation: cancellation
        )) { error in
            XCTAssertEqual(error as? JobsError, .executionCancelled)
        }
    }

    func testWorkerUsesToolFreeRPCWithOnlyExplicitlySuppliedContext() throws {
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
            commandRunner: runner,
            hasTransferApproval: { true }
        )
        let manifest = fixture.manifest()

        let result = try worker.run(manifest: manifest, suppliedContext: MeetingAnalysisContext(
            transcript: "[u1] Me: Ship it.", myNotes: "Review next week."))

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
        XCTAssertTrue(command.arguments.contains("rpc"))
        XCTAssertEqual(command.arguments.drop(while: { $0 != "--model" }).dropFirst().first, PiIntegration.codexModel)
        XCTAssertTrue(command.arguments.contains("--no-tools"))
        XCTAssertTrue(command.arguments.contains("--no-mcp"))
        XCTAssertTrue(command.arguments.contains("--no-context-files"))
        let prompt = try XCTUnwrap(runner.rpcPrompts.first)
        XCTAssertTrue(prompt.contains("[u1] Me: Ship it."))
        XCTAssertTrue(prompt.contains("Review next week."))
        XCTAssertTrue(prompt.contains("generated Summary, Action Item, Decision, and Open Question content in English"))
        XCTAssertFalse(prompt.contains("Do not mutate"))
        XCTAssertEqual(try fixture.contents(of: "Meetings/kickoff/transcript.md"), "# Transcript\nA decision was made.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.vaultURL.appendingPathComponent("Generated/kickoff-summary.md").path))
    }

    func testWorkerDoesNotLaunchPiWithoutExplicitTransferApproval() throws {
        let fixture = try PiWorkerFixture()
        let runner = RecordingPiCommandRunner(results: [])
        let worker = PiCodexWorker(executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
            vaultRootURL: fixture.vaultURL, commandRunner: runner)

        XCTAssertThrowsError(try worker.run(manifest: fixture.manifest(),
            suppliedContext: MeetingAnalysisContext(transcript: "private text"))) { error in
            XCTAssertEqual(error as? PiWorkerError, .transferApprovalRequired)
        }
        XCTAssertTrue(runner.commands.isEmpty)
        XCTAssertTrue(runner.rpcPrompts.isEmpty)
        XCTAssertTrue(String(describing: PiWorkerError.transferApprovalRequired).contains("No text was sent"))
    }

    func testWorkerRejectsProviderFailureWithoutLeakingDiagnostics() throws {
        let fixture = try PiWorkerFixture()
        let runner = RecordingPiCommandRunner(results: [
            PiCommandResult(exitCode: 1, standardOutput: "", standardError: "account-secret-token")
        ])
        let worker = PiCodexWorker(executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
            vaultRootURL: fixture.vaultURL, commandRunner: runner, hasTransferApproval: { true })
        XCTAssertThrowsError(try worker.run(manifest: fixture.manifest(), suppliedContext: MeetingAnalysisContext(
            transcript: "Synthetic transcript only."))) { error in
            guard case let PiWorkerError.commandFailed(_, message) = error else {
                return XCTFail("Expected a provider failure")
            }
            XCTAssertFalse(message.contains("account-secret-token"))
        }
    }

    func testWorkerRejectsMalformedAbortedAndUnsettledRPCResponses() throws {
        let fixture = try PiWorkerFixture()
        let artifact = #"{"schema_version":1,"artifacts":[]}"#
        let assistant: [String: Any] = ["role": "assistant", "stopReason": "stop",
            "content": [["type": "text", "text": artifact]] as [[String: String]]]
        let ack: [String: Any] = ["type": "response", "id": "stillmatter-analysis",
            "command": "prompt", "success": true]
        let message: [String: Any] = ["type": "message_end", "message": assistant]
        let lengthMessage: [String: Any] = ["type": "message_end", "message": [
            "role": "assistant", "stopReason": "length",
            "content": [["type": "text", "text": artifact]] as [[String: String]]
        ]]
        let cases: [[ [String: Any] ]] = [
            [ack, message],
            [ack, message, ["type": "agent_settled", "aborted": true]],
            [ack, lengthMessage, ["type": "agent_settled", "aborted": false]],
            [message, ["type": "agent_settled", "aborted": false]]
        ]
        for events in cases {
            let runner = RecordingPiCommandRunner(results: [
                PiCommandResult(exitCode: 0, standardOutput: artifact, standardError: "")
            ])
            runner.rpcEventOverride = events
            let worker = PiCodexWorker(executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
                vaultRootURL: fixture.vaultURL, commandRunner: runner, hasTransferApproval: { true })
            XCTAssertThrowsError(try worker.run(manifest: fixture.manifest())) { error in
                XCTAssertTrue(error is PiWorkerError)
            }
        }
        let malformed = RecordingPiCommandRunner(results: [
            PiCommandResult(exitCode: 0, standardOutput: artifact, standardError: ""),
            PiCommandResult(exitCode: 0, standardOutput: artifact, standardError: "")
        ])
        malformed.rpcOutputOverride = "not-json\n"
        let worker = PiCodexWorker(executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
            vaultRootURL: fixture.vaultURL, commandRunner: malformed, hasTransferApproval: { true })
        XCTAssertThrowsError(try worker.run(manifest: fixture.manifest())) { error in
            XCTAssertEqual(error as? PiWorkerError, .invalidResponse("Pi RPC emitted malformed JSONL"))
        }

        malformed.rpcOutputOverride = "42\n"
        XCTAssertThrowsError(try worker.run(manifest: fixture.manifest())) { error in
            XCTAssertEqual(error as? PiWorkerError, .invalidResponse("Pi RPC emitted malformed JSONL"))
        }
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
            commandRunner: runner,
            hasTransferApproval: { true }
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
            commandRunner: runner,
            hasTransferApproval: { true }
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

private final class RecordingPiCommandRunner: PiCommandRunning, PiRPCCommandRunning {
    private(set) var commands: [PiCommand] = []
    private(set) var rpcPrompts: [String] = []
    private var results: [PiCommandResult]
    var rpcEventOverride: [[String: Any]]?
    var rpcOutputOverride: String?

    init(results: [PiCommandResult]) {
        self.results = results
    }

    func run(_ command: PiCommand) throws -> PiCommandResult {
        commands.append(command)
        return results.removeFirst()
    }

    func runRPC(_ command: PiCommand, prompt: String, cancellation: JobExecutionCancellation?) throws -> PiCommandResult {
        commands.append(command)
        rpcPrompts.append(prompt)
        let result = results.removeFirst()
        if let rpcOutputOverride {
            return PiCommandResult(exitCode: result.exitCode, standardOutput: rpcOutputOverride,
                                   standardError: result.standardError)
        }
        let message: [String: Any] = ["role": "assistant", "stopReason": "stop",
            "content": [["type": "text", "text": result.standardOutput]] as [[String: String]]]
        let defaultEvents: [[String: Any]] = [
            ["type": "response", "id": "stillmatter-analysis", "command": "prompt", "success": true],
            ["type": "message_end", "message": message],
            ["type": "agent_settled", "aborted": false]
        ]
        let lines = try (rpcEventOverride ?? defaultEvents).map { event -> String in
            String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self)
        }
        return PiCommandResult(exitCode: result.exitCode,
            standardOutput: lines.joined(separator: "\n"),
            standardError: result.standardError)
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
            forbiddenMutations: ["Todos/todo.md", "Meetings/**"],
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
