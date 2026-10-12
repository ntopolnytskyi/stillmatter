#if DEBUG
import AppKit
import AVFoundation
import StillmatterCore
import StillmatterPresentation

// Shared by the signed DEBUG broad and independent six-behavior probes.
extension MeetingManagementView {
    private func waitForMeetingFixture(_ label: String, until ready: () -> Bool) async {
        let deadline = Date().addingTimeInterval(8)
        while !ready() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(ready(), "Meeting fixture timed out: \(label)")
    }

    func validateExplicitProviderFixtures() async {
        let file = meetingFixtureTemporaryRoot.appendingPathComponent("focused-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
            try { () throws in
                let writer = try AVAudioFile(forWriting: file, settings: format.settings)
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000)!
                buffer.frameLength = 48000
                try writer.write(from: buffer)
            }()
            let original = try Data(contentsOf: file)
            try await validateProviderScenarios(audioFile: file)
            let after = try Data(contentsOf: file)
            precondition(after == original, "Provider fixtures must preserve source audio")
            print("TASK09_MEETING all six explicit-provider behaviors passed (DEBUG; broad audio excluded)")
            fflush(stdout)
        } catch { preconditionFailure("Meeting provider fixtures failed: \(error)") }
    }

    private var meetingFixtureTemporaryRoot: URL {
        ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
    }

    func validateProviderScenarios(audioFile file: URL) async throws {
            let fixture = try MeetingScenarioWorkspace(audioFile: file, temporaryRoot: meetingFixtureTemporaryRoot)
            let workspaceRoot = fixture.root
            let vault = fixture.vault
            defer { fixture.remove() }
            let selectionView = MeetingFixtureProviders.make(serviceProvider: { MeetingManagementService(vault: vault) })
            selectionView.refresh(isVisible: true)
            await waitForMeetingFixture("selection detail") { selectionView.segmentLabels.count == 1 && selectionView.playButton.isEnabled && selectionView.transcriptRows.arrangedSubviews.contains { $0 is NSButton } }
            let empty = MeetingFixtureProviders.make(serviceProvider: { nil })
            empty.renderedRows = [selectionView.rows[0]]
            empty.table.reloadData()
            precondition(empty.numberOfRows(in: empty.table) == 1)
            empty.applySnapshot(nil)
            precondition(empty.numberOfRows(in: empty.table) == 0 && empty.table.numberOfRows == 0 &&
                         empty.tableView(empty.table, viewFor: empty.table.tableColumns.first, row: 0) == nil,
                         "Empty workspace must commit zero AppKit rows before stale layout")
            print("TASK09_MEETING empty projection passed"); fflush(stdout)
            precondition(selectionView.segmentLabels.count == 1 && selectionView.evidenceRows.arrangedSubviews.count > 1,
                         "Selected Meeting must show its Transcript and cited decision")
            let segmentButton = selectionView.transcriptRows.arrangedSubviews.compactMap { $0 as? NSButton }.first!
            selectionView.seekEvidence(segmentButton)
            await waitForMeetingFixture("transcript seek") { abs(selectionView.waveform.doubleValue - 0.1) < 0.01 }
            precondition(abs(selectionView.waveform.doubleValue - 0.1) < 0.01, "Transcript segment must seek selected audio")
            selectionView.audioPlayer?.seek(to: 0.8)
            await waitForMeetingFixture("gap seek") { abs(selectionView.waveform.doubleValue - 0.8) < 0.01 }
            precondition(selectionView.segmentLabels[0].1.font?.fontDescriptor.symbolicTraits.contains(.bold) == false,
                         "Gaps must not highlight a Transcript segment")
            let firstEvidence = selectionView.evidenceRows.arrangedSubviews.compactMap { $0 as? NSButton }.first!
            precondition(firstEvidence.accessibilityLabel()?.contains("approximately") == true, "Evidence seek must be accessible and approximate")
            selectionView.seekEvidence(firstEvidence)
            await waitForMeetingFixture("outcome seek") { abs(selectionView.waveform.doubleValue - 0.1) < 0.01 }
            precondition(abs(selectionView.waveform.doubleValue - 0.1) < 0.01, "Cited outcome must seek selected audio")
            precondition(selectionView.segmentLabels[0].1.font?.fontDescriptor.symbolicTraits.contains(.bold) == true,
                         "Playback position must highlight the current segment")
            selectionView.playButton.performClick(nil)
            await waitForMeetingFixture("selection play") { selectionView.playButton.title == "Pause" }
            precondition(selectionView.playButton.title == "Pause", "Selected Meeting Play must offer Pause")
            guard let firstPlayer = selectionView.audioPlayer else {
                preconditionFailure("First Meeting must bind its audio player")
            }
            let nextIndex = selectionView.rows.firstIndex { $0.id != selectionView.displayedDetail?.row.id }!
            selectionView.table.selectRowIndexes(IndexSet(integer: nextIndex), byExtendingSelection: false)
            selectionView.show(row: nextIndex)
            await waitForMeetingFixture("second selection detail") { selectionView.displayedDetail?.row.id == selectionView.rows[nextIndex].id }
            await waitForMeetingFixture("second selection playback") { selectionView.audioPlayer !== firstPlayer && selectionView.playButton.isEnabled }
            let secondPlayer = selectionView.audioPlayer
            selectionView.seekEvidence(firstEvidence)
            precondition(selectionView.audioPlayer === secondPlayer && selectionView.waveform.doubleValue == 0,
                         "Stale evidence must not seek the new Meeting")
            precondition(selectionView.segmentLabels[0].1.stringValue.contains(selectionView.rows[nextIndex].title),
                         "Transcript must switch with the selected Meeting")
            precondition(selectionView.audioPlayer !== firstPlayer && !firstPlayer.isPlaying,
                         "Selecting another Meeting must stop and replace the previous Meeting player")
            precondition(selectionView.playButton.title == "Play" &&
                         selectionView.playButton.accessibilityLabel() == "Play Meeting audio",
                         "Switching Meetings must reset Play and its spoken label")
            let secondTimeline = selectionView.audioTime.stringValue
            firstPlayer.seek(to: 0.5)
            precondition(selectionView.audioTime.stringValue == secondTimeline,
                         "A stale Meeting player must not update the selected Meeting timeline")
            let readable = selectionView.displayedDetail!
            selectionView.bindAudio(MeetingPlayback(capability: .unavailable, message: "Audio unavailable"))
            await waitForMeetingFixture("unavailable playback") { !selectionView.playButton.isEnabled }
            selectionView.renderEvidence(readable)
            precondition(selectionView.segmentLabels.count == 1 &&
                         selectionView.transcriptRows.arrangedSubviews.compactMap({ $0 as? NSButton }).isEmpty &&
                         selectionView.transcriptRows.arrangedSubviews.contains(where: { ($0 as? NSTextField)?.stringValue.contains("Seek unavailable") == true }),
                         "Transcript stays readable without audio, with no working evidence seek")

            let jobStore = try JobStore(databaseURL: workspaceRoot.appendingPathComponent("Support/retry-fixture.sqlite"))
            let scheduler = JobScheduler(store: jobStore, executor: MeetingRetryFixtureExecutor())
            _ = try scheduler.enqueue(id: "failed-first", manifest: JobManifest(
                type: MeetingSummaryJob.type, title: "Summarize first", executionClass: .heavy,
                stages: [JobStageDefinition(id: "summarize", title: "Generate Summary")],
                metadata: ["capture_session_id": "first"], maxAutomaticRetries: 0))
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline && (try? jobStore.job(id: "failed-first")?.status) != .failed {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            let failedFixtureJob = try jobStore.job(id: "failed-first")
            precondition(failedFixtureJob?.status == .failed, "Retry fixture must fail")
            let retryView = MeetingFixtureProviders.make(serviceProvider: {
                MeetingManagementService(vault: vault, jobStore: jobStore, retryUnavailableReason: { _ in nil },
                    retryDispatcher: { _, id, path, session in
                        try scheduler.retry(id: id, meetingRelativePath: path, captureSessionID: session)
                    })
            })
            print("TASK09_MEETING audio/evidence selection passed"); fflush(stdout)
            retryView.refresh(isVisible: true)
            await waitForMeetingFixture("retry browser") { !retryView.rows.isEmpty }
            let firstIndex = retryView.rows.firstIndex(where: { $0.id == "first" })!
            retryView.table.selectRowIndexes(IndexSet(integer: firstIndex), byExtendingSelection: false)
            retryView.show(row: firstIndex)
            await waitForMeetingFixture("retry detail") { retryView.displayedDetail?.row.id == "first" && !retryView.retryRows.arrangedSubviews.isEmpty }
            let retryButton = retryView.retryRows.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first }.first
            precondition(retryButton?.isEnabled == true && retryButton?.accessibilityLabel()?.contains("Summarize first") == true,
                         "Failed Meeting needs an accessible Retry control")
            retryView.retryFailedJob(retryButton!)
            await waitForMeetingFixture("retry completion") { retryView.retryFeedback != nil }
            await waitForMeetingFixture("retry mutation") { retryView.status.stringValue.contains("Retry queued") && retryView.retryRows.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first }.isEmpty }
            precondition(retryView.status.stringValue.contains("Retry queued") && retryView.selectedID == "first",
                         "Retry feedback and selected Meeting must survive refresh")
            precondition(retryView.retryRows.arrangedSubviews.compactMap { ($0 as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton }.first }.isEmpty,
                         "Repeated Retry must not remain available while processing")
            retryView.refresh(isVisible: false)

            let cancelView = MeetingFixtureProviders.make(serviceProvider: {
                MeetingManagementService(vault: vault, jobStore: jobStore, retryUnavailableReason: { _ in nil })
            }, presentConfirmationAlert: { alert in
                precondition(alert.buttons.count == 2, "Actions must offer Cancel")
                if alert.messageText.contains("Rename") {
                    precondition(alert.informativeText.contains("outside Stillmatter") &&
                                 (alert.accessoryView as? NSTextField)?.stringValue == "second",
                                 "Rename must warn about external links and offer the current title")
                } else {
                    precondition(alert.informativeText.contains("manual Summary edits"),
                                 "Reprocess must warn about replacement")
                    precondition((alert.accessoryView as? NSPopUpButton)?.itemTitles == ["English", "Ukrainian"],
                                 "Reprocess must offer both supported languages")
                }
                return .alertSecondButtonReturn
            })
            print("TASK09_MEETING retry passed"); fflush(stdout)
            cancelView.refresh(isVisible: true)
            await waitForMeetingFixture("cancel browser") { !cancelView.rows.isEmpty }
            let cancelIndex = cancelView.rows.firstIndex(where: { $0.id == "second" })!
            cancelView.table.selectRowIndexes(IndexSet(integer: cancelIndex), byExtendingSelection: false)
            cancelView.show(row: cancelIndex)
            await waitForMeetingFixture("cancel detail") { cancelView.displayedDetail?.row.id == "second" }
            let beforeCancel = try jobStore.jobs().count
            cancelView.confirmReprocess()
            cancelView.confirmRename()
            let originalDoorway = try vault.versionOfMarkdown(relativePath: "Meetings/second/meeting.md")
            precondition(originalDoorway != nil && cancelView.selectedID == "second",
                         "Cancel Rename must leave Meeting and selection intact")
            let afterCancel = try jobStore.jobs().count
            precondition(afterCancel == beforeCancel && cancelView.selectedID == "second",
                         "Cancel must not queue work or change Meeting selection")
            cancelView.refresh(isVisible: false)

            let renameView = MeetingFixtureProviders.make(serviceProvider: {
                MeetingManagementService(vault: vault, jobStore: jobStore)
            }, presentConfirmationAlert: { alert in
                precondition(alert.informativeText.contains("outside Stillmatter"),
                             "Rename confirmation must warn about external links")
                (alert.accessoryView as? NSTextField)?.stringValue = "Renamed second"
                return .alertFirstButtonReturn
            })
            print("TASK09_MEETING cancel passed"); fflush(stdout)
            renameView.refresh(isVisible: true)
            await waitForMeetingFixture("rename browser") { !renameView.rows.isEmpty }
            let renameIndex = renameView.rows.firstIndex(where: { $0.id == "second" })!
            renameView.table.selectRowIndexes(IndexSet(integer: renameIndex), byExtendingSelection: false)
            renameView.show(row: renameIndex)
            await waitForMeetingFixture("rename detail") { renameView.displayedDetail?.row.id == "second" }
            renameView.confirmRename()
            await waitForMeetingFixture("rename mutation") { renameView.status.stringValue == "Meeting renamed." && renameView.rows.contains { $0.title == "Renamed second" } }
            precondition(renameView.selectedID == "second" && renameView.status.stringValue == "Meeting renamed." &&
                         renameView.rows.contains(where: { $0.id == "second" && $0.title == "Renamed second" }),
                         "Confirmed Rename must preserve selection and display the new title")
            let removedDoorway = try vault.versionOfMarkdown(relativePath: "Meetings/second/meeting.md")
            precondition(removedDoorway == nil, "Confirmed Rename must remove the old path")
            renameView.refresh(isVisible: false)

            let archiveView = MeetingFixtureProviders.make(serviceProvider: {
                MeetingManagementService(vault: vault)
            })
            print("TASK09_MEETING rename passed"); fflush(stdout)
            archiveView.refresh(isVisible: true)
            await waitForMeetingFixture("archive browser") { !archiveView.rows.isEmpty }
            let archiveIndex = archiveView.rows.firstIndex(where: { $0.id == "first" })!
            archiveView.table.selectRowIndexes(IndexSet(integer: archiveIndex), byExtendingSelection: false)
            archiveView.show(row: archiveIndex)
            await waitForMeetingFixture("archive detail") { archiveView.displayedDetail?.row.id == "first" }
            archiveView.archiveButton.performClick(nil)
            await waitForMeetingFixture("archive mutation") { !archiveView.rows.contains { $0.id == "first" } }
            precondition(!archiveView.rows.contains(where: { $0.id == "first" }),
                         "Archive must hide the Meeting from the current list")
            archiveView.archiveFilter.selectItem(at: 1)
            archiveView.filtersChanged(archiveView.archiveFilter)
            await waitForMeetingFixture("archived filter") { archiveView.rows.map(\.id) == ["first"] && archiveView.displayedDetail?.row.isArchived == true }
            precondition(archiveView.rows.map(\.id) == ["first"] &&
                         archiveView.displayedDetail?.row.isArchived == true &&
                         archiveView.archiveButton.title == "Restore",
                         "Archived filter must expose the Meeting detail and Restore")
            archiveView.archiveButton.performClick(nil)
            await waitForMeetingFixture("restore mutation") { archiveView.archiveFilter.indexOfSelectedItem == 0 && archiveView.selectedID == "first" && archiveView.rows.contains { $0.id == "first" && !$0.isArchived } }
            precondition(archiveView.archiveFilter.indexOfSelectedItem == 0 &&
                         archiveView.selectedID == "first" &&
                         archiveView.rows.contains(where: { $0.id == "first" && !$0.isArchived }),
                         "Restore must return the same Meeting to the current list and selection")
            archiveView.refresh(isVisible: false)
            print("TASK09_MEETING archive/restore passed"); fflush(stdout)

            selectionView.refresh(isVisible: false)
            precondition(selectionView.evidenceRows.arrangedSubviews.isEmpty && selectionView.audioPlayer == nil,
                         "Leaving Meetings must remove evidence controls and stop audio")
    }
}
#endif
