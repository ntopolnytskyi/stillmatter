#if DEBUG || STILLMATTER_NATIVE_PROBES
import AppKit
import AVFoundation
import StillmatterCore
import StillmatterPresentation

// Existing Task 04 optimized probes use STILLMATTER_NATIVE_PROBES in a separate
// build directory. Ordinary release builds exclude these synthetic walkthroughs.
extension MeetingManagementView {
    func validateLongContentOverflowFixture() {
        let savedQuery = queryField.stringValue
        let savedStatus = filterStatus.stringValue
        defer {
            queryField.stringValue = savedQuery
            filterStatus.stringValue = savedStatus
            GraphiteFocusOverflow.configureSecondaryMetadata(filterStatus, fullText: savedStatus)
        }
        let longTitle = "Зустріч із надзвичайно довгою перекладеною назвою про контрольні інтерфейси, цитати, фільтри та поведінку переповнення на підтримуваному мінімумі"
        GraphiteFocusPageHeader.setTitle(longTitle, on: meetingTitle)
        precondition(meetingTitle.maximumNumberOfLines == 1 && meetingTitle.lineBreakMode == .byTruncatingTail,
                     "Long Meeting titles must tail-truncate visually")
        precondition(meetingTitle.toolTip == longTitle && meetingTitle.accessibilityLabel() == longTitle,
                     "Long Meeting titles must remain readable in full")
        queryField.stringValue = "надзвичайно-довгий-фільтр-який-не-може-витіснити-список"
        updateFilterStatus(visibleCount: 0)
        precondition(filterStatus.toolTip?.contains(queryField.stringValue) == true,
                     "Filtered empty state must expose full active Meeting filters")
        let path = "Meetings/2026/09/20/дуже-довга-назва-наради-з-перекладеним-шляхом/transcript.json"
        let pathLabel = NSTextField(labelWithString: path)
        GraphiteFocusOverflow.configureSecondaryMetadata(pathLabel, fullText: path)
        precondition(pathLabel.lineBreakMode == .byTruncatingMiddle && pathLabel.toolTip == path,
                     "Long source paths may truncate only with a full-text route")
        let prose = NSTextField(wrappingLabelWithString: "Status explanation with a long localized-looking sentence wraps instead of clipping or using an ellipsis as the sole essential state text.")
        GraphiteFocusOverflow.configureWrappingText(prose, fullText: prose.stringValue)
        precondition(prose.maximumNumberOfLines == 0 && prose.lineBreakMode == .byWordWrapping,
                     "Status explanations and prose must wrap")
        let citations = NSPopUpButton(frame: .zero, pullsDown: true)
        citations.addItem(withTitle: "Sources (6)")
        citations.setAccessibilityLabel("Transcript sources for the cited action")
        precondition(citations.accessibilityLabel() == "Transcript sources for the cited action",
                     "Crowded citations must have an accessible disclosure or menu route")
        let typedReviewRow = MeetingOutcomeRow(id: "fixture", text: "Send the localized draft",
            provenance: "Generated from meeting", reviewState: .pending, citations: [])
        precondition(typedReviewRow.isPendingReview && typedReviewRow.detailText.contains("pending"),
                     "Meeting review availability must use typed review state")
        let emptyState = FocusableMeetingEmptyState(labelWithString: "No actions are awaiting review.")
        precondition(emptyState.acceptsFirstResponder,
                     "The Meeting review empty state must accept programmatic focus")
        let processingRow = MeetingBrowserRow(id: "processing", title: "Processing", startedAt: nil,
            meetingRelativePath: "Meetings/processing/meeting.md", captureState: .stopped,
            processingState: .processing)
        let unavailableRow = MeetingBrowserRow(id: "unavailable", title: "Unavailable", startedAt: nil,
            meetingRelativePath: "Meetings/unavailable/meeting.md", captureState: .unavailable,
            processingState: .unavailable)
        precondition(statusMeaning(for: processingRow) == .informational &&
                     statusMeaning(for: unavailableRow) == .informational,
                     "Meeting processing and unavailable states must not borrow attention or failure meaning")
    }

