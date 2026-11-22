import AppKit
import XCTest
import StillmatterCore
import StillmatterPresentation
@testable import StillmatterHostedTestHost

final class TodayMeetingNavigationHostedTests: XCTestCase {
    @MainActor
    func testCancellingDirtySelectionKeepsDraftAndDoesNotOpenReminderTarget() async throws {
        let source = ReviewNavigationSource()
        let model = MeetingReadModel(workspaceID: "A", sourceFactory: { source })
        var prompts = 0, opens = 0
        let view = MeetingManagementView(readModelProvider: { model }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in },
            presentConfirmationAlert: { _ in prompts += 1; return .alertThirdButtonReturn })
        view.setOnOpenSelection { opens += 1 }
        view.refresh(isVisible: true)
        let loaded = expectation(for: NSPredicate { _, _ in view.displayedDetail?.row.id == "other" }, evaluatedWith: view)
        await fulfillment(of: [loaded], timeout: 5)
        view.meetingsModel.detail.beginEditingNotes()
        view.meetingsModel.detail.updateNotesDraft("Unsaved user notes")
        view.focusActionItems(source.target.meetingRelativePath) { XCTFail("Cancel is not an unavailable target") }
        let cancelled = expectation(for: NSPredicate { _, _ in prompts == 1 }, evaluatedWith: view)
        await fulfillment(of: [cancelled], timeout: 5)
        XCTAssertEqual(view.selectedID, "other")
        XCTAssertEqual(view.meetingsModel.detail.notesDraft?.editedText, "Unsaved user notes")
        XCTAssertEqual(opens, 0)
        // A subsequent explicit route remains usable after cancellation.
        view.meetingsModel.detail.discardDrafts()
        view.focusActionItems(source.target.meetingRelativePath) { XCTFail("Valid target must open") }
        let selected = expectation(for: NSPredicate { _, _ in
            view.displayedDetail?.row.id == "target" && view.meetingsModel.detail.page == .actionItems
        }, evaluatedWith: view)
        await fulfillment(of: [selected], timeout: 5)
        XCTAssertGreaterThan(opens, 0)
        view.refresh(isVisible: false)
        model.stop()
    }

    @MainActor
    func testRepeatedReminderOpensCorrectMeetingAndActionItemsEvenWithUnchangedBrowserSnapshot() async throws {
        let source = ReviewNavigationSource()
        let model = MeetingReadModel(workspaceID: "A", sourceFactory: { source })
        let view = makeView(model)
        view.refresh(isVisible: true)
        let loaded = expectation(for: NSPredicate { _, _ in view.meetingsModel.loadState == .loaded }, evaluatedWith: view)
        await fulfillment(of: [loaded], timeout: 5)
        for _ in 0..<2 {
            view.focusActionItems(source.target.meetingRelativePath) { XCTFail("Valid target must open") }
            let selected = expectation(for: NSPredicate { _, _ in
                view.displayedDetail?.row.id == "target" && view.meetingsModel.detail.page == .actionItems
                    && view.pageSelector.selectedSegment == 1
            }, evaluatedWith: view)
            await fulfillment(of: [selected], timeout: 5)
            view.refresh(isVisible: false)
            view.refresh(isVisible: true)
        }
        view.refresh(isVisible: false)
        model.stop()
    }

    @MainActor
    func testDeletionDuringBrowserReadReportsUnavailableInsteadOfOpeningAnotherMeeting() async throws {
        let started = expectation(description: "browser read started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let source = ReviewNavigationSource()
        source.blockFirstRead = { started.fulfill(); gate.wait() }
        let model = MeetingReadModel(workspaceID: "A", sourceFactory: { source })
        let view = makeView(model)
        var opens = 0
        view.setOnOpenSelection { opens += 1 }
        view.refresh(isVisible: true)
        await fulfillment(of: [started], timeout: 5)
        let unavailable = expectation(description: "deleted target unavailable")
        view.focusActionItems(source.target.meetingRelativePath) { unavailable.fulfill() }
        source.deleteTarget()
        model.invalidate(.workspaceFilesChanged(paths: [source.target.meetingRelativePath]))
        gate.signal()
        await fulfillment(of: [unavailable], timeout: 5)
        XCTAssertEqual(opens, 0)
        view.refresh(isVisible: false)
        model.stop()
    }

    @MainActor
    func testWorkspaceChangeCancelsReviewNavigationWhileReadIsInFlight() async throws {
        let started = expectation(description: "old workspace reading")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let oldSource = ReviewNavigationSource()
        oldSource.blockFirstRead = { started.fulfill(); gate.wait() }
        let old = MeetingReadModel(workspaceID: "A", sourceFactory: { oldSource })
        let newSource = ReviewNavigationSource()
        newSource.deleteTarget()
        let new = MeetingReadModel(workspaceID: "B", sourceFactory: { newSource })
        var current = old
        let view = MeetingManagementView(readModelProvider: { current }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        var opens = 0, failures = 0
        view.setOnOpenSelection { opens += 1 }
        view.refresh(isVisible: true)
        await fulfillment(of: [started], timeout: 5)
        view.focusActionItems(oldSource.target.meetingRelativePath) { failures += 1 }
        view.refresh(isVisible: false)
        current = new
        view.refresh(isVisible: true)
        gate.signal()
        let loaded = expectation(for: NSPredicate { _, _ in
            view.meetingsModel.snapshot?.workspaceID == "B" && view.meetingsModel.loadState == .loaded
        }, evaluatedWith: view)
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(opens, 0)
        XCTAssertEqual(failures, 0)
        view.refresh(isVisible: false)
        old.stop(); new.stop()
    }

    @MainActor
    func testUnavailableBrowserAndFailedDetailEndReviewNavigation() async throws {
        let missing = MeetingManagementView(readModelProvider: { nil }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
        missing.refresh(isVisible: true)
        var failures = 0
        missing.focusActionItems("Meetings/target/meeting.md") { failures += 1 }
        XCTAssertEqual(failures, 1)
        missing.refresh(isVisible: false)

        let source = ReviewNavigationSource()
        source.failDetail = true
        let model = MeetingReadModel(workspaceID: "A", sourceFactory: { source })
        let view = makeView(model)
        view.refresh(isVisible: true)
        let failed = expectation(description: "detail unavailable")
        view.focusActionItems(source.target.meetingRelativePath) { failed.fulfill() }
        await fulfillment(of: [failed], timeout: 5)
        view.refresh(isVisible: false)
        model.stop()
    }

    @MainActor
    func testReplacingSelectionDuringNativeAlertRejectsItsOldDiscardAndPromptsReplacement() async throws {
        let source = ReviewNavigationSource()
        let read = MeetingReadModel(workspaceID: "A", sourceFactory: { source })
        var view: MeetingManagementView!
        var prompts = 0
        view = MeetingManagementView(readModelProvider: { read }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in },
            presentConfirmationAlert: { alert in
                XCTAssertEqual(alert.messageText, "Save Meeting edits before changing selection?")
                prompts += 1
                if prompts == 1 {
                    _ = view.meetingsModel.select(meetingID: "target", selectedIDs: ["other", "target"])
                    return .alertSecondButtonReturn // Discard belongs to the replaced request.
                }
                XCTAssertEqual(view.selectedID, "other")
                XCTAssertEqual(view.meetingsModel.detail.notesDraft?.editedText, "Keep this draft")
                return .alertThirdButtonReturn
            })
        defer { view.refresh(isVisible: false); read.stop() }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.selectedID == "other" && view.displayedDetail != nil }, evaluatedWith: view)], timeout: 5)
        view.meetingsModel.detail.updateNotesDraft("Keep this draft")
        _ = view.meetingsModel.select(meetingID: "target", selectedIDs: ["target"])
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in prompts == 2 && !view.meetingsModel.pendingSelectionDecision }, evaluatedWith: view)], timeout: 5)
        XCTAssertEqual(view.selectedID, "other")
        XCTAssertTrue(view.meetingsModel.detail.hasDirtyDrafts)
    }

    @MainActor
    func testSettingsRequestExistsBeforeNativeAlertAndOldDiscardCannotApproveReplacement() async throws {
        let source = ReviewNavigationSource()
        let read = MeetingReadModel(workspaceID: "A", sourceFactory: { source })
        var view: MeetingManagementView!
        var prompts = 0
        var first: [Bool] = [], replacement: [Bool] = []
        view = MeetingManagementView(readModelProvider: { read }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in },
            presentConfirmationAlert: { _ in
                prompts += 1
                XCTAssertEqual(view.meetingsModel.draftNavigation.context, .workspacePreparation)
                if prompts == 1 {
                    view.prepareWorkspaceChange { replacement.append($0) }
                    return .alertSecondButtonReturn
                }
                XCTAssertEqual(view.meetingsModel.detail.notesDraft?.editedText, "Keep this draft")
                return .alertThirdButtonReturn
            })
        defer { view.refresh(isVisible: false); read.stop() }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail != nil }, evaluatedWith: view)], timeout: 5)
        view.meetingsModel.detail.updateNotesDraft("Keep this draft")
        view.prepareWorkspaceChange { first.append($0) }
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in prompts == 2 && replacement == [false] }, evaluatedWith: view)], timeout: 5)
        XCTAssertEqual(first, [false])
        XCTAssertEqual(replacement, [false])
        XCTAssertTrue(view.meetingsModel.detail.hasDirtyDrafts)
    }

    @MainActor
    func testStaleNativeRecoveryAnswerCannotReloadOrResolveReplacementSelection() async throws {
        let source = ReviewNavigationSource()
        let read = MeetingReadModel(workspaceID: "A", sourceFactory: { source })
        var view: MeetingManagementView!
        var decisions = 0, recoveries = 0
        view = MeetingManagementView(readModelProvider: { read }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in },
            presentConfirmationAlert: { alert in
                if alert.messageText == "Could not save Meeting edits" {
                    recoveries += 1
                    _ = view.meetingsModel.select(meetingID: "target", selectedIDs: ["other", "target"])
                    return .alertFirstButtonReturn // Reload belongs to the replaced failure.
                }
                decisions += 1
                if decisions == 1 { return .alertFirstButtonReturn }
                XCTAssertEqual(view.selectedID, "other")
                XCTAssertEqual(view.meetingsModel.detail.notesDraft?.editedText, "Retain failed save")
                return .alertThirdButtonReturn
            })
        defer { view.refresh(isVisible: false); read.stop() }
        view.refresh(isVisible: true)
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in view.displayedDetail != nil }, evaluatedWith: view)], timeout: 5)
        view.meetingsModel.detail.updateNotesDraft("Retain failed save")
        _ = view.meetingsModel.select(meetingID: "target", selectedIDs: ["target"])
        await fulfillment(of: [expectation(for: NSPredicate { _, _ in decisions == 2 && recoveries == 1 && !view.meetingsModel.pendingSelectionDecision }, evaluatedWith: view)], timeout: 5)
        XCTAssertEqual(view.selectedID, "other")
        XCTAssertEqual(view.meetingsModel.detail.notesDraft?.editedText, "Retain failed save")
        XCTAssertTrue(view.meetingsModel.detail.hasDirtyDrafts)
    }

    @MainActor
    private func makeView(_ model: MeetingReadModel) -> MeetingManagementView {
        MeetingManagementView(readModelProvider: { model }, mutationExecutorProvider: { nil },
            playbackTransportProvider: { nil }, openRecording: {}, openWorkspaceFile: { _ in })
    }
}

