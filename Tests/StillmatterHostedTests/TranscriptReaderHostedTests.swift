import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class TranscriptReaderHostedTests: XCTestCase {
    @MainActor
    func testReadingControlsHighlightCopyAndRetainSourceDuringRefresh() throws {
        let reader = TranscriptReaderView(controls: GraphiteFocusControls())
        let phrases = [TranscriptReaderPhrase(id: "one", seconds: 42, speaker: "Me", text: "Budget budget", seekSeconds: 42),
                       TranscriptReaderPhrase(id: "two", seconds: 99, speaker: "Guest", text: "Approved", seekSeconds: nil)]
        reader.load(meetingID: "meeting", phrases: phrases, hasAudio: true, seek: { _ in })
        XCTAssertEqual(reader.state.view, .timestamps)
        reader.search.stringValue = "budget"
        reader.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: reader.search))
        XCTAssertEqual(reader.state.matches.count, 2)
        reader.nextMatch.performClick(nil)
        XCTAssertEqual(reader.state.matchNumber, 2)
        reader.load(meetingID: "meeting", phrases: phrases, hasAudio: false, seek: { _ in })
        XCTAssertEqual(reader.state.matchNumber, 2)
        XCTAssertEqual(reader.search.stringValue, "budget")
        let phrase: NSTextField = try find("transcript-text-one", in: reader)
        XCTAssertFalse(phrase.isEditable)
        XCTAssertNotNil(phrase.attributedStringValue.attribute(.backgroundColor, at: 7, effectiveRange: nil))
        XCTAssertNotNil(phrase.attributedStringValue.attribute(.underlineStyle, at: 7, effectiveRange: nil))
        XCTAssertTrue(phrase.accessibilityHelp()?.contains("characters 8 through 13") == true)
        let time: NSButton = try find("transcript-time-one", in: reader)
        XCTAssertFalse(time.isEnabled)
        reader.viewPicker.selectItem(withTitle: "Clear text")
        reader.changeView()
        XCTAssertEqual(reader.state.view, .clearText)
        XCTAssertThrowsError(try find("transcript-time-one", in: reader) as NSButton)
        reader.viewPicker.selectItem(withTitle: "By speakers")
        reader.changeView()
        XCTAssertEqual(reader.state.view, .speakers)
        reader.previousMatch.performClick(nil)
        XCTAssertEqual(reader.state.matchNumber, 1)
        let beforeTick: NSTextField = try find("transcript-text-one", in: reader)
        reader.setActivePhrase("one")
        XCTAssertTrue(beforeTick.accessibilityHelp()?.contains("Current playback phrase") == true)
        XCTAssertEqual(beforeTick.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                       GraphiteFocusPresentation.Typography.activeTranscriptSegment)
        reader.setActivePhrase("one")
        reader.setActivePhrase(nil)
        let afterTick: NSTextField = try find("transcript-text-one", in: reader)
        XCTAssertTrue(beforeTick === afterTick)
        let menu = try XCTUnwrap(afterTick.menu)
        for (index, expected) in ["Budget budget", "Me 00:00:42 Budget budget", "Me"].enumerated() {
            reader.copyValue(menu.items[index])
            XCTAssertEqual(NSPasteboard.general.string(forType: .string), expected)
        }
        reader.load(meetingID: "other", phrases: [], hasAudio: false, seek: { _ in })
        XCTAssertEqual(reader.feedback.stringValue, "No Transcript available.")
        XCTAssertFalse(reader.nextPage.isEnabled)
        XCTAssertFalse(reader.nextMatch.isEnabled)
        reader.load(meetingID: "third", phrases: phrases, hasAudio: true, seek: { _ in })
        reader.search.stringValue = "missing"
        reader.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: reader.search))
        XCTAssertEqual(reader.feedback.stringValue, "No matches in this recording.")
    }

    @MainActor
    private func find<T: NSView>(_ id: String, in view: NSView) throws -> T {
        if view.accessibilityIdentifier() == id, let result = view as? T { return result }
        for child in view.subviews { if let found: T = try? find(id, in: child) { return found } }
        throw NSError(domain: "TranscriptReaderTests", code: 1)
    }
}
