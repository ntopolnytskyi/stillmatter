#if DEBUG
import AppKit
import Darwin
import StillmatterCore
import StillmatterPresentation

extension AppDelegate {
    func runTask05NativeRegressionProbe() {
        let env = ProcessInfo.processInfo.environment
        let first = URL(fileURLWithPath: env["STILLMATTER_VALIDATION_WORKSPACE_ROOT"]!, isDirectory: true)
        let next = first.deletingLastPathComponent().appendingPathComponent("workspace-next", isDirectory: true)
        let owner = first.standardizedFileURL.resolvingSymlinksInPath().path
        let nextOwner = next.standardizedFileURL.resolvingSymlinksInPath().path
        precondition(env["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] != nil &&
                     env["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] != nil &&
                     FileManager.default.fileExists(atPath: next.path))
        let shell = mainWindow!.contentViewController as! ShellViewController
        let view = shell.task05MeetingView
        var choices: [NSApplication.ModalResponse] = []
        var prompts: [String] = []
        view.task05AlertResponse = { alert in
            prompts.append(alert.messageText)
            precondition(!choices.isEmpty, "Unexpected native alert: \(alert.messageText)")
            return choices.removeFirst()
        }
        func wait(_ condition: @escaping () -> Bool, _ label: String, then: @escaping () -> Void) {
            if condition() { then(); return }
            // Only yield to the main executor: no timer/sleep governs an assertion or completion.
            if Date() >= deadline {
                print("TASK05_DIAG \(label) effective=\(self.effectiveWorkspacePath ?? "nil") visible=\(view.task05VisibleTitles) rendered=\(view.task05RenderedIDs) detail=\(view.selectedTitleForValidation ?? "nil") \(view.task05SelectionDiagnostic)")
                fflush(stdout)
                preconditionFailure("Task 05 regression stalled: \(label)")
            }
            DispatchQueue.main.async { wait(condition, label, then: then) }
        }
        let deadline = Date().addingTimeInterval(30) // failure watchdog, not synchronization
        func waitDetail(_ title: String, _ label: String, then: @escaping () -> Void) {
            wait({
                if view.selectedTitleForValidation == title { return true }
                view.task05RecoverDetailIfFailed()
                return false
            }, label, then: then)
        }
        func select(_ url: URL) {
            settingsStore.requestWorkspace(.init(root: url, media: settingsStore.settings.recordingMediaURL))
            retryPendingWorkspace()
        }
        func assertA(_ marker: String) {
            precondition(effectiveWorkspacePath == owner && settingsStore.settings.stillmatterRootURL == first &&
                         view.hasDirtyNotesForValidation && settingsStore.pendingWorkspace == nil)
            view.task05Assert("same", title: "A original", draft: marker)
        }
        wait({ self.effectiveWorkspacePath == owner }, "startup") { [self] in
            view.refresh(isVisible: true)
            wait({ view.task05RenderedIDs.contains("same") && view.task05CanReadDetail }, "A browser") {
                view.task05Select("same")
                waitDetail("A original", "A detail") { [self] in
                    view.task05EditNotes(" CANCEL-MARKER")
                    choices = [.alertThirdButtonReturn]
                    select(next)
                    wait({ self.settingsStore.pendingWorkspace == nil }, "cancel") {
                        assertA("CANCEL-MARKER")
                        precondition(prompts.removeLast() == "Save Meeting edits before changing workspace?")
                        view.refresh(isVisible: false)
                        view.refresh(isVisible: true) // hidden/reopened while draft is retained
                        choices = [.alertFirstButtonReturn, .alertSecondButtonReturn]
                        let gate = self.task05MeetingGate!
                        gate.failNext = true
                        select(next)
                        wait({ self.settingsStore.pendingWorkspace == nil && prompts.count >= 2 }, "failed save") {
                            assertA("CANCEL-MARKER")
                            precondition(prompts.suffix(2) == ["Save Meeting edits before changing workspace?", "Could not save Meeting edits"])
                            gate.holdCompletion = true
                            choices = [.alertFirstButtonReturn]
                            select(next)
                            wait({ gate.pending != nil }, "real A write completed") {
                                let text = try! String(contentsOf: first.appendingPathComponent("Meetings/same/meeting.md"), encoding: .utf8)
                                precondition(text.contains("CANCEL-MARKER"), "Save must persist to A")
                                precondition(self.effectiveWorkspacePath == owner && self.settingsStore.pendingWorkspace?.root == next,
                                             "B cannot become effective before save callback")
                                gate.release()
                                wait({ self.effectiveWorkspacePath == nextOwner }, "save activation") {
                                    precondition(!view.hasDirtyNotesForValidation)
                                    wait({ view.task05VisibleTitles.contains("B same") && view.task05RenderedIDs.contains("same") && view.task05CanReadDetail }, "B browser") {
                                        view.task05Select("same")
                                        view.task05RetryDetail()
                                        waitDetail("B same", "B detail") {
                                            view.task05Assert("same", title: "B same")
                                            precondition(Set(view.task05RenderedIDs) == ["same", "deleted"], "B must initially contain the soon-deleted row")
                                            select(first)
                                            wait({ self.effectiveWorkspacePath == owner && view.task05VisibleTitles.contains("A original") && view.task05RenderedIDs.contains("same") && view.task05CanReadDetail }, "return A") {
                                                view.task05Select("same")
                                                view.task05RetryDetail()
                                                waitDetail("A original", "return A detail") {
                                                    view.task05EditNotes(" DISCARD-MARKER")
                                                    choices = [.alertSecondButtonReturn]
                                                    select(next)
                                                    wait({ self.effectiveWorkspacePath == nextOwner }, "discard activation") {
                                                        precondition(prompts.last == "Save Meeting edits before changing workspace?" &&
                                                                     !view.hasDirtyNotesForValidation)
                                                        let saved = try! String(contentsOf: first.appendingPathComponent("Meetings/same/meeting.md"), encoding: .utf8)
                                                        precondition(!saved.contains("DISCARD-MARKER"))
                                                        // Hold the actual view's deferred snapshot callback while AppKit still has A/B cells.
                                                        DispatchQueue.main.async {
                                                        view.task05HoldRenders = true
                                                        select(first)
                                                        precondition(view.task05VisibleIDs.isEmpty, "Workspace install must clear live projection")
                                                        wait({ view.task05PendingRenders > 0 }, "empty A render") {
                                                        view.task05DeliverRenders()
                                                        view.task05AssertEmpty()
                                                        wait({ view.task05VisibleTitles.contains("A original") && view.task05CanReadDetail }, "A projection") {
                                                            view.task05DeliverRenders()
                                                            view.task05Select("same")
                                                            view.task05RetryDetail()
                                                            waitDetail("A original", "A reselect") {
                                                                // Delete B's extra row before the second B read; its surviving
                                                                // colliding ID now has A's row count but a different detail.
                                                                try! FileManager.default.removeItem(at: next.appendingPathComponent("Meetings/deleted/meeting.md"))
                                                                select(next)
                                                                precondition(view.task05VisibleIDs.isEmpty)
                                                                wait({ view.task05PendingRenders > 0 }, "empty B render") {
                                                                view.task05DeliverRenders()
                                                                view.task05AssertEmpty()
                                                                wait({ view.task05VisibleTitles.contains("B same") && view.task05CanReadDetail }, "reordered B projection") {
                                                                    view.task05DeliverRenders()
                                                                    precondition(view.task05RenderedIDs == view.task05VisibleIDs)
                                                                    view.task05Select("same")
                                                                    view.task05RetryDetail()
                                                                    waitDetail("B same", "B reselect") {
                                                                        view.task05DeliverRenders()
                                                                        view.task05Assert("same", title: "B same")
                                                                        precondition(view.task05RenderedIDs == ["same"], "Deleted B row must not survive deferred layout")
                                                                        precondition(choices.isEmpty)
                                                                        print("TASK05_REGRESSION dirty decisions, persisted save gate, failure retry, deferred AppKit identity passed")
                                                                        fflush(stdout)
                                                                        self.quit(nil)
                                                                    }
                                                                }
                                                                }
                                                            }
                                                        }
                                                        }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func runTask05NativeLifecycleProbe() {
        let env = ProcessInfo.processInfo.environment
        guard let mode = env["STILLMATTER_TASK05_LIFECYCLE"], ["first", "restart"].contains(mode),
              let rootPath = env["STILLMATTER_VALIDATION_WORKSPACE_ROOT"],
              let mediaPath = env["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"],
              let supportPath = env["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] else {
            fatalError("Task 05 native probe requires three isolated roots and first/restart mode")
        }
        let base = URL(fileURLWithPath: rootPath).deletingLastPathComponent()
        let first = URL(fileURLWithPath: rootPath, isDirectory: true)
        let next = base.appendingPathComponent("workspace-next", isDirectory: true)
        let missing = base.appendingPathComponent("missing-destination", isDirectory: true)
        precondition(!FileManager.default.fileExists(atPath: missing.path) &&
                     mediaPath.hasPrefix(base.path + "/") && supportPath.hasPrefix(base.path + "/") &&
                     FileManager.default.fileExists(atPath: next.path), "Task 05 roots must be disposable siblings")
        let owner = first.standardizedFileURL.resolvingSymlinksInPath().path
        let nextOwner = next.standardizedFileURL.resolvingSymlinksInPath().path
        let deadline = Date().addingTimeInterval(25)
        func wait(_ condition: @escaping () -> Bool, _ explanation: String, then: @escaping () -> Void) {
            if condition() { then(); return }
            precondition(Date() < deadline, "Task 05 native probe timed out: \(explanation)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { wait(condition, explanation, then: then) }
        }
        func select(_ url: URL) {
            settingsStore.requestWorkspace(.init(root: url, media: settingsStore.settings.recordingMediaURL))
            retryPendingWorkspace()
        }
        func finish(_ label: String) {
            print("TASK05_NATIVE \(label)")
            fflush(stdout)
            quit(nil) // Actual NSApplication termination policy and applicationWillTerminate barrier.
        }
        wait({ self.captureService != nil && self.effectiveWorkspacePath != nil }, "normal startup") { [self] in
            precondition(settingsStore.settings.calendarSourceSelection.mode == .none)
            precondition(mainWindow?.isVisible == true && jobStore != nil && tasksInbox != nil)
            if mode == "restart" {
                precondition(effectiveWorkspacePath == owner && settingsStore.pendingWorkspace == nil,
                    "A pending destination must not be applied on restart")
                let records = try! jobStore!.jobs()
                precondition(records.contains { $0.manifest.workspaceOwner == owner }, "Old Jobs must survive quit")
                precondition((try? jobStore?.job(id: "task05-late-old")?.status) == .queued &&
                             (try? jobStore?.job(id: "task05-late-old")?.manifest.workspaceOwner) == owner)
                precondition((try? jobStore?.job(id: "task05-draining")?.status) == .succeeded)
                precondition(records.allSatisfy { $0.manifest.workspaceOwner != nextOwner || $0.manifest.type != "meeting-capture-placeholder" })
                finish("restart restored effective workspace, no pending switch, old Jobs durable")
                return
            }
            precondition(effectiveWorkspacePath == owner)
            select(next)
            precondition(effectiveWorkspacePath == nextOwner, "Idle switch must install B synchronously")
            select(first)
            precondition(effectiveWorkspacePath == owner)
            print("TASK05_NATIVE normal startup and idle A-B-A switch passed")
            fflush(stdout)
            let syntheticTeamsCall = TeamsDetectionService().observe(.activeMeetingForTesting)
            teamsAutomation.observeFixture(syntheticTeamsCall)
            precondition(teamsAutomation.hasPendingFixtureAsk, "Confirmed fake call must offer native Ask")
            teamsAutomation.manualOverride()
            precondition(!teamsAutomation.hasPendingFixtureAsk && captureService?.snapshot.state == .idle,
                         "Manual override must revoke pending consent without recording")
            print("TASK05_NATIVE synthetic Teams Ask and manual revocation passed")
            fflush(stdout)
            let capture = captureService!
            _ = try! capture.startManual(titleHint: "Synthetic failed finalization")
            precondition(settingsStore.workspaceChangeHeld)
            settingsStore.requestWorkspace(.init(root: next, media: settingsStore.settings.recordingMediaURL))
            precondition(effectiveWorkspacePath == owner && settingsStore.pendingWorkspace?.root == next)
            settingsStore.cancelPendingWorkspace()
            settingsStore.requestWorkspace(.init(root: missing, media: settingsStore.settings.recordingMediaURL))
            settingsStore.requestWorkspace(.init(root: next, media: settingsStore.settings.recordingMediaURL))
            task05Microphone.failNextStop = true
            capture.stopManualAsync { [self] result in
                guard case .failure = result else { preconditionFailure("Fake finalization must fail") }
                precondition(effectiveWorkspacePath == owner && settingsStore.pendingWorkspace?.root == next &&
                             settingsStore.workspaceChangeHeld && capture.snapshot.state == .failed)
                _ = try! capture.startManual(titleHint: "Synthetic durable handoff")
                task05Microphone.holdNextStop()
                capture.stopManualAsync { [self] result in
                    guard case let .success(job) = result, let job else { preconditionFailure("Fake handoff must persist") }
                    precondition(job.manifest.workspaceOwner == owner &&
                                 (try? jobStore?.job(id: job.id))?.manifest.workspaceOwner == owner)
                    wait({ self.effectiveWorkspacePath == nextOwner }, "durable handoff switch") { [self] in
                        precondition(settingsStore.pendingWorkspace == nil)
                        precondition(currentJobRecords()?.allSatisfy { $0.manifest.workspaceOwner == nextOwner } == true)
                        select(missing)
                        precondition(effectiveWorkspacePath == nextOwner && settingsStore.pendingWorkspace?.root == missing)
                        settingsStore.cancelPendingWorkspace()
                        // A late old-owner notification cannot enter B's visible processing list
                        // or publish Job status to the new workspace's Shell.
                        var stalePublications = 0
                        let observation = stateStore.observe([.jobStatus]) { _ in stalePublications += 1 }
                        _ = try! jobStore!.enqueue(id: "task05-late-old", manifest: JobManifest(
                            type: TranscriptionJob.type, title: "Synthetic old callback", executionClass: .heavy,
                            stages: [JobStageDefinition(id: "fake", title: "Fake")]).owned(by: first))
                        precondition(currentJobRecords()?.isEmpty == true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [self] in
                        precondition(stalePublications == 0, "Old Job must not publish B's Job status")
                        observation.cancel()
                        select(first)
                        precondition(effectiveWorkspacePath == owner)
                        let workerScheduler = JobScheduler(store: jobStore!, executor: task05Worker,
                            eligibleJobTypes: ["task05.fake"], workspaceRootURL: first,
                            heavyExecutionGate: heavyExecutionGate)
                        validationJobScheduler = workerScheduler
                        _ = try! workerScheduler.enqueue(id: "task05-draining", manifest: JobManifest(
                            type: "task05.fake", title: "Synthetic draining stage", executionClass: .heavy,
                            stages: [JobStageDefinition(id: "fake", title: "Fake")]).owned(by: first))
                        wait({ self.task05Worker.hasStarted("task05-draining") }, "fake worker start") { [self] in
                            workerScheduler.pauseSynchronously()
                            select(next)
                            precondition(effectiveWorkspacePath == owner && settingsStore.pendingWorkspace?.root == next,
                                         "Running old Job must block activation")
                            settingsStore.cancelPendingWorkspace()
                            settingsStore.requestWorkspace(.init(root: next, media: settingsStore.settings.recordingMediaURL))
                            retryPendingWorkspace()
                            precondition(effectiveWorkspacePath == owner)
                            task05Worker.finish("task05-draining")
                            wait({ self.effectiveWorkspacePath == nextOwner &&
                                   (try? self.jobStore?.job(id: "task05-draining")?.status) == .succeeded },
                                 "draining old Job and pending activation") { [self] in
                                select(first)
                                precondition(effectiveWorkspacePath == owner)
                                // An active fake capture pins a pending request until explicit quit.
                                _ = try! captureService!.startManual(titleHint: "Synthetic pending at quit")
                                settingsStore.requestWorkspace(.init(root: next, media: settingsStore.settings.recordingMediaURL))
                                precondition(settingsStore.workspaceChangeHeld &&
                                             settingsStore.settings.stillmatterRootURL == first)
                                print("TASK05_NATIVE fake worker drain, cancel/replace, old callback, and pending quit passed")
                                fflush(stdout)
                                finish("shutdown with pending switch")
                            }
                        }
                        print("TASK05_NATIVE failed finalization, durable handoff, old callbacks/draft, invalid destination passed")
                        fflush(stdout)
                        }
                    }
                }
                precondition(capture.snapshot.state == .stopping && effectiveWorkspacePath == owner)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [self] in
                    precondition(effectiveWorkspacePath == owner && settingsStore.pendingWorkspace?.root == next)
                    task05Microphone.releaseStop()
                }
            }
        }
    }

    func startDisposableRunningJobFixtureIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["STILLMATTER_VALIDATION_RUNNING_JOB"] == "1",
              let workspace = env["STILLMATTER_VALIDATION_WORKSPACE_ROOT"],
              let support = env["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"],
              let media = env["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"],
              URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath().path.contains("/.build/workbench-redesign/02-03-acceptance/"),
              URL(fileURLWithPath: support).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
                  URL(fileURLWithPath: workspace).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              URL(fileURLWithPath: media).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(
                  URL(fileURLWithPath: workspace).deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path + "/"),
              let jobStore else { return }
        validationJobScheduler = JobScheduler(store: jobStore, executor: MeetingValidationHeldJobExecutor(),
            eligibleJobTypes: ["validation-held"])
        validationJobScheduler?.start()
    }
}
#endif