private final class ReviewNavigationSource: MeetingReadSource {
    let target = MeetingBrowserRow(id: "target", title: "Planning", startedAt: nil,
        meetingRelativePath: "Meetings/target/meeting.md", captureState: .stopped)
    private let other = MeetingBrowserRow(id: "other", title: "Planning", startedAt: nil,
        meetingRelativePath: "Meetings/other/meeting.md", captureState: .stopped)
    private let lock = NSLock()
    private var deleted = false
    var blockFirstRead: (() -> Void)?
    var failDetail = false

    func deleteTarget() { lock.lock(); deleted = true; lock.unlock() }
    func browserProjection() throws -> [MeetingBrowserRow] {
        let block = blockFirstRead
        blockFirstRead = nil
        block?()
        lock.lock(); defer { lock.unlock() }
        return deleted ? [other] : [other, target]
    }
    func browserRows(filters: MeetingBrowserFilters, from projection: [MeetingBrowserRow]) throws -> MeetingBrowserReadResult {
        MeetingBrowserReadResult(visibleRows: projection, availableRows: projection)
    }
    func detail(for reference: MeetingReference, browserRow: MeetingBrowserRow) throws -> MeetingBrowserDetail {
        if failDetail { throw MeetingManagementError.unavailable }
        return MeetingBrowserDetail(row: browserRow, doorwayText: "")
    }
}
