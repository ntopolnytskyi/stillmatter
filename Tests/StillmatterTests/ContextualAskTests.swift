import Foundation
import XCTest
@testable import StillmatterCore

final class ContextualAskTests: XCTestCase {
    func testCurrentContextLimitsSourcesAndReturnsVisibleCitations() throws {
        let fixture = try ContextualAskFixture()
        try fixture.write("# Todos\n\n## Queue\n\n- [ ] Prepare Aurora launch\n", to: "Todos/todo.md")
        try fixture.write("# Meeting\n\nPrepare Aurora launch was discussed.\n", to: "Meetings/aurora/meeting.md")
        try fixture.index.rebuild()
        let runner = RecordingContextualAskRunner { request in
            ContextualAskDraft(
                answer: "Prepare the launch checklist.",
                citations: [ContextualAskCitation(sourcePath: "Todos/todo.md", title: "Prepare Aurora launch")]
            )
        }
        let service = ContextualAskService(searchIndex: fixture.index, runner: runner)

        let answer = try service.ask(ContextualAskRequest(
            question: "What should I prepare for Aurora launch?",
            context: .tasks
        ))

        XCTAssertEqual(answer.sources.map(\.sourcePath), ["Todos/todo.md"])
        XCTAssertEqual(answer.citations, [
            ContextualAskCitation(sourcePath: "Todos/todo.md", title: "Prepare Aurora launch")
        ])
        XCTAssertEqual(runner.requests.first?.context, .tasks)
        XCTAssertFalse(try XCTUnwrap(runner.requests.first).includesBroaderVault)
    }

    func testBroaderVaultOptInCanUseSourcesOutsideCurrentContext() throws {
        let fixture = try ContextualAskFixture()
        try fixture.write("# Todos\n\n- [ ] Prepare Aurora launch\n", to: "Todos/todo.md")
        try fixture.write("# Meeting\n\nPrepare Aurora launch was discussed.\n", to: "Meetings/aurora/meeting.md")
        try fixture.index.rebuild()
        let runner = RecordingContextualAskRunner { request in
            ContextualAskDraft(
                answer: "The task came from the meeting.",
                citations: [ContextualAskCitation(sourcePath: "Meetings/aurora/meeting.md", title: "Meeting")]
            )
        }
        let service = ContextualAskService(searchIndex: fixture.index, runner: runner)

        let answer = try service.ask(ContextualAskRequest(
            question: "Where did the Aurora launch task come from?",
            context: .tasks,
            includesBroaderVault: true
        ))

        XCTAssertEqual(Set(answer.sources.map(\.sourcePath)), ["Todos/todo.md", "Meetings/aurora/meeting.md"])
        XCTAssertTrue(try XCTUnwrap(runner.requests.first).includesBroaderVault)
    }

    func testBroaderVaultMultiPartQuestionDoesNotLetCommonFirstTermCrowdOutSpecificSource() throws {
        let fixture = try ContextualAskFixture()
        for index in 0..<12 {
            try fixture.write(
                "# Processing\n\nWhat is the processing state for recording \(index)?\n",
                to: "Meetings/noise-\(index)/meeting.md"
            )
        }
        let targetPath = "Meetings/orchid-planning/meeting.md"
        try fixture.write("""
        # Orchid planning

        ## Decisions

        The team decided to launch Orchid on October 20.

        ## Other action items

        Jordan will prepare the release announcement.
        """, to: targetPath)
        try fixture.index.rebuild()
        let runner = RecordingContextualAskRunner { request in
            let citedSource = request.sources.first { $0.sourcePath == targetPath } ?? request.sources[0]
            return ContextualAskDraft(
                answer: "Captured retrieved sources.",
                citations: [ContextualAskCitation(sourcePath: citedSource.sourcePath, title: citedSource.title)]
            )
        }
        let service = ContextualAskService(searchIndex: fixture.index, runner: runner)

        _ = try service.ask(ContextualAskRequest(
            question: "What was decided about the Orchid launch and who owns the announcement?",
            context: .tasks,
            includesBroaderVault: true
        ))

        XCTAssertTrue(try XCTUnwrap(runner.requests.first).sources.contains { $0.sourcePath == targetPath })
    }

