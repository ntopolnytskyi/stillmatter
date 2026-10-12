#if DEBUG || STILLMATTER_NATIVE_PROBES
import AppKit
import Darwin
import StillmatterCore
import StillmatterPresentation

extension ShellViewController {
    /// One-shot real review button and filesystem delivery probe, only with disposable roots.
    func validateTask04Acceptance(in window: NSWindow, workspace: URL, inbox: TasksInbox,
                                  completion: @escaping () -> Void) {
        precondition(window.isVisible && window.contentViewController === self,
                     "Task 04 acceptance must exercise the actual visible AppKit window")
        func until(_ name: String, deadline: Date = Date().addingTimeInterval(12),
                   _ predicate: @escaping () -> Bool, then: @escaping () -> Void) {
            if predicate() { then(); return }
            precondition(Date() < deadline, "Task 04 acceptance timed out: \(name)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { until(name, deadline: deadline, predicate, then: then) }
        }
        let proposalID = "meeting-action:synthetic-audio:task04-accept"
        let title = "Task 04 accepted item"
        stateStore.state.select(.meetings)
        meetingManagementView.prepareCaptionLayoutFixture { [self] in
            precondition(meetingManagementView.task04ProposalStateForValidation() == .pending &&
                         meetingManagementView.task04BrowserNeedsReviewForValidation() == true,
                         "Seeded proposal must appear in selected Meeting detail and browser")
            let beforeBrowserReads = meetingReadModelProvider()?.browserProjectionReadCountForValidation ?? -1
            stateStore.state.select(.today)
            until("visible pending proposal", { self.proposalReviewView.pendingTitlesForValidation == [title] &&
                  self.todayWorkbenchView.renderCountForValidation > 0 }) { [self] in
                let beforeToday = todayWorkbenchView.renderCountForValidation
                let beforeTasks = todoLedgerView.renderCountForValidation
                proposalReviewView.acceptFirstForValidation() // Actual enabled AppKit Accept button -> reviewer.
                until("Todo written and Today reloaded", {
                    (try? inbox.proposalReviewState(id: proposalID)) == .accepted &&
                    self.todayWorkbenchView.renderCountForValidation > beforeToday
                }) { [self] in
                    do {
                        let contents = try String(contentsOf: workspace.appendingPathComponent("Todos/todo.md"), encoding: .utf8)
                        let rows = try TodoItemIndex(workspaceRootURL: workspace).loadTaskViews(today: "2026-10-21").queue
                        let pending = try inbox.pendingProposal(id: proposalID)
                        precondition(rows.filter { $0.title == title }.count == 1 &&
                                     contents.components(separatedBy: title).count == 2 && pending == nil,
                                     "Accept must create exactly one canonical Todo and remove pending proposal")
                    } catch { preconditionFailure("Acceptance canonical verification: \(error)") }
                    precondition(todoLedgerView.renderCountForValidation == beforeTasks,
                                 "Acceptance must not repaint hidden Tasks")
                    stateStore.state.select(.tasks)
                    until("Tasks projection includes accepted item", {
                        self.todoLedgerView.visibleTitlesForValidation.contains(title)
                    }) { [self] in
                        stateStore.state.select(.meetings)
                        until("Meeting proposal state updated", {
                            self.meetingManagementView.task04ProposalStateForValidation() == .accepted &&
                            self.meetingManagementView.task04BrowserNeedsReviewForValidation() == false &&
                            (self.meetingReadModelProvider()?.browserProjectionReadCountForValidation ?? -1) > beforeBrowserReads
                        }) { [self] in
                            print("TASK04_ACCEPT UI accept canonical=1 proposal=accepted Today=\(todayWorkbenchView.renderCountForValidation - beforeToday) Tasks=1 Meeting reads=\((meetingReadModelProvider()?.browserProjectionReadCountForValidation ?? -1) - beforeBrowserReads)")
                            validateTask04ExternalEdits(in: window, workspace: workspace, completion: completion)
                        }
                    }
                }
            }
        }
    }

    private func writeTask04ExternalFile(_ text: String, to file: URL, workspace: URL) throws {
        precondition(file.standardizedFileURL.path.hasPrefix(workspace.standardizedFileURL.path + "/"),
                     "Only disposable workspace files may be edited")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = ["-c", "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text(sys.argv[2],encoding='utf-8')",
                           file.path, text]
        try child.run()
        child.waitUntilExit()
        precondition(child.terminationStatus == 0, "External writer must exit successfully")
    }

    private func validateTask04ExternalEdits(in window: NSWindow, workspace: URL,
                                             completion: @escaping () -> Void) {
        precondition(window.isVisible && window.contentViewController === self,
                     "External edits must reach the still-visible owner without navigation")
        func until(_ name: String, deadline: Date = Date().addingTimeInterval(12),
                   _ predicate: @escaping () -> Bool, then: @escaping () -> Void) {
            if predicate() { then(); return }
            precondition(Date() < deadline, "Task 04 external edit timed out: \(name)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { until(name, deadline: deadline, predicate, then: then) }
        }
        // Meetings use their own read-model monitor; never publish .meetings by hand.
        let meetingFile = workspace.appendingPathComponent("Meetings/audio-fixture/meeting.md")
        let oldMeetingReads = meetingReadModelProvider()?.browserProjectionReadCountForValidation ?? -1
        _ = meetingManagementView.prepareNarrowStateForValidation()
        do {
            let text = try String(contentsOf: meetingFile, encoding: .utf8)
            precondition(text.contains("Synthetic Audio Fixture"))
            try writeTask04ExternalFile(text.replacingOccurrences(of: "Synthetic Audio Fixture",
                with: "Task 04 external Meeting"), to: meetingFile, workspace: workspace)
        } catch { preconditionFailure("Could not edit disposable Meeting: \(error)") }
        until("Meeting monitor refreshes selected detail", {
            self.meetingManagementView.selectedTitleForValidation == "Task 04 external Meeting" &&
            self.meetingManagementView.task04BrowserTitleForValidation == "Task 04 external Meeting" &&
            (self.meetingReadModelProvider()?.browserProjectionReadCountForValidation ?? -1) > oldMeetingReads
        }) { [self] in
            precondition(meetingManagementView.hasDirtyNotesForValidation &&
                         meetingManagementView.task04ProposalStateForValidation() == .accepted,
                         "External Meeting edit must retain unsaved notes/review and not reload other features")
            meetingManagementView.verifyNarrowStateForValidation(id: "synthetic-audio")
            print("TASK04_EXTERNAL Meeting monitor updated selected detail without navigation; notes draft retained")
            stateStore.state.select(.today)
            let todo = workspace.appendingPathComponent("Todos/todo.md")
            let beforeTodo = todayWorkbenchView.renderCountForValidation
            let beforeMeetingTodo = meetingManagementView.refreshCountForValidation
            var taskEvents = 0
            let token = stateStore.observe([.tasks]) { _ in taskEvents += 1 }
            do {
                let prior = try String(contentsOf: todo, encoding: .utf8)
                try writeTask04ExternalFile(prior + "\n- [ ] External subprocess Todo\n",
                    to: todo, workspace: workspace)
            } catch { preconditionFailure("Could not externally edit disposable Todo: \(error)") }
            until("external subprocess Todo edit refreshes Today", {
                taskEvents > 0 && self.todayWorkbenchView.renderCountForValidation > beforeTodo
            }) { [self] in
                token.cancel()
                precondition(meetingManagementView.refreshCountForValidation == beforeMeetingTodo,
                             "External Todo must not reload Meeting")
                print("TASK04_EXTERNAL Todo subprocess .tasks refreshed visible Today without navigation")
                validateTask04WorkspaceSearchRace(workspace: workspace, completion: completion)
            }
        }
    }

    private func validateTask04WorkspaceSearchRace(workspace: URL, completion: @escaping () -> Void) {
        func until(_ name: String, deadline: Date = Date().addingTimeInterval(10),
                   _ predicate: @escaping () -> Bool, then: @escaping () -> Void) {
            if predicate() { then(); return }
            precondition(Date() < deadline, "Task 04 real workspace search race timed out: \(name)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { until(name, deadline: deadline, predicate, then: then) }
        }
        let secondRoot = workspace.deletingLastPathComponent().appendingPathComponent("workspace-B")
        let support = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"]!)
        do {
            for (root, suffix) in [(workspace, "OLD"), (secondRoot, "NEW")] {
                let todo = root.appendingPathComponent("Todos/switch.md")
                try FileManager.default.createDirectory(at: todo.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "# Switch\n\n- [ ] switchprobe \(suffix)\n".write(to: todo, atomically: true, encoding: .utf8)
            }
            let oldIndex = try SearchIndex(databaseURL: support.appendingPathComponent("switch-old.sqlite"), workspaceRootURL: workspace)
            let newIndex = try SearchIndex(databaseURL: support.appendingPathComponent("switch-new.sqlite"), workspaceRootURL: secondRoot)
            try oldIndex.rebuild()
            try newIndex.rebuild()
            let oldTitles = try oldIndex.search("switchprobe").map(\.title)
            let newTitles = try newIndex.search("switchprobe").map(\.title)
            precondition(oldTitles == ["switchprobe OLD"] && newTitles == ["switchprobe NEW"],
                         "Both disposable Search Indexes must contain distinct actual canonical rows")
            let gate = DispatchSemaphore(value: 0)
            let lock = NSLock()
            var started = false
            searchIndexProvider = { oldIndex }
            searchRunner = { index, query, filter in
                let result = try index.search(query, filter: filter, limit: 100)
                if index === oldIndex {
                    lock.lock(); started = true; lock.unlock()
                    gate.wait() // Hold a completed old-root read until after the new-root result.
                }
                return result
            }
            stateStore.state.select(.today)
            stateStore.state.searchText = "switchprobe"
            isSearchPresented = true
            render()
            until("old workspace read started", { lock.lock(); defer { lock.unlock() }; return started }) { [self] in
                searchIndexProvider = { newIndex }
                settingsStore.settings.stillmatterRootURL = secondRoot // Real scoped settings/workspace change.
                until("new workspace indexed result displayed", {
                    self.searchResultsView.resultTitlesForValidation == ["switchprobe NEW"]
                }) { [self] in
                    gate.signal()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                        precondition(searchResultsView.resultTitlesForValidation == ["switchprobe NEW"] &&
                                     settingsStore.settings.stillmatterRootURL == secondRoot,
                                     "Old indexed workspace completion must not replace the new workspace result")
                        print("TASK04_SEARCH actual indexed OLD completion rejected after settings switched to NEW root")
                        completion()
                    }
                }
            }
        } catch { preconditionFailure("Could not set up two disposable workspace indexes: \(error)") }
    }

    /// Disposable actual-window acceptance probe. Runs only under STILLMATTER_TASK04_HARNESS.
    func validateTask04Harness(in window: NSWindow, workspace: URL, completion: @escaping () -> Void) {
        func until(_ name: String, deadline: Date = Date().addingTimeInterval(8),
                   _ predicate: @escaping () -> Bool, then: @escaping () -> Void) {
            if predicate() { then(); return }
            precondition(Date() < deadline, "Task 04 fixture timed out: \(name)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                until(name, deadline: deadline, predicate, then: then)
            }
        }
        stateStore.state.select(.today)
        until("initial Today projection", { self.todayWorkbenchView.renderCountForValidation > 0 }) { [self] in
            let initialToday = todayWorkbenchView.renderCountForValidation
            let initialMeeting = meetingManagementView.refreshCountForValidation
            for _ in 0..<10 {
                stateStore.publish(.recordingStatus)
                stateStore.publish(.jobStatus)
                stateStore.publish(.teamsStatus)
            }
            precondition(todayWorkbenchView.renderCountForValidation == initialToday &&
                         meetingManagementView.refreshCountForValidation == initialMeeting,
                         "Compact status must not rebuild Today or refresh Meetings")
            print("TASK04 status today=\(initialToday) meetingRefresh=\(initialMeeting) unchanged")
            // Today deliberately suppresses identical projections. Give the task
            // event a real canonical change rather than demanding a no-op repaint.
            let todo = workspace.appendingPathComponent("Todos/todo.md")
            do {
                try FileManager.default.createDirectory(at: todo.deletingLastPathComponent(), withIntermediateDirectories: true)
                try "# Todo\n\n## Queue\n- [ ] Task 04 changed Todo projection\n".write(to: todo, atomically: true, encoding: .utf8)
            } catch { preconditionFailure("Could not seed disposable task change: \(error)") }
            stateStore.publish(.tasks)
            until("task event refreshes Today", { self.todayWorkbenchView.renderCountForValidation > initialToday }) { [self] in
                precondition(meetingManagementView.refreshCountForValidation == initialMeeting,
                             "Task event must not broadcast a Meeting view refresh")
                print("TASK04 tasks today=\(todayWorkbenchView.renderCountForValidation) meetingRefresh unchanged")
                stateStore.state.select(.tasks)
                until("initial Tasks projection", { self.todoLedgerView.renderCountForValidation > 1 }) { [self] in
                    let tasksBefore = todoLedgerView.renderCountForValidation
                    let todayBefore = todayWorkbenchView.renderCountForValidation
                    let meetingsBefore = meetingManagementView.refreshCountForValidation
                    stateStore.publish(.tasks)
                    until("task event refreshes Tasks", { self.todoLedgerView.renderCountForValidation > tasksBefore }) { [self] in
                        precondition(todayWorkbenchView.renderCountForValidation == todayBefore &&
                                     meetingManagementView.refreshCountForValidation == meetingsBefore,
                                     "Tasks mutation must not repaint hidden Today or Meetings")
                        print("TASK04 tasks visible ledger=\(todoLedgerView.renderCountForValidation) Today and Meetings unchanged")
                        stateStore.state.select(.meetings)
                        meetingManagementView.prepareCaptionLayoutFixture { [self] in
                    let meetingReads = meetingReadModelProvider()?.browserProjectionReadCountForValidation ?? -1
                    let meetingRefreshes = meetingManagementView.refreshCountForValidation
                    let todayRenders = todayWorkbenchView.renderCountForValidation
                    for _ in 0..<10 { stateStore.publish(.recordingStatus); stateStore.publish(.jobStatus) }
                    precondition(meetingReadModelProvider()?.browserProjectionReadCountForValidation == meetingReads &&
                                 meetingManagementView.refreshCountForValidation == meetingRefreshes &&
                                 todayWorkbenchView.renderCountForValidation == todayRenders,
                                 "Recording/Job ticks must not read Meetings or rebuild Today")
                    print("TASK04 loaded Meeting browser reads=\(meetingReads) refreshes=\(meetingRefreshes) Today renders=\(todayRenders) unchanged")
                    prepareForWindowResize(to: 720)
                    window.setFrame(NSRect(origin: window.frame.origin, size: AppDelegate.minimumWindowFrameSize), display: true)
                    window.layoutIfNeeded()
                    applyAdaptiveLayout()
                    precondition(lastAdaptiveLayout?.detailMode == .listOnly,
                                 "Compact Meeting layout must start in list mode")
                    let selectedMeetingID = meetingManagementView.prepareNarrowStateForValidation()
                    meetingManagementView.openSelectionForValidation()
                    precondition(!narrowBackButton.isHidden && !detailContainer.isHidden,
                                 "Opening compact Meeting selection must show detail and Back")
                    showNarrowList(nil)
                    precondition(!contentListContainer.isHidden && detailContainer.isHidden,
                                 "Back must return to Meeting browser")
                    meetingManagementView.verifyNarrowStateForValidation(id: selectedMeetingID)
                    print("TASK04 narrow Meeting selection=\(selectedMeetingID), notes draft and Transcript page retained across Back")
                    prepareForWindowResize(to: 1200)
                    window.setContentSize(NSSize(width: 1200, height: 760))
                    window.layoutIfNeeded()
                    applyAdaptiveLayout()
                    stateStore.state.select(.today)
                // An actual native search results table and focused field must survive status events.
                stateStore.state.searchText = "fixture"
                isSearchPresented = true
                render()
                let fixture = SearchResult(kind: .todo, sourcePath: "Todos/todo.md",
                    title: "Disposable task", body: "Status must not replace this result")
                searchResultsView.render(query: "fixture", scope: "Today", type: "All types", state: .results([fixture]))
                precondition(window.makeFirstResponder(searchField), "Search field must accept focus")
                let before = searchResultsView.resultCountForValidation
                stateStore.publish(.jobStatus)
                stateStore.publish(.teamsStatus)
                precondition(searchControlHasFocus(searchField) &&
                             searchResultsView.resultCountForValidation == before,
                             "Background status must preserve Search focus and results")
                print("TASK04 search focus and \(before) results preserved")
                validateTask04SearchRace { [self] in
                isSearchPresented = false
                stateStore.state.searchText = ""
                render()
                let observers = stateStore.observerCount
                let settingsObservers = settingsStore.observerCount
                for _ in 0..<12 {
                    stateStore.state.select(.meetings)
                    stateStore.state.select(.today)
                }
                precondition(stateStore.observerCount == observers && settingsStore.observerCount == settingsObservers,
                             "Repeated feature activation must not duplicate shell subscriptions")
                print("TASK04 activation observers=\(observers) settings=\(settingsObservers) stable")
                stateStore.state.select(.today)
                // Exercise the real workspace FSEvents monitor rather than publishing its event manually.
                let todo = workspace.appendingPathComponent("Todos/todo.md")
                var externalTaskEvents = 0
                let externalObservation = stateStore.observe([.tasks]) { _ in externalTaskEvents += 1 }
                do {
                    try FileManager.default.createDirectory(at: todo.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try "# Todo\n\n## Queue\n- [ ] External Task 04 fixture\n".write(to: todo, atomically: true, encoding: .utf8)
                } catch { preconditionFailure("Could not edit disposable Todo: \(error)") }
                let beforeExternal = todayWorkbenchView.renderCountForValidation
                let meetingBeforeExternal = meetingManagementView.refreshCountForValidation
                until("external Todo edit refreshes Today", deadline: Date().addingTimeInterval(12),
                      { externalTaskEvents > 0 && self.todayWorkbenchView.renderCountForValidation > beforeExternal }) { [self] in
                    externalObservation.cancel()
                    precondition(meetingManagementView.refreshCountForValidation == meetingBeforeExternal,
                                 "External Todo edit must not refresh Meetings beyond explicit navigation")
                    print("TASK04 external Todo .tasks events=\(externalTaskEvents); Today renders=\(todayWorkbenchView.renderCountForValidation)")
                    completion()
                        }
                    }
                }
                        }
                }
            }
        }
    }

    private func validateTask04SearchRace(completion: @escaping () -> Void) {
        let gate = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var started = false
        let old = SearchResult(kind: .transcript, sourcePath: "Meetings/old/transcript.json",
                               title: "STALE A", body: "Must never display")
        let latest = SearchResult(kind: .transcript, sourcePath: "Meetings/current/transcript.json",
                                  title: "CURRENT B", body: "Must remain visible")
        searchRunner = { _, query, _ in
            if query == "stale-A" {
                lock.lock(); started = true; lock.unlock()
                gate.wait()
                return [old]
            }
            return [latest]
        }
        func until(_ label: String, deadline: Date = Date().addingTimeInterval(6),
                   _ predicate: @escaping () -> Bool, then: @escaping () -> Void) {
            if predicate() { then(); return }
            precondition(Date() < deadline, "Task 04 search race timed out: \(label)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                until(label, deadline: deadline, predicate, then: then)
            }
        }
        stateStore.state.searchText = "stale-A"
        until("old query started", { lock.lock(); defer { lock.unlock() }; return started }) { [self] in
            stateStore.state.searchText = "current-B"
            stateStore.state.select(.meetings)
            receive(.workspace) // Invalidate the request generation as on a workspace change.
            until("new scope result", { self.searchResultsView.resultTitlesForValidation == ["CURRENT B"] &&
                  self.searchResultsView.contextForValidation.contains("Scope: Meetings") }) { [self] in
                gate.signal()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [self] in
                    precondition(searchResultsView.resultTitlesForValidation == ["CURRENT B"] &&
                                 searchResultsView.contextForValidation.contains("Scope: Meetings"),
                                 "Old query/scope/workspace completion must not replace new results")
                    print("TASK04 stale A rejected after B + scope/workspace revision")
                    searchRunner = { try $0.search($1, filter: $2, limit: 100) }
                    completion()
                }
            }
        }
    }

}
#endif