    func validateTimelineSelectionFixture() {
        // AppKit may ask for the old row during deferred layout after the feature
        // publishes an empty workspace. The committed projection must be cleared.
        #if DEBUG
        if let oldRow = meetingsModel.visibleRows.first {
            let empty = MeetingFixtureProviders.make(serviceProvider: { nil })
            empty.renderedRows = [oldRow]
            empty.table.reloadData()
            precondition(empty.numberOfRows(in: empty.table) == 1)
            empty.applySnapshot(nil)
            precondition(empty.numberOfRows(in: empty.table) == 0 && empty.table.numberOfRows == 0 &&
                         empty.tableView(empty.table, viewFor: empty.table.tableColumns.first, row: 0) == nil,
                         "Empty workspace must commit zero AppKit rows before stale layout")
        }
        #endif
        let kinds = Set(MeetingTimelineMoment.Kind.allCases)
        let moments = (0..<240).map { index in
            MeetingTimelineMoment(id: "\(index)", seconds: Double(index * 60),
                kind: index.isMultiple(of: 3) ? .action : .transcript,
                text: index == 235 ? "unique late phrase" : "ordinary", context: "Speaker", seekSeconds: Double(index * 60))
        }
        let first = MeetingTimelineSelection.visible(moments, included: kinds, position: 0, query: "")
        precondition(first.count == 15 && first.last?.seconds == 840, "Ordinary browsing must bound a four-hour timeline")
        let fourthHour = MeetingTimelineSelection.visible(moments, included: [.action], position: 3 * 3600 + 15 * 60, query: "")
        precondition(fourthHour.allSatisfy { $0.kind == .action && $0.seconds >= 11700 && $0.seconds < 12600 },
                     "Hour jumps and independent filters must respect the selected window")
        precondition(MeetingTimelineSelection.visible(moments, included: kinds, position: 0, query: "unique late phrase").count == 1,
                     "Search must cover the whole recording")
        precondition(MeetingTimelineSelection.visible(moments, included: kinds, position: 0, query: "no match").isEmpty,
                     "Missing search terms must produce an empty result")
        openTimeline()
        precondition(!caption.isHidden && !pinnedAudio.isHidden && pageSelector.selectedSegment == 1 && overviewPage.isHidden && !timelinePage.isHidden,
                     "Transcript replaces overview but keeps the header and transport")
        closeTimeline()
        precondition(!overviewPage.isHidden && timelinePage.isHidden && pageSelector.selectedSegment == 0,
                     "Overview selection must restore meeting details")
    }

    #if DEBUG
    var browserFixtureRowCount: Int { rows.count }
    #endif
    var selectedTitleForValidation: String? { displayedDetail?.row.title }
    var task04BrowserTitleForValidation: String? { meetingsModel.visibleRows.first { $0.id == "synthetic-audio" }?.title }
    var hasDirtyNotesForValidation: Bool { meetingsModel.detail.notesDraft?.isDirty == true }

