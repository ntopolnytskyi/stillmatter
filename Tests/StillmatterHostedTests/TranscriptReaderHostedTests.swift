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
        reader.viewPicker.selectItem(withTitle: "Text only")
        reader.changeView()
        XCTAssertEqual(reader.state.view, .clearText)
        XCTAssertThrowsError(try find("transcript-time-one", in: reader) as NSButton)
        reader.viewPicker.selectItem(withTitle: "Grouped by speaker")
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
        reader.viewPicker.selectItem(withTitle: "Grouped by speaker")
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
        reader.viewPicker.selectItem(withTitle: "Text only")
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
    func testPendingCorrectionKeepsEditorAndCallbackBoundToTheOriginalSource() throws {
        let reader = TranscriptReaderView(controls: GraphiteFocusControls())
        let phrases = [TranscriptReaderPhrase(id: "first", seconds: 1, speaker: "Guest", text: "One", seekSeconds: nil),
            TranscriptReaderPhrase(id: "second", seconds: 2, speaker: "Guest", text: "Two", seekSeconds: nil)]
        var finish: ((Result<Void, Error>) -> Void)?
        var originalUsed = false
        reader.configureCorrection(enabled: true, outdated: false, reviewRequired: false,
            correct: { _, _, completion in originalUsed = true; finish = completion }, reprocess: {})
        reader.load(meetingID: "one", phrases: phrases, hasAudio: false, seek: { _ in })
        let first: NSButton = try find("transcript-correct-first", in: reader)
        let second: NSButton = try find("transcript-correct-second", in: reader)
        first.performClick(nil)
        reader.configureCorrection(enabled: true, outdated: false, reviewRequired: false,
            correct: { _, _, _ in XCTFail("An open editor must retain its original source operation") }, reprocess: {})
        reader.speakerEditor.name.stringValue = "Alice"
        reader.speakerEditor.apply.performClick(nil)
        XCTAssertTrue(originalUsed)
        XCTAssertFalse(second.isEnabled)
        XCTAssertFalse(reader.speakerEditor.name.isEnabled)
        reader.configureCorrection(enabled: true, outdated: false, reviewRequired: false, correct: { _, _, _ in }, reprocess: {})
        XCTAssertFalse(second.isEnabled)
        finish?(.failure(MeetingManagementError.unavailable))
        XCTAssertTrue(second.isEnabled)
        XCTAssertTrue(reader.speakerEditor.name.isEnabled)
        XCTAssertEqual(reader.speakerEditor.feedback.meaning, .destructive)
        XCTAssertEqual(reader.speakerEditor.name.stringValue, "Alice")
    }

    @MainActor
    func testSpeakerFiltersFollowRenamedSourcesWithoutFollowingReusedIDs() throws {
        let reader = TranscriptReaderView(controls: GraphiteFocusControls())
        func phrases(_ name: String, seconds: Double = 1) -> [TranscriptReaderPhrase] {
            [.init(id: "one", seconds: seconds, speaker: name, text: "One", seekSeconds: nil),
             .init(id: "two", seconds: 2, speaker: "Guest", text: "Two", seekSeconds: nil),
             .init(id: "three", seconds: 3, speaker: "Me", text: "Three", seekSeconds: nil)]
        }
        reader.load(meetingID: "one", phrases: phrases("Guest"), hasAudio: false, seek: { _ in })
        for name in ["Guest", "Me"] {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: ""); item.representedObject = name
            reader.selectSpeaker(item)
        }
        reader.load(meetingID: "one", phrases: phrases("Alice"), hasAudio: false, seek: { _ in })
        XCTAssertEqual(reader.state.speakers, ["Guest", "Me", "Alice"])
        XCTAssertEqual(reader.state.results.map(\.id), ["one", "two", "three"])
        reader.load(meetingID: "one", phrases: phrases("Olena"), hasAudio: false, seek: { _ in })
        XCTAssertEqual(reader.state.speakers, ["Guest", "Me", "Olena"])
        reader.load(meetingID: "one", phrases: phrases("Olena"), hasAudio: false, seek: { _ in })
        XCTAssertEqual(reader.state.speakers, ["Guest", "Me", "Olena"])
        reader.load(meetingID: "one", phrases: phrases("Unrelated", seconds: 20), hasAudio: false, seek: { _ in })
        XCTAssertEqual(reader.state.speakers, ["Guest", "Me"])
        XCTAssertFalse(reader.state.results.contains { $0.id == "one" })
        reader.load(meetingID: "other", phrases: phrases("Other"), hasAudio: false, seek: { _ in })
        XCTAssertTrue(reader.state.speakers.isEmpty)
        XCTAssertEqual(reader.state.results.count, 3)
    }

    @MainActor
    func testOnlyItemsScrollWhileControlsRemainFixedAndReaderFitsAvailableHeight() throws {
        let reader = TranscriptReaderView(controls: GraphiteFocusControls())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = reader
        reader.load(meetingID: "long", phrases: (0..<80).map {
            TranscriptReaderPhrase(id: "s\($0)", seconds: Double($0 * 8), speaker: "Guest",
                                   text: "A paragraph of the conversation to read while the controls stay visible.", seekSeconds: Double($0 * 8))
        }, hasAudio: true, seek: { _ in })
        window.contentView?.layoutSubtreeIfNeeded()
        let headingBefore = reader.heading.convert(reader.heading.bounds, to: nil)
        let filtersBefore = try XCTUnwrap(reader.kindButtons[.transcript]).convert(reader.kindButtons[.transcript]!.bounds, to: nil)
        let document = try XCTUnwrap(reader.itemsScroll.documentView)
        XCTAssertGreaterThan(document.bounds.height, reader.itemsScroll.contentView.bounds.height)
        XCTAssertGreaterThan(reader.itemsScroll.bounds.height, 100)
        XCTAssertFalse(reader.search.isDescendant(of: document))
        XCTAssertFalse(reader.viewPicker.isDescendant(of: document))
        XCTAssertFalse(reader.speakersButton.isDescendant(of: document))
        reader.itemsScroll.contentView.scroll(to: NSPoint(x: 0, y: 200))
        reader.itemsScroll.reflectScrolledClipView(reader.itemsScroll.contentView)
        XCTAssertEqual(reader.itemsScroll.contentView.bounds.origin.y, 200, accuracy: 1)
        XCTAssertEqual(reader.heading.convert(reader.heading.bounds, to: nil), headingBefore)
        XCTAssertEqual(reader.kindButtons[.transcript]!.convert(reader.kindButtons[.transcript]!.bounds, to: nil), filtersBefore)
        let phrases = reader.state.phrases
        reader.load(meetingID: "another", phrases: phrases, hasAudio: true, seek: { _ in })
        XCTAssertEqual(reader.itemsScroll.contentView.bounds.origin.y, 0, accuracy: 1)
        window.setContentSize(NSSize(width: 1100, height: 500))
        reader.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(reader.itemsScroll.bounds.height, 0)
        XCTAssertLessThanOrEqual(reader.itemsScroll.frame.maxY, reader.bounds.height)
    }

    @MainActor
    func testLinkedCreationAndJumpMenusHaveKeyboardControlsAndUnavailableStates() throws {
        let reader = TranscriptReaderView(controls: GraphiteFocusControls())
        let phrase = TranscriptReaderPhrase(id: "late", seconds: 7200, speaker: "Guest", text: "Send report", seekSeconds: 7202)
        var created: [String] = []
        var sought: TranscriptReaderPhrase?
        reader.configureLinkedItems(enabled: true) { phrase, kind in created.append(phrase.sourceSegmentID + ":" + kind.rawValue) }
        reader.load(meetingID: "one", phrases: [phrase], hasAudio: true, seek: { sought = $0 })
        reader.state.reveal(id: "late"); reader.moveNextMatch()
        let text: NSTextField = try find("transcript-text-late", in: reader)
        XCTAssertEqual(text.menu?.items.map(\.title), ["Copy text", "Copy with timestamp", "Copy speaker", "Add Action Item…", "Add Decision…", "Add note…", "Jump to moment"])
        let actions: NSPopUpButton = try find("transcript-actions-late", in: reader)
        XCTAssertEqual(actions.menu?.items.dropFirst().map(\.title), text.menu?.items.map(\.title))
        let menu = try XCTUnwrap(text.menu)
        for item in menu.items[3...5] { reader.createLinkedItem(item) }
        XCTAssertEqual(created, ["late:Action Item", "late:Decision", "late:note"])
        reader.jumpToMoment(menu.items[6])
        XCTAssertEqual(reader.state.selectedID, "late"); XCTAssertEqual(sought?.seekSeconds, 7202)
        reader.configureLinkedItems(enabled: false) { _, _ in XCTFail("Disabled creation") }
        let disabled: NSTextField = try find("transcript-text-late", in: reader)
        XCTAssertTrue(disabled.menu!.items[3...5].allSatisfy { !$0.isEnabled })
        reader.createLinkedItem(menu.items[3])
        reader.load(meetingID: "one", phrases: [phrase], hasAudio: false, seek: { _ in XCTFail("Missing audio") })
        let missing: NSTextField = try find("transcript-text-late", in: reader)
        XCTAssertFalse(try XCTUnwrap(missing.menu?.items.last).isEnabled)
        reader.jumpToMoment(menu.items[6])
        reader.load(meetingID: "one", phrases: [], hasAudio: false, seek: { _ in XCTFail("Missing source") })
        reader.createLinkedItem(menu.items[3])
        reader.jumpToMoment(menu.items[6])
    }

    @MainActor
    private func find<T: NSView>(_ id: String, in view: NSView) throws -> T {
        if view.accessibilityIdentifier() == id, let result = view as? T { return result }
        for child in view.subviews { if let found: T = try? find(id, in: child) { return found } }
        throw NSError(domain: "TranscriptReaderTests", code: 1)
    }
}
