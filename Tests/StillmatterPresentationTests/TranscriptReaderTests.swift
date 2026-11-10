import XCTest
import StillmatterCore
@testable import StillmatterPresentation

final class TranscriptReaderTests: XCTestCase {
    func testSearchReachesFourHourTailAndPagesWithoutChangingSourceIdentity() {
        let reader = TranscriptReaderState()
        let phrases = (0..<240).map { index in
            TranscriptReaderPhrase(id: "s\(index)", seconds: Double(index * 60), speaker: index % 2 == 0 ? "Me" : "Guest",
                                   text: "Searchable phrase \(index)", seekSeconds: nil)
        }
        reader.load(meetingID: "a", phrases: phrases)
        reader.setQuery("Searchable")
        XCTAssertEqual(reader.results.count, 240)
        reader.nextPage()
        XCTAssertEqual(reader.pageRows.first?.id, "s100")
        reader.nextPage()
        XCTAssertEqual(reader.pageRows.last?.id, "s239")
        reader.setQuery("phrase 239")
        XCTAssertEqual(reader.pageRows.map(\.id), ["s239"])
        XCTAssertEqual(reader.pageRows.first?.seconds, 14340)
        XCTAssertEqual(reader.phrases, phrases)
    }
    func testFiltersViewsAndRefreshKeepSelectionAndResetAcrossMeetings() {
        let reader = TranscriptReaderState()
        let phrases = [
            TranscriptReaderPhrase(id: "a", seconds: 1, speaker: "Me", text: "Budget budget", seekSeconds: 1),
            TranscriptReaderPhrase(id: "b", seconds: 2, speaker: "Guest", text: "budget approved", seekSeconds: 2),
            TranscriptReaderPhrase(id: "c", seconds: 3, speaker: "Other", text: "Later", seekSeconds: nil)
        ]
        reader.load(meetingID: "a", phrases: phrases)
        reader.setQuery("budget")
        XCTAssertEqual(reader.matches.count, 3)
        reader.nextMatch()
        XCTAssertEqual(reader.selectedMatch?.range, NSRange(location: 7, length: 6))
        reader.nextMatch()
        XCTAssertEqual(reader.selectedID, "b")
        reader.setView(.speakers)
        XCTAssertEqual(reader.selectedID, "b")
        reader.load(meetingID: "a", phrases: phrases)
        XCTAssertEqual(reader.selectedID, "b")
        reader.setSpeakers(["Me", "Other"])
        XCTAssertEqual(reader.results.map(\.id), ["a"])
        reader.setSpeakers(["Other"])
        XCTAssertTrue(reader.results.isEmpty)
        reader.setQuery("")
        XCTAssertEqual(reader.pageRows.map(\.id), ["c"])
        reader.load(meetingID: "b", phrases: [])
        XCTAssertTrue(reader.results.isEmpty)
        XCTAssertTrue(reader.speakers.isEmpty)
        XCTAssertEqual(reader.query, "")
        XCTAssertEqual(reader.view, .speakers)
        XCTAssertEqual(reader.phrases, [])
    }

    func testPagingTraversalBoundsUnicodeAndSourceReveal() {
        let reader = TranscriptReaderState(view: .clearText)
        let phrases = (0..<205).map { index in
            TranscriptReaderPhrase(id: "s\(index)", seconds: Double(index), speaker: index % 2 == 0 ? "A" : "B",
                                   text: "😀 café café", seekSeconds: Double(index))
        }
        reader.load(meetingID: "one", phrases: phrases)
        XCTAssertEqual(reader.availableSpeakers, ["A", "B"])
        reader.previousPage()
        reader.previousMatch()
        reader.nextMatch()
        XCTAssertEqual(reader.page, 0)
        reader.setQuery("cafe")
        XCTAssertEqual(reader.matches.count, 410)
        XCTAssertEqual(reader.selectedMatch?.range, NSRange(location: 3, length: 4))
        reader.nextPage()
        XCTAssertEqual(reader.selectedID, "s100")
        reader.previousPage()
        XCTAssertEqual(reader.selectedID, "s0")
        reader.previousMatch()
        XCTAssertEqual(reader.matchNumber, 1)
        for _ in 0..<410 { reader.nextMatch() }
        XCTAssertEqual(reader.matchNumber, 410)
        XCTAssertEqual(reader.page, 2)
        reader.nextPage()
        XCTAssertEqual(reader.page, 2)
        reader.previousMatch()
        XCTAssertEqual(reader.matchNumber, 409)
        reader.reveal(id: "s103")
        XCTAssertEqual(reader.query, "")
        XCTAssertEqual(reader.selectedID, "s103")
        XCTAssertEqual(reader.page, 1)
        reader.setView(.speakers)
        XCTAssertEqual(reader.selectedID, "s103")
        reader.reveal(id: "missing")
        XCTAssertEqual(reader.selectedID, "s103")
        reader.setSpeakers(["A"])
        XCTAssertNil(reader.selectedID)
        reader.setQuery("   ")
        XCTAssertEqual(reader.results.count, 103)
        reader.setQuery("missing")
        XCTAssertTrue(reader.results.isEmpty)
        reader.setQuery("café")
        reader.setView(.timestamps)
        reader.load(meetingID: "one", phrases: Array(phrases.prefix(2)))
        XCTAssertEqual(reader.results.count, 1)
        XCTAssertEqual(reader.selectedID, "s0")
        XCTAssertEqual(reader.phrases, Array(phrases.prefix(2)))
    }

}
