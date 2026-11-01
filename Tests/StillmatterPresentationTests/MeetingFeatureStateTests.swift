import XCTest
import Combine
import StillmatterCore
@testable import StillmatterPresentation

final class MeetingFeatureStateTests: XCTestCase {
    func testQueueFiltersPreserveRecordedAttentionAndReadySemantics() {
        let rows = [
            browserRow("recording", state: .live),
            browserRow("processing", state: .processing),
            browserRow("failed", state: .needsAttention, failed: true),
            browserRow("review", state: .ready, needsReview: true),
            browserRow("ready", state: .ready)
        ]

        XCTAssertEqual(MeetingQueueFilter.recorded.filter(rows).map(\.id), rows.map(\.id))
        XCTAssertEqual(Set(MeetingQueueFilter.attention.filter(rows).map(\.id)), ["failed", "review"])
        XCTAssertEqual(MeetingQueueFilter.ready.filter(rows).map(\.id), ["ready"])
    }

    func testDirtyDraftKeepsItsBaseVersionAcrossRefreshUntilExplicitReload() {
        let originalVersion = version("original")
        let externalVersion = version("external")
        var draft = MeetingTextDraft(originalText: "Original", baseVersion: originalVersion)
        draft.beginEditing()
        draft.update("My unsaved text")
        draft.refresh(originalText: "External edit", baseVersion: externalVersion)

        XCTAssertEqual(draft.originalText, "Original")
        XCTAssertEqual(draft.editedText, "My unsaved text")
        XCTAssertEqual(draft.baseVersion, originalVersion)
        XCTAssertTrue(draft.isDirty)

        draft.reload(originalText: "External edit", baseVersion: externalVersion)
        XCTAssertEqual(draft.originalText, "External edit")
        XCTAssertEqual(draft.editedText, "External edit")
        XCTAssertEqual(draft.baseVersion, externalVersion)
        XCTAssertFalse(draft.isDirty)
    }

    func testUneditedDraftRefreshesAndBeginEditCapturesCurrentVersion() {
        var draft = MeetingTextDraft(originalText: "Old", baseVersion: version("old"))
        draft.refresh(originalText: "Fresh", baseVersion: version("fresh"))
        draft.beginEditing()
        draft.update("Fresh plus notes")

        XCTAssertEqual(draft.originalText, "Fresh")
        XCTAssertEqual(draft.baseVersion, version("fresh"))
        XCTAssertTrue(draft.isDirty)
    }

    @MainActor
    func testSelectionChangesAtoBtoARejectStaleDetailAndNeverShowAUnderB() async {
        let rowA = browserRow("a", state: .ready)
        let rowB = browserRow("b", state: .ready)
        let source = FeatureReadSource(rows: [rowA, rowB], details: [
            "a": detail(rowA, notes: "A only", version: "a"),
            "b": detail(rowB, notes: "B only", version: "b")
        ])
        let executor = ControlledFeatureReadExecutor()
        let readModel = makeReadModel("workspace-a", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel })
        defer { model.stop(); readModel.stop() }

        model.activate()
        await drain(executor)
        XCTAssertEqual(model.selectedMeetingID, "a")
        XCTAssertEqual(model.detail.detail?.humanNotes, "A only")
        XCTAssertEqual(model.select(meetingID: "a", selectedIDs: ["a", "b"]), .applied)
        XCTAssertEqual(model.selectedMeetingIDs, ["a", "b"], "Multi-selection identity is preserved in feature state")

        XCTAssertEqual(model.select(meetingID: "b", selectedIDs: ["b"]), .applied)
        XCTAssertNil(model.detail.detail, "B must not temporarily display A's detail")
        XCTAssertEqual(model.select(meetingID: "a", selectedIDs: ["a"]), .applied)
        await drain(executor)

