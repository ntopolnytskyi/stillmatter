import Foundation
import XCTest
import StillmatterCore
import StillmatterTranscriptionRuntime

final class E5LocalSemanticSearchTests: XCTestCase {
    func testMissingComponentReportsSetupWithoutDownloading() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try E5LocalSemanticSearch(componentURL: root).similarities(query: "query", passages: ["text"])) {
            XCTAssertTrue($0.localizedDescription.contains("Install the offline E5"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testControlledProcessReturnsScoresAndRejectsMalformedOrFailedOutput() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = E5LocalSemanticSearch(componentURL: root)
        try installChild(root, body: "printf '[0.7,0.8]' > \"$6\"")
        XCTAssertEqual(try engine.similarities(query: "text", passages: ["a", "b"]), [0.7, 0.8])
        try installChild(root, body: "printf '[2]' > \"$6\"")
        XCTAssertThrowsError(try engine.similarities(query: "text", passages: ["a"]))
        try installChild(root, body: "printf '[]' > \"$6\"")
        XCTAssertThrowsError(try engine.similarities(query: "text", passages: ["a"]))
        try installChild(root, body: "printf 'broken' > \"$6\"")
        XCTAssertThrowsError(try engine.similarities(query: "text", passages: ["a"]))
        try installChild(root, body: "exit 9")
        XCTAssertThrowsError(try engine.similarities(query: "text", passages: ["a"])) {
            XCTAssertTrue($0.localizedDescription.contains("inference failed"))
        }
    }

    func testUnresponsiveLocalChildHasBoundedLifetime() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try installChild(root, body: "exec /bin/sleep 30")
        let started = Date()
        XCTAssertThrowsError(try E5LocalSemanticSearch(componentURL: root, timeout: 0.1).similarities(query: "text", passages: ["a"])) {
            XCTAssertTrue($0.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Opt-in actual model lane, deliberately separate from controlled transport tests.
    func testActualE5MultilingualParaphraseAccentAndLongDocumentEvaluation() throws {
        guard let component = ProcessInfo.processInfo.environment["STILLMATTER_E5_TEST_COMPONENT"] else {
            throw XCTSkip("Actual E5 evaluation requires an isolated installed component")
        }
        let engine = E5LocalSemanticSearch(componentURL: URL(fileURLWithPath: component))
        let passages = [
            "Olena will deploy the mobile release on Friday after the final security review.",
            "Команда погодила бюджет на нові ноутбуки. Марко перевірить вартість обладнання.",
            "Archived meeting recordings are deleted after six calendar months; summaries remain available.",
            "The office garden needs watering twice a week during summer.",
            "Voice profiles stay on the device and are never sent to the text search index.",
            "Заплановану зустріч перенесли на вівторок о десятій ранку.",
            "The café résumé review with José is scheduled for Thursday."
        ]
        let queries: [(String, Int?)] = [
            ("Who is shipping the phone app and when?", 0), ("Хто випустить мобільний застосунок?", 0),
            ("Who will check the price of the new computers?", 1), ("Що вирішили щодо коштів на ноутбуки?", 1),
            ("How long is the audio kept after archiving?", 2), ("Чи передають голосові дані у пошук?", 4),
            ("When is the rescheduled appointment?", 5), ("cafe resume Jose", 6),
            ("What was the agreed ocean freight contract price?", nil)
        ]
        var report: [[String: Any]] = []
        for (query, expected) in queries {
            let scores = try engine.similarities(query: query, passages: passages)
            XCTAssertEqual(scores.count, passages.count)
            let order = scores.indices.sorted { scores[$0] > scores[$1] }
            report.append(["query": query, "expectedPassage": expected as Any? ?? NSNull(),
                "rank": expected.flatMap { order.firstIndex(of: $0).map { $0 + 1 } } as Any? ?? NSNull(), "order": order])
        }
        // A late passage beyond one model window must remain represented.
        let long = String(repeating: "Office stationery and ordinary supplies. ", count: 600)
            + " Olena will deploy the mobile release on Friday."
        let longScores = try engine.similarities(query: "Who deploys the mobile release?", passages: [long, "The garden needs watering."])
        XCTAssertGreaterThan(longScores[0], longScores[1])
        XCTAssertThrowsError(try engine.similarities(query: String(repeating: "query ", count: 600), passages: ["text"]))
        if let output = ProcessInfo.processInfo.environment["STILLMATTER_E5_TEST_REPORT"] {
            try JSONSerialization.data(withJSONObject: ["model": "multilingual-e5-small FP32 ONNX", "results": report,
                "longDocumentTailRankedFirst": true, "abstention": "Not calibrated"], options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output))
        }
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Stillmatter-E5-tests-\(UUID().uuidString)")
    }

    private func installChild(_ root: URL, body: String) throws {
        let executable = root.appendingPathComponent("runtime/bin/python3")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try ("#!/bin/sh\n" + body + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data().write(to: root.appendingPathComponent("model.onnx"))
        try Data().write(to: root.appendingPathComponent("tokenizer.json"))
    }
}