    #if DEBUG
    var task05VisibleIDs: [String] { meetingsModel.visibleRows.map(\.id) }
    var task05VisibleTitles: [String] { meetingsModel.visibleRows.map(\.title) }
    var task05RenderedIDs: [String] { rows.map(\.id) }
    var task05CanReadDetail: Bool { meetingsModel.task05ReadRows?["Meetings/same/meeting.md"] == "same" }
    var task05SelectionDiagnostic: String { "table=\(table.selectedRow) selected=\(meetingsModel.selectedMeetingID ?? "nil") detail=\(String(describing: meetingsModel.detail.loadState)) readRows=\(String(describing: meetingsModel.task05ReadRows)) binding=\(meetingsModel.task05DetailBindingMatches)" }
    func task05Select(_ id: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { preconditionFailure("Missing fixture row \(id)") }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        show(row: index)
    }
    func task05RetryDetail() { meetingsModel.detail.refreshSelectedDetail() }
    func task05RecoverDetailIfFailed() {
        if case .failed = meetingsModel.detail.loadState, task05CanReadDetail { task05RetryDetail() }
    }
    func task05EditNotes(_ marker: String) {
        guard let draft = meetingsModel.detail.notesDraft else { preconditionFailure("Missing fixture draft") }
        meetingsModel.detail.beginEditingNotes()
        meetingsModel.detail.updateNotesDraft(draft.editedText + marker)
    }
    func task05Assert(_ id: String?, title: String?, draft: String? = nil) {
        precondition(rows == meetingsModel.visibleRows && table.numberOfRows == rows.count)
        precondition(meetingsModel.selectedMeetingID == id && selectedID == id)
        precondition(displayedDetail?.row.title == title && meetingsModel.detail.detail?.row.title == title)
        if let draft { precondition(meetingsModel.detail.notesDraft?.editedText.contains(draft) == true) }
        for index in rows.indices {
            guard let cell = table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSStackView,
                  let label = cell.arrangedSubviews.first as? NSTextField else { preconditionFailure("Missing AppKit row") }
            precondition(label.stringValue == rows[index].displayTitle, "AppKit cell must match committed datasource")
        }
        let expected = rows.firstIndex(where: { $0.id == id }) ?? -1
        precondition(table.selectedRow == expected, "AppKit selection must match detail")
    }
    func task05AssertEmpty() {
        precondition(rows.isEmpty && table.numberOfRows == 0 && table.selectedRow == -1 &&
                     meetingsModel.selectedMeetingID == nil && displayedDetail == nil,
                     "Empty projection: rows=\(rows.map(\.title)) table=\(table.numberOfRows) selected=\(task05SelectionDiagnostic) displayed=\(selectedTitleForValidation ?? "nil")")
        precondition(tableView(table, viewFor: table.tableColumns.first, row: 0) == nil,
                     "Deferred AppKit row callback must tolerate empty projection")
    }
    #endif

    func task04ProposalStateForValidation() -> ProposalReviewState? {
        displayedDetail?.myActionItems.first { $0.id == "task04-accept" }?.reviewState
    }

    func task04BrowserNeedsReviewForValidation() -> Bool? {
        meetingsModel.visibleRows.first { $0.id == "synthetic-audio" }?.needsActionReview
    }

    /// Probe selected Meeting state through compact Back without writing the workspace.
    func prepareNarrowStateForValidation() -> String {
        guard let id = selectedID, let draft = meetingsModel.detail.notesDraft else {
            preconditionFailure("Task 04 narrow fixture needs an editable selected Meeting")
        }
        meetingsModel.detail.beginEditingNotes()
        meetingsModel.detail.updateNotesDraft(draft.editedText + " task04-unsaved-marker")
        meetingsModel.detail.setPage(.transcript)
        precondition(meetingsModel.detail.hasDirtyDrafts, "Narrow fixture must create an unsaved draft")
        return id
    }

    func openSelectionForValidation() { onOpenSelection() }

    func verifyNarrowStateForValidation(id: String) {
        precondition(selectedID == id && meetingsModel.detail.page == .transcript &&
                     meetingsModel.detail.notesDraft?.editedText.hasSuffix(" task04-unsaved-marker") == true &&
                     meetingsModel.detail.hasDirtyDrafts,
                     "Compact Back must retain Meeting selection, Transcript page, and unsaved notes")
        meetingsModel.detail.discardDrafts()
        meetingsModel.detail.setPage(.overview)
    }

    /// The shell fixture must exercise a selected detail, not placeholder geometry.
    func prepareCaptionLayoutFixture(completion: @escaping () -> Void) {
        let deadline = Date().addingTimeInterval(8)
        func awaitDetail(_ id: String) {
            if displayedDetail?.row.id == id && !toolbar.isHidden {
                layoutSubtreeIfNeeded()
                completion()
                return
            }
            precondition(Date() < deadline, "Meeting header fixture needs a loaded, visible detail toolbar")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { awaitDetail(id) }
        }
        func awaitBrowser() {
            if let row = rows.first {
                _ = meetingsModel.select(meetingID: row.id, selectedIDs: [row.id])
                awaitDetail(row.id)
                return
            }
            precondition(Date() < deadline, "Meeting header fixture needs a loaded browser row")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { awaitBrowser() }
        }
        awaitBrowser()
    }