        XCTAssertEqual(model.selectedMeetingID, "a")
        XCTAssertEqual(model.detail.detail?.row.id, "a")
        XCTAssertEqual(model.detail.detail?.humanNotes, "A only")
        XCTAssertEqual(source.detailReadCount, 2, "Canceled B and earlier A detail requests must not reach the source")
    }

    @MainActor
    func testOldWorkspaceBrowserCompletionCannotReplaceNewWorkspaceSnapshot() async {
        let rowA = browserRow("a", state: .ready)
        let rowB = browserRow("b", state: .ready)
        let executorA = ControlledFeatureReadExecutor()
        let executorB = ControlledFeatureReadExecutor()
        let readModelA = makeReadModel("workspace-a", source: FeatureReadSource(rows: [rowA]), executor: executorA)
        let readModelB = makeReadModel("workspace-b", source: FeatureReadSource(rows: [rowB]), executor: executorB)
        var selectedReadModel = readModelA
        let model = MeetingsModel(readModelProvider: { selectedReadModel })
        defer { model.stop(); readModelA.stop(); readModelB.stop() }

        model.activate()
        executorA.runNext() // Source creation.
        selectedReadModel = readModelB
        model.refresh() // Replaces the source while the old browser request is pending.
        await drain(executorB)
        await drain(executorA)
        await drain(executorB)

        XCTAssertEqual(model.snapshot?.workspaceID, "workspace-b")
        XCTAssertEqual(model.visibleRows.map(\.id), ["b"])
    }

    @MainActor
    func testReorderedAndDeletedRowsAcrossEmptyWorkspaceRetainDetailIdentity() async {
        let first = browserRow("first", state: .ready)
        let same = browserRow("same", state: .ready)
        let deleted = browserRow("deleted", state: .ready)
        let a = ControlledFeatureReadExecutor()
        let empty = ControlledFeatureReadExecutor()
        let b = ControlledFeatureReadExecutor()
        let readA = makeReadModel("A", source: FeatureReadSource(rows: [first, same, deleted], details: [
            "first": detail(first, notes: "A first", version: "a"), "same": detail(same, notes: "A same", version: "a"),
            "deleted": detail(deleted, notes: "A deleted", version: "a")
        ]), executor: a)
        let readEmpty = makeReadModel("empty", source: FeatureReadSource(rows: []), executor: empty)
        let readB = makeReadModel("B", source: FeatureReadSource(rows: [same, first], details: [
            "same": detail(same, notes: "B same", version: "b"), "first": detail(first, notes: "B first", version: "b")
        ]), executor: b)
        var selected = readA
        let model = MeetingsModel(readModelProvider: { selected })
        defer { model.stop(); readA.stop(); readEmpty.stop(); readB.stop() }
        model.activate()
        await drain(a)
        XCTAssertEqual(model.select(meetingID: "same", selectedIDs: ["same"]), .applied)
        await drain(a)
        XCTAssertEqual(model.detail.detail?.humanNotes, "A same")
        selected = readEmpty
        model.refresh()
        XCTAssertNil(model.detail.detail)
        await drain(empty)
        XCTAssertEqual(model.visibleRows.count, 0)
        XCTAssertNil(model.selectedMeetingID)
        selected = readB
        model.refresh()
        await drain(b)
        XCTAssertEqual(model.snapshot?.workspaceID, "B")
        XCTAssertEqual(model.visibleRows.map(\.id), ["same", "first"])
        XCTAssertEqual(model.selectedMeetingID, "same")
        XCTAssertEqual(model.detail.detail?.humanNotes, "B same")
        XCTAssertEqual(model.detail.notesDraft?.originalText, "B same")
    }

    @MainActor
    func testDirtyWorkspaceSwitchRequiresDecisionAndCancelKeepsCurrentWorkspace() async {
        let rowA = browserRow("a", state: .ready)
        let rowB = browserRow("b", state: .ready)
        let executorA = ControlledFeatureReadExecutor()
        let executorB = ControlledFeatureReadExecutor()
        let executorC = ControlledFeatureReadExecutor()
        let readModelA = makeReadModel("workspace-a", source: FeatureReadSource(rows: [rowA], details: ["a": detail(rowA, notes: "A", version: "a")]), executor: executorA)
        let readModelB = makeReadModel("workspace-b", source: FeatureReadSource(rows: [rowB]), executor: executorB)
        let readModelC = makeReadModel("workspace-c", source: FeatureReadSource(rows: [rowB]), executor: executorC)
        var selectedReadModel = readModelA
        let model = MeetingsModel(readModelProvider: { selectedReadModel })
        defer { model.stop(); readModelA.stop(); readModelB.stop(); readModelC.stop() }
        model.activate()
        await drain(executorA)
        model.detail.updateNotesDraft("Keep this edit")

        selectedReadModel = readModelB
        model.refresh()
        XCTAssertTrue(model.pendingWorkspaceDecision)
        XCTAssertEqual(model.snapshot?.workspaceID, "workspace-a")
        model.resolvePendingWorkspaceChange(.cancel)
        XCTAssertFalse(model.pendingWorkspaceDecision)
        XCTAssertEqual(model.detail.notesDraft?.editedText, "Keep this edit")

        selectedReadModel = readModelC
        model.refresh()
        XCTAssertTrue(model.pendingWorkspaceDecision)
        model.resolvePendingWorkspaceChange(.discard)
        await drain(executorC)
        XCTAssertEqual(model.snapshot?.workspaceID, "workspace-c")
        XCTAssertEqual(model.selectedMeetingID, "b")
        XCTAssertEqual(model.detail.notesDraft?.editedText, "")
        XCTAssertFalse(model.isDirty)
    }

    @MainActor
    func testLateMutationFromAWithCollidingIdentityCannotPublishIntoB() async {
        let row = browserRow("same", state: .ready)
        let a = ControlledFeatureReadExecutor()
        let b = ControlledFeatureReadExecutor()
        let readA = makeReadModel("A", source: FeatureReadSource(rows: [row], details: ["same": detail(row, notes: "A", version: "a")]), executor: a)
        let readB = makeReadModel("B", source: FeatureReadSource(rows: [row], details: ["same": detail(row, notes: "B", version: "b")]), executor: b)
        let mutationsA = ControlledMutationExecutor()
        let mutationsB = ControlledMutationExecutor()
        var selected = readA
        let model = MeetingsModel(readModelProvider: { selected }, mutationExecutorProvider: { selected === readA ? mutationsA : mutationsB })
        defer { model.stop(); readA.stop(); readB.stop() }
        model.activate()
        await drain(a)
        model.detail.updateNotesDraft("A edit")
        model.detail.saveNotes()
        selected = readB
        // The in-flight A write is durable even if B becomes the active projection.
        model.detail.discardDrafts()
        model.refresh()
        await drain(b)
        XCTAssertEqual(model.snapshot?.workspaceID, "B")
        XCTAssertEqual(model.detail.detail?.humanNotes, "B")
        mutationsA.completeNext(.success(.detail(detail(row, notes: "A edit", version: "a2"))))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(model.detail.detail?.humanNotes, "B")
        XCTAssertEqual(model.detail.selectedMeetingID, "same")
        XCTAssertFalse(model.detail.isMutationInFlight)
        model.detail.remove()
        XCTAssertEqual(mutationsB.mutations.count, 1, "B must use B's executor after A finishes")
        mutationsB.completeNext(.failure(FeatureMutationError.failed))
        await settleMainActor()
        XCTAssertEqual(model.selectedMeetingID, "same")
    }

    @MainActor
    func testLateRemoveFromOldSelectionCannotClearNewWorkspace() async {
        let row = browserRow("same", state: .ready)
        let a = ControlledFeatureReadExecutor()
        let b = ControlledFeatureReadExecutor()
        let readA = makeReadModel("A", source: FeatureReadSource(rows: [row], details: ["same": detail(row, notes: "A", version: "a")]), executor: a)
        let readB = makeReadModel("B", source: FeatureReadSource(rows: [row], details: ["same": detail(row, notes: "B", version: "b")]), executor: b)
        let mutations = ControlledMutationExecutor()
        var selected = readA
        let model = MeetingsModel(readModelProvider: { selected }, mutationExecutorProvider: { mutations })
        defer { model.stop(); readA.stop(); readB.stop() }
        model.activate()
        await drain(a)
        model.remove()
        selected = readB
        model.refresh()
        await drain(b)
        mutations.completeNext(.success(.none))
        await settleMainActor()
        XCTAssertEqual(model.snapshot?.workspaceID, "B")
        XCTAssertEqual(model.selectedMeetingID, "same")
        XCTAssertEqual(model.detail.detail?.humanNotes, "B")
    }

    @MainActor
    func testHiddenFeatureStopsObservationAndReappearanceRefreshesStaleDetail() async {
        let row = browserRow("a", state: .ready)
        let source = FeatureReadSource(rows: [row], details: ["a": detail(row, notes: "Before", version: "before")])
        let executor = ControlledFeatureReadExecutor()
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel })
        defer { model.stop(); readModel.stop() }
        model.activate()
        await drain(executor)
        XCTAssertEqual(model.detail.detail?.humanNotes, "Before")

        model.deactivate()
        source.details["a"] = detail(row, notes: "While hidden", version: "hidden")
        readModel.invalidate(.workspaceFilesChanged(paths: [row.meetingRelativePath]))
        await drain(executor)
        XCTAssertEqual(model.detail.detail?.humanNotes, "Before", "Hidden state receives no late change event")

        model.activate()
        await drain(executor)
        XCTAssertEqual(model.detail.detail?.humanNotes, "While hidden")
    }

    @MainActor
    func testExternalMeetingTitleAndDetailRefreshTogetherWithoutDiscardingDirtyNotes() async {
        let original = browserRow("a", state: .ready)
        let source = FeatureReadSource(rows: [original], details: ["a": detail(original, notes: "Before", version: "old")])
        let executor = ControlledFeatureReadExecutor()
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel })
        defer { model.stop(); readModel.stop() }
        model.activate()
        await drain(executor)
        model.detail.updateNotesDraft("Unsaved note")

        let edited = MeetingBrowserRow(id: "a", title: "Externally edited", startedAt: nil,
            meetingRelativePath: original.meetingRelativePath, captureState: .stopped, processingState: .ready)
        source.rows = [edited]
        source.details.removeValue(forKey: "a") // Source derives the detail row from the current browser projection.
        readModel.invalidate(.workspaceFilesChanged(paths: [original.meetingRelativePath]))
        executor.runNext() // Invalidate the cached projection.
        executor.runLast() // The detail read wins the race against the pending browser read.
        await settleMainActor()
        await drain(executor)

        XCTAssertEqual(model.snapshot?.visibleRows.first?.title, "Externally edited")
        XCTAssertEqual(model.detail.detail?.row.title, "Externally edited",
                       "The selected detail must use the new browser row, not the pre-invalidation row")
        XCTAssertEqual(model.detail.notesDraft?.editedText, "Unsaved note")
        XCTAssertTrue(model.detail.notesDraft?.isDirty == true)
    }

    @MainActor
    func testIdenticalBrowserRefreshDoesNotRepublishTableSnapshot() async {
        let executor = ControlledFeatureReadExecutor()
        let readModel = makeReadModel("workspace", source: FeatureReadSource(rows: [browserRow("a", state: .ready)]), executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel })
        defer { model.stop(); readModel.stop() }
        var snapshotPublications = 0
        let token = model.$snapshot.sink { if $0 != nil { snapshotPublications += 1 } }
        defer { token.cancel() }

        model.activate()
        await drain(executor)
        let afterFirstRead = snapshotPublications
        XCTAssertEqual(afterFirstRead, 1)
        model.refresh()
        await drain(executor)
        XCTAssertEqual(snapshotPublications, afterFirstRead, "Equal cached snapshots do not rebuild the table")
    }

    @MainActor
    func testQueueSwitchPublishesBrowserProjectionForTableReload() async {
        let executor = ControlledFeatureReadExecutor()
        let source = FeatureReadSource(rows: [
            browserRow("attention", state: .needsAttention, failed: true),
            browserRow("ready", state: .ready)
        ])
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel })
        defer { model.stop(); readModel.stop() }
        var publishedRows: [[String]] = []
        let token = model.$snapshot.sink { snapshot in
            if let snapshot { publishedRows.append(model.queueFilter.filter(snapshot.visibleRows).map(\.id)) }
        }
        defer { token.cancel() }

        model.activate()
        await drain(executor)
        XCTAssertEqual(publishedRows, [["attention", "ready"]])

        model.setQueueFilter(.ready)
        XCTAssertEqual(publishedRows.last, ["ready"], "The table must be notified when its data source shrinks")
        model.setQueueFilter(.attention)
        XCTAssertEqual(publishedRows.last, ["attention"])
        model.setQueueFilter(.recorded)
        XCTAssertEqual(publishedRows.last, ["attention", "ready"], "The table must be notified when rows return")
        XCTAssertEqual(publishedRows.count, 4, "Each changed queue publishes exactly once without a workspace read")
    }

    @MainActor
    func testSynchronousSelectionAlertCancelClearsPendingPublicationBeforeNextKeyboardSelection() async {
        let rowA = browserRow("a", state: .ready)
        let rowB = browserRow("b", state: .ready)
        let source = FeatureReadSource(rows: [rowA, rowB], details: [
            "a": detail(rowA, notes: "A", version: "a"),
            "b": detail(rowB, notes: "B", version: "b")
        ])
        let executor = ControlledFeatureReadExecutor()
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel })
        defer { model.stop(); readModel.stop() }
        model.activate()
        await drain(executor)
        model.detail.updateNotesDraft("unsaved A")

        var alerts = 0
        let observation = model.$pendingSelectionDecision.dropFirst().sink { pending in
            if pending {
                alerts += 1
                model.resolvePendingSelection(.cancel) // NSAlert returns inside Published's synchronous callback.
            }
        }
        defer { observation.cancel() }

        XCTAssertEqual(model.select(meetingID: "b", selectedIDs: ["b"]), .requiresDecision)
        XCTAssertEqual(alerts, 1)
        XCTAssertFalse(model.pendingSelectionDecision, "The outer Published setter must not restore a resolved alert")
        XCTAssertEqual(model.selectedMeetingID, "a")
        XCTAssertEqual(model.detail.notesDraft?.editedText, "unsaved A")
        XCTAssertEqual(model.select(meetingID: "b", selectedIDs: ["b"]), .requiresDecision)
        XCTAssertEqual(alerts, 2, "A new attempt must ask exactly once, not inherit a stale decision")
        XCTAssertFalse(model.pendingSelectionDecision)
        XCTAssertEqual(model.selectedMeetingID, "a")
    }

    @MainActor
    func testCancelDirtyQueueChangeRestoresSourceQueueAndDraft() async {
        let rowA = browserRow("a", state: .ready)
        let source = FeatureReadSource(rows: [rowA], details: ["a": detail(rowA, notes: "A", version: "a")])
        let executor = ControlledFeatureReadExecutor()
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel })
        defer { model.stop(); readModel.stop() }
        model.activate()
        await drain(executor)
        model.detail.updateNotesDraft("local unsaved")
        model.setQueueFilter(.attention)
        XCTAssertTrue(model.pendingSelectionDecision)
        model.resolvePendingSelection(.cancel)
        XCTAssertEqual(model.queueFilter, .recorded)
        XCTAssertEqual(model.visibleRows.map(\.id), ["a"])
        XCTAssertEqual(model.selectedMeetingID, "a")
        XCTAssertEqual(model.detail.notesDraft?.editedText, "local unsaved")
        XCTAssertFalse(model.pendingSelectionDecision)
        await settleMainActor()
        XCTAssertFalse(model.pendingSelectionDecision, "Cancel must not re-prompt after browser updates")
    }

    @MainActor
    func testSaveDiscardAndCancelSelectionFlowAndFailedSavePreservesDraft() async {
        let rowA = browserRow("a", state: .ready)
        let rowB = browserRow("b", state: .ready)
        let source = FeatureReadSource(rows: [rowA, rowB], details: [
            "a": detail(rowA, notes: "A", version: "a"),
            "b": detail(rowB, notes: "B", version: "b")
        ])
        let executor = ControlledFeatureReadExecutor()
        let mutations = ControlledMutationExecutor()
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel }, mutationExecutorProvider: { mutations })
        defer { model.stop(); readModel.stop() }
        model.activate()
        await drain(executor)

        model.detail.updateNotesDraft("unsaved")
        XCTAssertEqual(model.select(meetingID: "b", selectedIDs: ["b"]), .requiresDecision)
        model.resolvePendingSelection(.cancel)
        XCTAssertEqual(model.selectedMeetingID, "a")
        XCTAssertEqual(model.detail.notesDraft?.editedText, "unsaved")

        XCTAssertEqual(model.select(meetingID: "b", selectedIDs: ["b"]), .requiresDecision)
        model.resolvePendingSelection(.save)
        XCTAssertEqual(mutations.mutations.count, 1)
        guard case let .saveNotes(id, text, baseVersion) = mutations.mutations[0] else {
            return XCTFail("Expected versioned notes save")
        }
        XCTAssertEqual(id, "a")
        XCTAssertEqual(text, "unsaved")
        XCTAssertEqual(baseVersion, version("a"))
        mutations.completeNext(.failure(WorkspaceVaultError.conflict(relativePath: "Meetings/a/meeting.md",
                                                                      expected: version("a"), actual: version("external"))))
        await drain(executor)
        await settleMainActor()
        XCTAssertEqual(model.selectedMeetingID, "a", "Failed Save must not navigate")
        XCTAssertEqual(model.detail.notesDraft?.editedText, "unsaved")
        XCTAssertEqual(model.detail.notesDraft?.baseVersion, version("a"))
        XCTAssertTrue(model.pendingSelectionDecision)

        model.resolvePendingSelection(.discard)
        XCTAssertEqual(model.selectedMeetingID, "b")
        XCTAssertNil(model.detail.notesDraft)
        await drain(executor)
    }

    @MainActor
    func testSuccessfulSaveNavigatesOnlyAfterMutationCompletes() async {
        let rowA = browserRow("a", state: .ready)
        let rowB = browserRow("b", state: .ready)
        let source = FeatureReadSource(rows: [rowA, rowB], details: [
            "a": detail(rowA, notes: "A", version: "a"),
            "b": detail(rowB, notes: "B", version: "b")
        ])
        let executor = ControlledFeatureReadExecutor()
        let mutations = ControlledMutationExecutor()
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel }, mutationExecutorProvider: { mutations })
        defer { model.stop(); readModel.stop() }
        model.activate()
        await drain(executor)
        model.detail.updateNotesDraft("saved notes")
        _ = model.select(meetingID: "b", selectedIDs: ["b"])
        model.resolvePendingSelection(.save)
        XCTAssertEqual(model.selectedMeetingID, "a")

        let savedA = detail(rowA, notes: "saved notes", version: "saved")
        mutations.completeNext(.success(.detail(savedA)))
        await settleMainActor()
        XCTAssertEqual(model.selectedMeetingID, "b")
        XCTAssertEqual(model.detail.selectedMeetingID, "b")
        await drain(executor)
        XCTAssertEqual(model.detail.detail?.row.id, "b")
        XCTAssertEqual(model.detail.notesDraft?.baseVersion, version("b"), "B must own the editor base after Save")
        XCTAssertEqual(model.detail.notesDraft?.editedText, "B", "A's saved text must not appear under B")
        XCTAssertFalse(model.detail.notesDraft?.isDirty ?? true)
    }

    @MainActor
    func testExternalRefreshPreservesDirtyNotesAndSummaryVersionsUntilReload() async {
        let row = browserRow("a", state: .ready)
        let original = detail(row, notes: "Original note", summary: "Original summary", version: "old")
        let source = FeatureReadSource(rows: [row], details: ["a": original])
        let executor = ControlledFeatureReadExecutor()
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let model = MeetingsModel(readModelProvider: { readModel })
        defer { model.stop(); readModel.stop() }
        model.activate()
        await drain(executor)

        model.detail.updateNotesDraft("My note draft")
        model.detail.updateSummaryDraft("My summary draft")
        let external = detail(row, notes: "External note", summary: "External summary", version: "external")
        source.details["a"] = external
        readModel.invalidate(.jobTransition(meetingPaths: [row.meetingRelativePath]))
        await drain(executor)

        XCTAssertEqual(model.detail.detail?.humanNotes, "External note")
        XCTAssertEqual(model.detail.detail?.summary?.summary, "External summary")
        XCTAssertEqual(model.detail.notesDraft?.editedText, "My note draft")
        XCTAssertEqual(model.detail.notesDraft?.baseVersion, version("old"))
        XCTAssertEqual(model.detail.summaryDraft?.editedText, "My summary draft")
        XCTAssertEqual(model.detail.summaryDraft?.baseVersion, version("old"))
        model.detail.reloadDraftsAfterConfirmation()
        XCTAssertEqual(model.detail.notesDraft?.editedText, "External note")
        XCTAssertEqual(model.detail.summaryDraft?.editedText, "External summary")
        XCTAssertEqual(model.detail.notesDraft?.baseVersion, version("external"))
        XCTAssertEqual(model.detail.summaryDraft?.baseVersion, version("external"))
    }

    @MainActor
    func testNotesDraftUsesCanonicalVersionIndependentlyOfDoorwayAndSummary() async {
        let row = browserRow("canonical", state: .ready)
        func canonical(_ notes: String, version hash: String) -> MeetingBrowserDetail {
            MeetingBrowserDetail(row: row, doorwayText: "doorway", doorwayVersion: version("doorway"),
                humanNotes: notes, notesVersion: version(hash), summaryVersion: version("summary"),
                summary: MeetingSummarySections(summary: "Summary"))
        }
        let source = FeatureReadSource(rows: [row], details: [row.id: canonical("Initial notes", version: "notes-1")])
        let executor = ControlledFeatureReadExecutor()
        let readModel = makeReadModel("canonical-workspace", source: source, executor: executor)
        let mutations = ControlledMutationExecutor()
        let model = MeetingsModel(readModelProvider: { readModel }, mutationExecutorProvider: { mutations })
        defer { model.stop(); readModel.stop() }
        model.activate()
        await drain(executor)
        XCTAssertEqual(model.detail.notesDraft?.baseVersion, version("notes-1"))
        model.detail.beginEditingNotes()
        model.detail.updateNotesDraft("Local draft")
        source.details[row.id] = canonical("External notes", version: "notes-2")
        model.detail.refreshSelectedDetail()
        await drain(executor)
        XCTAssertEqual(model.detail.notesDraft?.editedText, "Local draft")
        XCTAssertEqual(model.detail.notesDraft?.baseVersion, version("notes-1"))
        model.detail.saveNotes()
        guard case let .saveNotes(id, text, base) = mutations.mutations[0] else {
            return XCTFail("Expected canonical notes mutation")
        }
        XCTAssertEqual(id, row.id)
        XCTAssertEqual(text, "Local draft")
        XCTAssertEqual(base, version("notes-1"))
        mutations.completeNext(.failure(WorkspaceVaultError.conflict(relativePath: "Meetings/canonical/my-notes.md",
            expected: version("notes-1"), actual: version("notes-2"))))
        await settleMainActor()
        model.detail.reloadDraftsAfterConfirmation()
        XCTAssertEqual(model.detail.notesDraft?.editedText, "External notes")
        XCTAssertEqual(model.detail.notesDraft?.baseVersion, version("notes-2"))
        XCTAssertEqual(model.detail.summaryDraft?.baseVersion, version("summary"))
        model.detail.updateNotesDraft("Saved notes")
        model.detail.saveNotes()
        mutations.completeNext(.success(.detail(canonical("Saved notes", version: "notes-3"))))
        await settleMainActor()
        XCTAssertEqual(model.detail.notesDraft?.baseVersion, version("notes-3"))
        XCTAssertFalse(model.detail.notesDraft?.isDirty ?? true)
    }

    @MainActor
    func testFailedAcceptPreservesProposalSelectionAndBusyStatePreventsDuplicateMutation() async {
        let mutations = ControlledMutationExecutor()
        let detailModel = MeetingDetailModel()
        detailModel.bind(readModel: nil, mutationExecutor: mutations, playbackTransport: nil)
        detailModel.selectActionProposals(["proposal-one"])

        detailModel.reviewAction(id: "proposal-one", accept: true)
        detailModel.reviewAction(id: "proposal-one", accept: true)
        XCTAssertEqual(mutations.mutations.count, 1)
        XCTAssertTrue(detailModel.isMutationInFlight)
        guard case .reviewAction(id: "proposal-one", accept: true) = mutations.mutations[0] else {
            return XCTFail("Expected one accept request")
        }

        mutations.completeNext(.failure(FeatureMutationError.failed))
        await settleMainActor()
        XCTAssertFalse(detailModel.isMutationInFlight)
        XCTAssertEqual(detailModel.selectedActionProposalIDs, ["proposal-one"])
        if case let .failed(_, conflict) = detailModel.mutationState { XCTAssertFalse(conflict) }
        else { XCTFail("Expected failed review state") }

        detailModel.reviewAction(id: "proposal-one", accept: true)
        mutations.completeNext(.success(.none))
        await settleMainActor()
        XCTAssertEqual(mutations.mutations.count, 2, "One retry after failure is the only second submission")
        XCTAssertEqual(detailModel.selectedActionProposalIDs, ["proposal-one"])
    }

    @MainActor
    func testPlaybackSurvivesRefreshAndPageChangesButStopsOnceWhenMeetingChanges() async {
        let rowA = browserRow("a", state: .ready)
        let rowB = browserRow("b", state: .ready)
        let sourceA = detail(rowA, playback: MeetingPlayback(capability: .microphoneOnly,
            microphonePath: "/tmp/a.wav", durationSeconds: 30, message: "A audio"))
        let sourceB = detail(rowB, playback: MeetingPlayback(capability: .unavailable, message: "No recording"))
        let source = FeatureReadSource(rows: [rowA, rowB], details: ["a": sourceA, "b": sourceB])
        let executor = ControlledFeatureReadExecutor()
        let transport = FakePlaybackTransport()
        let readModel = makeReadModel("workspace", source: source, executor: executor)
        let detailModel = MeetingDetailModel()
        detailModel.bind(readModel: readModel, mutationExecutor: nil, playbackTransport: transport)
        readModel.readBrowser(filters: MeetingBrowserFilters()) { _ in }
        await drain(executor)
        detailModel.select(MeetingReference(row: rowA))
        await drain(executor)
        XCTAssertEqual(transport.playerGeneration, 1)

        detailModel.setPage(.transcript)
        detailModel.refreshSelectedDetail()
        await drain(executor)
        XCTAssertEqual(detailModel.page, .transcript)
        detailModel.setPage(.overview)
        XCTAssertEqual(transport.stopCount, 0)
        XCTAssertEqual(transport.playerGeneration, 1, "Unchanged detail must not recreate the player")

        detailModel.select(MeetingReference(row: rowB))
        XCTAssertEqual(transport.stopCount, 1)
        await drain(executor)
        XCTAssertEqual(detailModel.playbackState.source?.message, "No recording")
        XCTAssertFalse(detailModel.playbackState.isAvailable)
        XCTAssertEqual(transport.stopCount, 1)
        detailModel.stop()
        XCTAssertEqual(transport.stopCount, 2, "Leaving Meetings stops its selected transport once")
        readModel.stop()
    }

    private func makeReadModel(_ workspaceID: String, source: FeatureReadSource,
                               executor: ControlledFeatureReadExecutor) -> MeetingReadModel {
        MeetingReadModel(workspaceID: workspaceID, sourceFactory: { source },
                         scheduleRead: executor.enqueue, deliver: { $0() })
    }

    private func browserRow(_ id: String, state: MeetingProcessingState,
                            failed: Bool = false, needsReview: Bool = false) -> MeetingBrowserRow {
        MeetingBrowserRow(id: id, title: id.uppercased(), startedAt: nil, meetingRelativePath: "Meetings/\(id)/meeting.md",
                          captureState: state == .live ? .live : .stopped, processingState: state,
                          job: failed ? MeetingJobPresentation(jobID: id, title: id, status: .failed,
                                                                stage: "stage", error: "failed") : nil,
                          needsActionReview: needsReview)
    }

    private func detail(_ row: MeetingBrowserRow, notes: String = "", summary: String = "",
                        version hash: String = "default", playback: MeetingPlayback = MeetingPlayback(capability: .unavailable,
                            message: "Recording Bundle unavailable")) -> MeetingBrowserDetail {
        MeetingBrowserDetail(row: row, doorwayText: "canonical", doorwayVersion: version(hash),
            humanNotes: notes, summaryVersion: version(hash), summary: MeetingSummarySections(summary: summary),
            playback: playback)
    }

    private func version(_ hash: String) -> WorkspaceFileVersion {
        WorkspaceFileVersion(contentHash: hash, modificationDate: Date(timeIntervalSince1970: 1), byteCount: 1)
    }

    @MainActor
    private func drain(_ executor: ControlledFeatureReadExecutor) async {
        for _ in 0..<30 {
            if executor.hasPending { executor.runNext() }
            await Task.yield()
        }
    }

    @MainActor
    private func settleMainActor() async {
        for _ in 0..<5 { await Task.yield() }
    }
}

