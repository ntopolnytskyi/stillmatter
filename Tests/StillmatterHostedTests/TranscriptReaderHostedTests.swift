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
        XCTAssertEqual(time.title, "00:00:42")
        XCTAssertNil(time.image, "Phrase timecodes have no play triangle")
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
    func testPaginationSpeakerSelectionSourceNavigationAndTimeActions() throws {
        let navigation = MeetingTimelineNavigation()
        var savedView: TranscriptReadingView?
        var sought: TranscriptReaderPhrase?
        let reader = TranscriptReaderView(controls: GraphiteFocusControls(), saveView: { savedView = $0 }, navigation: navigation)
        let phrases = (0..<205).map { index in
            TranscriptReaderPhrase(id: "s\(index)", seconds: Double(index * 60), speaker: index % 2 == 0 ? "Me" : "Guest",
                                   text: "phrase \(index)", seekSeconds: Double(index * 60))
        }
        reader.load(meetingID: "one", phrases: phrases, hasAudio: true, seek: { sought = $0 })
        let time: NSButton = try find("transcript-time-s0", in: reader)
        time.performClick(nil)
        XCTAssertEqual(sought?.id, "s0")
        reader.search.stringValue = "phrase"
        reader.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: reader.search))
        reader.nextPage.performClick(nil)
        XCTAssertEqual(reader.feedback.stringValue, "Results 101–200 of 205")
        reader.previousPage.performClick(nil)
        XCTAssertEqual(reader.feedback.stringValue, "Results 1–100 of 205")
        let item = NSMenuItem(title: "Me", action: nil, keyEquivalent: "")
        item.representedObject = "Me"
        reader.selectSpeaker(item)
        XCTAssertEqual(reader.state.results.count, 103)
        reader.selectSpeaker(item)
        XCTAssertEqual(reader.state.results.count, 205)
        reader.selectSpeaker(NSMenuItem(title: "All speakers", action: nil, keyEquivalent: ""))
        reader.viewPicker.selectItem(withTitle: "By speakers")
        reader.changeView()
        XCTAssertEqual(savedView, .speakers)
        navigation.show(seconds: 12240, segmentID: "s204", kind: .transcript)
        XCTAssertEqual(reader.state.selectedID, "s204")
        XCTAssertEqual(reader.state.page, 0)
        XCTAssertEqual(reader.state.windowStart, 11700)
        navigation.show(seconds: 0, segmentID: "missing", kind: .transcript)
        XCTAssertEqual(reader.state.selectedID, "s204")
        XCTAssertEqual(TranscriptReaderView.time(.infinity), "Time unavailable")
        XCTAssertEqual(TranscriptReaderView.time(-1), "Time unavailable")
        XCTAssertEqual(TranscriptReaderView.time(14400), "04:00:00")
    }

    @MainActor
    func testMixedTimelinePanelTypeFiltersAndHourNavigationKeepReaderFeatures() throws {
        let reader = TranscriptReaderView(controls: GraphiteFocusControls())
        let phrases = [
            TranscriptReaderPhrase(id: "s1", seconds: 7, speaker: "Me", text: "Budget", seekSeconds: 7),
            TranscriptReaderPhrase(id: "action-s1", seconds: 7, speaker: "Me", text: "Approve budget", seekSeconds: 7,
                kind: .action, sourceSegmentID: "s1", context: "My action · pending"),
            TranscriptReaderPhrase(id: "decision-s2", seconds: 14400, speaker: "Guest", text: "Budget approved", seekSeconds: nil,
                kind: .decision, sourceSegmentID: "s2", context: "Cited decision")
        ]
        reader.load(meetingID: "mixed", phrases: phrases, hasAudio: true, seek: { _ in })
        let heading: NSTextField = try find("meeting-transcript-heading", in: reader)
        XCTAssertEqual(heading.stringValue, "Transcript timeline")
        XCTAssertGreaterThan(reader.layer?.cornerRadius ?? 0, 0)
        XCTAssertGreaterThan(reader.edgeInsets.left, 0)
        XCTAssertTrue(reader.kindButtons.values.allSatisfy { $0.state == .on })
        let caption: NSTextField = try find("transcript-kind-action-s1", in: reader)
        XCTAssertEqual(caption.stringValue, "ACTION")
        reader.kindButtons[.transcript]?.performClick(nil)
        XCTAssertEqual(reader.state.results.map(\.id), ["action-s1"])
        reader.hourPicker.selectItem(at: 4)
        reader.changeHour()
        XCTAssertEqual(reader.state.windowStart, 14400)
        XCTAssertEqual(reader.state.pageRows.first?.id, "decision-s2")
        reader.search.stringValue = "budget"
        reader.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: reader.search))
        XCTAssertEqual(reader.state.results.count, 2)
        reader.viewPicker.selectItem(withTitle: "Clear text")
        reader.changeView()
        XCTAssertEqual(reader.state.results.count, 2)
        reader.previousPage.performClick(nil)
        reader.kindButtons[.transcript]?.performClick(nil)
        XCTAssertEqual(reader.state.results.count, 3)
        reader.search.stringValue = "pending"
        reader.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: reader.search))
        let context: NSTextField = try find("transcript-context-action-s1", in: reader)
        XCTAssertNotNil(context.attributedStringValue.attribute(.underlineStyle, at: 12, effectiveRange: nil))
        XCTAssertEqual(reader.state.selectedMatch?.field, .context)
    }

    @MainActor
    func testSpeakerEditorApplyCancelAuditionAndErrors() throws {
        let reader = TranscriptReaderView(controls: GraphiteFocusControls())
        let phrase = TranscriptReaderPhrase(id: "source", seconds: 1, speaker: "Guest", text: "Words", seekSeconds: 1)
        var applied: String?
        var auditioned: String?
        reader.configureCorrection(enabled: true, outdated: false, reviewRequired: false,
            correct: { _, name, completion in applied = name; completion(.failure(MeetingManagementError.unavailable)) }, reprocess: {})
        reader.load(meetingID: "one", phrases: [phrase], hasAudio: true, seek: { auditioned = $0.id })
        let button: NSButton = try find("transcript-correct-source", in: reader)
        button.performClick(nil)
        XCTAssertFalse(reader.speakerEditor.isHidden)
        reader.speakerEditor.audition.performClick(nil)
        XCTAssertEqual(auditioned, "source")
        reader.speakerEditor.name.stringValue = "Alice"
        reader.speakerEditor.apply.performClick(nil)
        XCTAssertEqual(applied, "Alice")
        XCTAssertFalse(reader.speakerEditor.isHidden)
        XCTAssertFalse(reader.speakerEditor.feedback.stringValue.isEmpty)
        XCTAssertEqual(reader.speakerEditor.name.stringValue, "Alice")
        reader.speakerEditor.cancel.performClick(nil)
        XCTAssertTrue(reader.speakerEditor.isHidden)
        reader.configureCorrection(enabled: false, outdated: true, reviewRequired: true, correct: { _, _, _ in }, reprocess: {})
        XCTAssertFalse(reader.analysisNotice.isHidden)
        XCTAssertTrue(reader.analysisNotice.stringValue.contains("review"))
        XCTAssertFalse(button.isEnabled)
    }

    @MainActor
    private func find<T: NSView>(_ id: String, in view: NSView) throws -> T {
        if view.accessibilityIdentifier() == id, let result = view as? T { return result }
        for child in view.subviews { if let found: T = try? find(id, in: child) { return found } }
        throw NSError(domain: "TranscriptReaderTests", code: 1)
    }
}