    func validateCaptionLayoutFixture() {
        precondition(displayedDetail != nil && !toolbar.isHidden && window != nil,
                     "Meeting header clearance requires a visible selected detail in a window")
        let savedTitle = meetingTitle.stringValue
        let savedOverview = overview.stringValue
        let savedHidden = statusBadge.isHidden
        defer {
            GraphiteFocusPageHeader.setTitle(savedTitle, on: meetingTitle)
            overview.stringValue = savedOverview
            statusBadge.isHidden = savedHidden
        }
        GraphiteFocusPageHeader.setTitle("Untitled Meeting at 2026-10-07 17:35 — This deliberately localized-looking title continues far beyond the available header width so the Page Header title must truncate at the tail while all local actions remain visible", on: meetingTitle)
        overview.stringValue = "7 Oct 2026 at 17:35  ·  Project: Orchid"
        statusBadge.isHidden = false
        processingProgress.isHidden = true
        processingStatus.isHidden = false
        processingStatus.setStatus("Ready", meaning: .success, colors: presentationColors)
        styleStatusBadge(meaning: .success)
        layoutSubtreeIfNeeded()
        let title = meetingTitle.convert(meetingTitle.bounds, to: self)
        let metadata = overview.convert(overview.bounds, to: self)
        let state = statusBadge.convert(statusBadge.bounds, to: self)
        precondition(bounds.height - title.maxY < 85, "Meeting caption must occupy the compact top region")
        // Negative fixture: move the real visible action cluster into the title's frame.
        // Only used by the disposable harness to prove the unchanged clearance guard is live.
        if ProcessInfo.processInfo.environment["STILLMATTER_SHELL_LAYOUT_HARNESS"] == "1" &&
            ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_OVERLAP_MEETING_HEADER"] == "1" {
            toolbar.setFrameOrigin(NSPoint(x: meetingTitle.frame.minX, y: toolbar.frame.minY))
        }
        let toolbarFrame = toolbar.convert(toolbar.bounds, to: self)
        precondition(meetingTitle.maximumNumberOfLines == 1 && meetingTitle.lineBreakMode == .byTruncatingTail,
                     "Meeting Page Header title must be a single tail-truncated line")
        precondition(meetingTitle.toolTip == meetingTitle.stringValue && meetingTitle.accessibilityLabel() == meetingTitle.stringValue,
                     "Meeting Page Header title must expose the complete title outside the truncated visual line")
        if ProcessInfo.processInfo.environment["STILLMATTER_SHELL_LAYOUT_HARNESS"] == "1" {
            print("MEETING_HEADER selected=\(selectedID ?? "nil") visible=\(!toolbar.isHidden) title=\(title) toolbar=\(toolbarFrame) window=\(String(describing: window?.frame))")
            fflush(stdout)
        }
        precondition(title.maxX <= toolbarFrame.minX - GraphiteFocusPresentation.Space.compact + 1,
                     "Meeting title must yield width before overlapping local header actions")
        precondition(state.maxY <= metadata.minY + 1, "Meeting state must occupy the third caption line")
        precondition(abs(state.minX - metadata.minX) <= 2, "Meeting state must align with the date")
        precondition(abs(toolbarFrame.maxX - caption.convert(caption.bounds, to: self).maxX) < 2,
                     "Meeting controls must align to the right edge of the caption")
        precondition(transcriptionButton.bounds.width == 36 && transcriptionButton.bounds.height == 36,
                     "Meeting toolbar controls must match the reference dimensions")
        let controls = [transcriptionButton, editSummaryTool, editNotesTool, archiveButton, moreButton]
        for control in controls where !control.isHidden {
            let frame = control.convert(control.bounds, to: toolbar)
            let reference = transcriptionButton.convert(transcriptionButton.bounds, to: toolbar)
            precondition(abs(frame.minY - reference.minY) < 1 && abs(frame.maxY - reference.maxY) < 1,
                         "Meeting header buttons must share top and bottom edges")
        }
    }

    func validateAudioTransportFixture(completion: @escaping () -> Void) {
        if let root = ProcessInfo.processInfo.environment["STILLMATTER_REPLAY_WORKSPACE_ROOT"],
           let recordingID = ProcessInfo.processInfo.environment["STILLMATTER_REPLAY_RECORDING_ID"] {
            let workspaceURL = URL(fileURLWithPath: root)
            let readModel = MeetingReadModel(workspaceID: root, sourceFactory: {
                let vault = WorkspaceVault(workspaceRootURL: workspaceURL,
                    appSupportRootURL: FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterAudioReplay-\(UUID().uuidString)"))
                return MeetingManagementReadSource(serviceProvider: { MeetingManagementService(vault: vault) })
            })
            defer { readModel.stop() }
            var browser: Result<MeetingBrowserSnapshot, MeetingReadError>?
            readModel.readBrowser(filters: MeetingBrowserFilters()) { browser = $0 }
            let browserDeadline = Date().addingTimeInterval(5)
            while browser == nil && Date() < browserDeadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            let rows = (try? browser?.get().visibleRows) ?? []
            var playback: MeetingPlayback?
            for row in rows {
                var result: Result<MeetingBrowserDetail, MeetingReadError>?
                readModel.readDetail(for: MeetingReference(row: row)) { result = $0 }
                let detailDeadline = Date().addingTimeInterval(5)
                while result == nil && Date() < detailDeadline {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.01))
                }
                if let detail = try? result?.get(),
                   detail.doorwayText.components(separatedBy: .newlines).contains(where: {
                       $0.hasPrefix("recording_bundle:") && $0.contains(recordingID)
                   }) {
                    playback = detail.playback
                }
            }
            guard let playback else { preconditionFailure("Replay must select exactly one recording") }
            precondition(playback.capability != .unavailable, "Replay bundle must be playable")
            bindAudio(playback)
            precondition(playButton.isEnabled, "Replay Play must be enabled")
            playButton.performClick(nil)
            let deadline = Date().addingTimeInterval(3)
            while (audioPlayer?.elapsed ?? 0) < 0.05 && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition((audioPlayer?.elapsed ?? 0) >= 0.05, "Replay Play must advance audio")
            precondition(audioPlayer?.activeTrackCount == (playback.systemPath == nil ? 1 : 2),
                         "Replay must play both available source tracks together")
            clearAudio()
        }
        clearAudio()
        precondition(!playButton.isEnabled && !waveform.isEnabled, "Missing Meeting audio must not expose a functional transport")
        precondition(audioStatus.stringValue.contains("Recording Bundle unavailable"), "Missing audio must explain the unavailable state")
        precondition(playButton.accessibilityLabel() == "Play Meeting audio", "Transport needs a spoken play label")
        precondition(waveform.accessibilityLabel() == "Meeting audio position", "Timeline needs a spoken seek label")
        let file = (ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("Stillmatter-MeetingAudio-\(UUID().uuidString).caf")
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            try { () throws in
                let writer = try AVAudioFile(forWriting: file, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
                buffer.frameLength = 48000
                try writer.write(from: buffer)
            }()
            let original = try Data(contentsOf: file)
            let waveformLevels = MeetingWaveformView.sample(path: file.path, duration: 1)
            precondition(waveformLevels.count == 96 && waveformLevels.allSatisfy { (0...1).contains($0) },
                         "Waveform sampling must be bounded and normalized")
            bindAudio(MeetingPlayback(capability: .microphoneOnly, microphonePath: file.path,
                durationSeconds: 1, message: "Partial recording: microphone-only audio; system audio unavailable."))
            // The transport publishes to feature state on the main actor. Return to the
            // event loop before checking the rendered controls; a nested RunLoop does
            // not drain that actor job. Retain the file until the continuation finishes.
            let readinessDeadline = Date().addingTimeInterval(8)
            func afterPlaybackPublication() {
                if (!playButton.isEnabled || audioPlayer == nil) && Date() < readinessDeadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: afterPlaybackPublication)
                    return
                }
                precondition(playButton.isEnabled && waveform.isEnabled, "Recovered microphone audio needs one transport")
                Task { @MainActor in
                    await validateLoadedAudioFixture(file: file, original: original, completion: completion)
                }
            }
            DispatchQueue.main.async(execute: afterPlaybackPublication)
        } catch { preconditionFailure("Meeting audio shell fixture failed: \(error)") }
    }

    private func validateLoadedAudioFixture(file: URL, original: Data, completion: @escaping () -> Void) async {
        do {
            precondition(audioStatus.stringValue.contains("microphone-only"), "Degraded playback must be labeled")
            precondition(abs(waveform.maxValue - 1) < 0.01, "Seek range must match playable duration")
            precondition(waveform.accessibilityRole() == .slider, "Waveform must retain native slider accessibility")
            openTimeline()
            layoutSubtreeIfNeeded()
            precondition(waveform.bounds.width > 100 && waveform.bounds.height > 0,
                         "Playable audio must have a visible, full-width seek target in the real detail layout")
            waveform.setFrameSize(NSSize(width: 220, height: 44))
            let click = NSEvent.mouseEvent(with: .leftMouseDown,
                location: waveform.convert(NSPoint(x: 110, y: 22), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            waveform.mouseDown(with: click)
            precondition(abs((audioPlayer?.elapsed ?? 0) - 0.5) < 0.01,
                         "Clicking the waveform must seek the selected Meeting audio")
            let drag = NSEvent.mouseEvent(with: .leftMouseDragged,
                location: waveform.convert(NSPoint(x: 160, y: 22), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            waveform.mouseDragged(with: drag)
            precondition(abs((audioPlayer?.elapsed ?? 0) - 0.75) < 0.01,
                         "Dragging the waveform must seek continuously")
            audioPlayer?.seek(to: 10)
            let clampDeadline = Date().addingTimeInterval(3)
            while abs(waveform.doubleValue - 1) >= 0.01 && Date() < clampDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(abs(waveform.doubleValue - 1) < 0.01, "Seeking past the end must clamp")
            audioPlayer?.seek(to: 0)
            let playbackStartedAt = Date()
            playButton.performClick(nil)
            let playDeadline = Date().addingTimeInterval(3)
            while playButton.title != "Pause" && Date() < playDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(audioPlayer?.isPlaying == true && playButton.title == "Pause" &&
                         playButton.accessibilityLabel() == "Pause Meeting audio",
                         "Activating Play must start playback and offer Pause")
            let syntheticPlaybackDeadline = Date().addingTimeInterval(2)
            while ((audioPlayer?.elapsed ?? 0) < 0.05 || waveform.doubleValue == 0) && Date() < syntheticPlaybackDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition((audioPlayer?.elapsed ?? 0) >= 0.05 && waveform.doubleValue > 0,
                         "Play must advance audio and its visible timeline")
            while Date().timeIntervalSince(playbackStartedAt) < 0.65 {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition((audioPlayer?.elapsed ?? 0) < 0.9 && audioPlayer?.isPlaying == true,
                         "Playback must not count elapsed device time again on every timer tick")
            let playbackClick = NSEvent.mouseEvent(with: .leftMouseDown,
                location: waveform.convert(NSPoint(x: waveform.bounds.midX, y: waveform.bounds.midY), to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            waveform.mouseDown(with: playbackClick)
            precondition(abs((audioPlayer?.elapsed ?? 0) - 0.5) < 0.08 && audioPlayer?.isPlaying == true,
                         "Seeking during playback must move the playhead without stopping playback")
            playButton.performClick(nil)
            let pauseDeadline = Date().addingTimeInterval(3)
            while playButton.title != "Play" && Date() < pauseDeadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            precondition(audioPlayer?.isPlaying == false && playButton.title == "Play" &&
                         playButton.accessibilityLabel() == "Play Meeting audio",
                         "Activating Pause must stop playback and offer Play")

            #if DEBUG
            try await validateProviderScenarios(audioFile: file)
            #endif
            clearAudio() // Leaving Meetings stops the previous audio.
            precondition(!playButton.isEnabled && waveform.doubleValue == 0 && audioPlayer == nil,
                         "Leaving Meetings must discard the old Meeting timeline")
            let after = try Data(contentsOf: file)
            precondition(after == original, "Listening must not modify source audio")
            clearAudio()
            try FileManager.default.removeItem(at: file)
            completion()
        } catch { preconditionFailure("Meeting audio shell fixture failed: \(error)") }
    }

}
#endif