private final class ControlledFeatureReadExecutor {
    private var operations: [() -> Void] = []
    var hasPending: Bool { !operations.isEmpty }
    func enqueue(_ operation: @escaping () -> Void) { operations.append(operation) }
    func runNext() { if !operations.isEmpty { operations.removeFirst()() } }
    func runLast() { if !operations.isEmpty { operations.removeLast()() } }
}

private final class FeatureReadSource: MeetingReadSource {
    var rows: [MeetingBrowserRow]
    var details: [String: MeetingBrowserDetail]
    private(set) var detailReadCount = 0

    init(rows: [MeetingBrowserRow], details: [String: MeetingBrowserDetail] = [:]) {
        self.rows = rows
        self.details = details
    }

    func browserProjection() throws -> [MeetingBrowserRow] { rows }
    func browserRows(filters: MeetingBrowserFilters, from projection: [MeetingBrowserRow]) throws -> MeetingBrowserReadResult {
        let available = projection.filter { $0.isArchived == filters.archived }
        let query = filters.query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return MeetingBrowserReadResult(visibleRows: available.filter { query.isEmpty || $0.title.lowercased().contains(query) },
                                       availableRows: available)
    }
    func detail(for reference: MeetingReference, browserRow: MeetingBrowserRow) throws -> MeetingBrowserDetail {
        detailReadCount += 1
        return details[reference.id] ?? MeetingBrowserDetail(row: browserRow, doorwayText: "canonical")
    }
    func updateSearchIndex(_ index: SearchIndex?) {}
    func updateCaptureSnapshot(_ snapshot: CaptureSnapshot?) {}
}