    func testSourceBackedAnswerMustCiteOnlyVisibleSources() throws {
        let fixture = try ContextualAskFixture()
        try fixture.write("# Todos\n\n- [ ] Prepare Aurora launch\n", to: "Todos/todo.md")
        try fixture.index.rebuild()
        let noCitation = ContextualAskService(
            searchIndex: fixture.index,
            runner: RecordingContextualAskRunner { _ in ContextualAskDraft(answer: "Prepare it.", citations: []) }
        )

        XCTAssertThrowsError(try noCitation.ask(ContextualAskRequest(question: "Aurora", context: .tasks))) { error in
            XCTAssertEqual(error as? ContextualAskError, .missingCitations)
        }

        let hiddenCitation = ContextualAskService(
            searchIndex: fixture.index,
            runner: RecordingContextualAskRunner { _ in
                ContextualAskDraft(
                    answer: "Prepare it.",
                    citations: [ContextualAskCitation(sourcePath: "Private/hidden.md", title: "Hidden")]
                )
            }
        )
        XCTAssertThrowsError(try hiddenCitation.ask(ContextualAskRequest(question: "Aurora", context: .tasks))) { error in
            XCTAssertEqual(error as? ContextualAskError, .unknownCitation("Private/hidden.md"))
        }
    }

    func testPiRunnerUsesToolFreeEphemeralPrompt() throws {
        let commandRunner = ContextualAskCommandRunner(result: PiCommandResult(
            exitCode: 0,
            standardOutput: "{\"schema_version\":1,\"answer\":\"Open the task.\",\"citations\":[{\"source_path\":\"Todos/todo.md\",\"title\":\"Queue\"}]}",
            standardError: ""
        ))
        let runner = PiContextualAskRunner(
            executableURL: URL(fileURLWithPath: "/usr/local/bin/pi"),
            commandRunner: commandRunner
        )
        let request = ContextualAskRunnerRequest(
            question: "What is next?",
            context: .tasks,
            includesBroaderVault: false,
            sources: [ContextualAskSource(
                kind: .todo,
                sourcePath: "Todos/todo.md",
                title: "Queue",
                body: "Prepare Aurora launch"
            )]
        )

        let draft = try runner.answer(request)

        XCTAssertEqual(draft.answer, "Open the task.")
        let command = try XCTUnwrap(commandRunner.commands.first)
        XCTAssertEqual(command.arguments.drop(while: { $0 != "--model" }).dropFirst().first, PiIntegration.codexModel)
        XCTAssertTrue(command.arguments.contains("--no-tools"))
        XCTAssertTrue(command.arguments.contains("--no-session"))
        XCTAssertNil(command.workingDirectory)
        XCTAssertTrue(command.arguments.last?.contains("Todos/todo.md") == true)
        XCTAssertFalse(command.arguments.contains("read,grep,find,ls"))
    }
}

private final class RecordingContextualAskRunner: ContextualAskRunning {
    private(set) var requests: [ContextualAskRunnerRequest] = []
    private let response: (ContextualAskRunnerRequest) throws -> ContextualAskDraft

    init(response: @escaping (ContextualAskRunnerRequest) throws -> ContextualAskDraft) {
        self.response = response
    }

    func answer(_ request: ContextualAskRunnerRequest) throws -> ContextualAskDraft {
        requests.append(request)
        return try response(request)
    }
}

private final class ContextualAskCommandRunner: PiCommandRunning {
    private(set) var commands: [PiCommand] = []
    private let result: PiCommandResult

    init(result: PiCommandResult) {
        self.result = result
    }

    func run(_ command: PiCommand) throws -> PiCommandResult {
        commands.append(command)
        return result
    }
}

private final class ContextualAskFixture {
    let rootURL: URL
    let workspaceURL: URL
    let index: SearchIndex

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        index = try SearchIndex(
            databaseURL: rootURL.appendingPathComponent("search.sqlite"),
            workspaceRootURL: workspaceURL
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: rootURL)
    }

    func write(_ text: String, to relativePath: String) throws {
        let url = workspaceURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }
}