private enum FeatureMutationError: Error { case failed }

private final class ControlledMutationExecutor: MeetingMutationExecuting {
    private(set) var mutations: [MeetingMutation] = []
    private var completions: [(Result<MeetingMutationOutput, Error>) -> Void] = []

    func execute(_ mutation: MeetingMutation,
                 completion: @escaping (Result<MeetingMutationOutput, Error>) -> Void) {
        mutations.append(mutation)
        completions.append(completion)
    }

    func completeNext(_ result: Result<MeetingMutationOutput, Error>) {
        guard !completions.isEmpty else { XCTFail("No pending mutation"); return }
        completions.removeFirst()(result)
    }
}

@MainActor
private final class FakePlaybackTransport: MeetingPlaybackTransport {
    private(set) var state = MeetingPlaybackTransportState()
    var onChange: ((MeetingPlaybackTransportState) -> Void)?
    private(set) var playerGeneration = 0
    private(set) var stopCount = 0

    func load(_ source: MeetingPlayback) {
        guard state.source != source else { return }
        playerGeneration += source.capability == .unavailable ? 0 : 1
        state = MeetingPlaybackTransportState(source: source, duration: source.durationSeconds,
                                              isAvailable: source.capability != .unavailable)
        onChange?(state)
    }
    func play() { update(isPlaying: true) }
    func pause() { update(isPlaying: false) }
    func seek(to seconds: Double) {
        state = MeetingPlaybackTransportState(source: state.source, position: seconds, duration: state.duration,
                                              isPlaying: state.isPlaying, isAvailable: state.isAvailable)
        onChange?(state)
    }
    func stop() {
        guard state.source != nil else { return }
        stopCount += 1
        state = MeetingPlaybackTransportState()
        onChange?(state)
    }
    private func update(isPlaying: Bool) {
        state = MeetingPlaybackTransportState(source: state.source, position: state.position,
                                              duration: state.duration, isPlaying: isPlaying,
                                              isAvailable: state.isAvailable)
        onChange?(state)
    }
}
