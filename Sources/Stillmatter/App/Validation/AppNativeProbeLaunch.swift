#if DEBUG || STILLMATTER_NATIVE_PROBES
import AppKit
import Darwin
import StillmatterCore
import StillmatterPresentation

extension AppDelegate {
    @MainActor
    func runValidationLaunchIfRequested() -> Bool {
        if ProcessInfo.processInfo.environment["STILLMATTER_TASK04_HARNESS"] == "1" {
            guard let root = settingsStore.settings.stillmatterRootURL,
                  ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] != nil,
                  ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] != nil else {
                fatalError("Task 04 harness requires all three isolated validation roots")
            }
            do {
                try indexRuntime.installFixtureIndex(databaseURL: Self.applicationSupportURL.appendingPathComponent("task04-search.sqlite"), root: root)
            } catch { fatalError("Could not open disposable Task 04 Search Index: \(error)") }
            if ProcessInfo.processInfo.environment["STILLMATTER_TASK04_ACCEPTANCE"] == "1" {
                guard let inbox = tasksInbox else { fatalError("Task 04 acceptance requires disposable Inbox") }
                let extractionURL = root.appendingPathComponent("Meetings/audio-fixture/summary-extraction.json")
                do {
                    let original = try JSONDecoder().decode(MeetingSummaryExtraction.self, from: Data(contentsOf: extractionURL))
                    let seeded = MeetingSummaryExtraction(meeting: original.meeting, transcript: original.transcript,
                        decisions: original.decisions,
                        myActionItems: [MeetingOutcome(id: "task04-accept", text: "Task 04 accepted item", citations: [])],
                        otherActionItems: original.otherActionItems, openQuestions: original.openQuestions)
                    try JSONEncoder().encode(seeded).write(to: extractionURL, options: .atomic)
                    let todo = root.appendingPathComponent("Todos/todo.md")
                    try FileManager.default.createDirectory(at: todo.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try "# Todos\n\n## Queue\n".write(to: todo, atomically: true, encoding: .utf8)
                    let queued = try inbox.queueProposal(id: "meeting-action:synthetic-audio:task04-accept",
                        title: "Task 04 accepted item", sourceRef: "[[Meetings/audio-fixture/summary#My action items|ref]]")
                    precondition(queued, "Task 04 acceptance fixture must start with a new pending proposal")
                } catch { fatalError("Could not seed isolated proposal: \(error)") }
            }
            configureMeetingReadModel(settings: settingsStore.settings)
            let window = makeMainWindow()
            mainWindow = window
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, let shell = window.contentViewController as? ShellViewController,
                      let root = self.settingsStore.settings.stillmatterRootURL,
                      ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] != nil,
                      ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] != nil else {
                    fatalError("Task 04 harness requires a disposable signed app and all three isolated roots")
                }
                if ProcessInfo.processInfo.environment["STILLMATTER_TASK04_ACCEPTANCE"] == "1" {
                    shell.validateTask04Acceptance(in: window, workspace: root, inbox: self.tasksInbox!) {
                        print("Task 04 acceptance and external-edit probe passed.")
                        fflush(stdout)
                        window.close()
                        Darwin.exit(EXIT_SUCCESS)
                    }
                    return
                }
                shell.validateTask04Harness(in: window, workspace: root) { [weak self, weak window] in
                    guard let self, let window else { fatalError("Task 04 fixture lost its window") }
                    window.contentViewController = nil
                    window.close()
                    self.mainWindow = nil
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        NSLog("TASK04 close observer counts shell=%ld settings=%ld", self.stateStore.observerCount, self.settingsStore.observerCount)
                        precondition(self.stateStore.observerCount == 0 && self.settingsStore.observerCount == 0,
                                     "Closing window must dispose its scoped observers")
                        let reopened = self.makeMainWindow()
                        self.mainWindow = reopened
                        reopened.makeKeyAndOrderFront(nil)
                        NSLog("TASK04 reopen observer counts shell=%ld settings=%ld", self.stateStore.observerCount, self.settingsStore.observerCount)
                        precondition(self.stateStore.observerCount == 2 && self.settingsStore.observerCount == 2,
                                     "Reopening window must install exactly one shell subscription set")
                        reopened.contentViewController = nil
                        reopened.close()
                        self.mainWindow = nil
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }
                            precondition(self.stateStore.observerCount == 0 && self.settingsStore.observerCount == 0,
                                         "Reclosed window must leave no callbacks")
                            print("TASK04 window close/reopen observers=0 -> 2/2 -> 0")
                            print("Task 04 scoped native harness passed.")
                            fflush(stdout)
                            Darwin.exit(EXIT_SUCCESS)
                        }
                    }
                }
            }
            return true
        }
        if ProcessInfo.processInfo.environment["STILLMATTER_TASK04_INDEX_LIFECYCLE"] == "1" {
            guard let oldRoot = settingsStore.settings.stillmatterRootURL,
                  let support = ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"],
                  ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] != nil else {
                fatalError("Index lifecycle probe requires three disposable validation roots")
            }
            let nextRoot = oldRoot.deletingLastPathComponent().appendingPathComponent("workspace-next")
            precondition(!FileManager.default.fileExists(atPath: nextRoot.path) &&
                         support.hasPrefix(oldRoot.deletingLastPathComponent().path + "/"),
                         "Next workspace and support must be fresh siblings of the fixture")
            do {
                let projects = nextRoot.appendingPathComponent("Projects")
                try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
                try "# Task04NewWorkspaceToken\n".write(to: projects.appendingPathComponent("General.md"),
                    atomically: true, encoding: .utf8)
                try FileManager.default.createDirectory(at: oldRoot.appendingPathComponent("Projects"),
                    withIntermediateDirectories: true)
                try "# Task04OldWorkspaceToken\n".write(to: oldRoot.appendingPathComponent("Projects/task04-old.md"),
                    atomically: true, encoding: .utf8)
            } catch { fatalError("Could not seed two synthetic workspaces: \(error)") }
            var settings = settingsStore.settings
            var expectedGeneration: Int?
            var switchObserved = false
            // Replay the production settings -> main-actor index configuration seam
            // without starting capture, schedulers or AI services in a fixture.
            settingsStore.observe { [weak self] changedSettings in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.indexRuntime.configure(changedSettings)
                    if changedSettings.stillmatterRootURL == nextRoot {
                        precondition(self.indexGeneration == expectedGeneration && self.searchIndex == nil,
                                     "Settings observer must invalidate OLD index before rebuilding")
                        switchObserved = true
                        print("TASK04_INDEX OLD indexed, settings observer invalidated old index")
                        fflush(stdout)
                    }
                }
            }
            let deadline = Date().addingTimeInterval(25)
            func waitForNewIndex() {
                if switchObserved, let index = searchIndex {
                    do {
                        let results = try index.search("Task04NewWorkspaceToken")
                        let oldResults = try index.search("Task04OldWorkspaceToken")
                        precondition(results.contains { $0.sourcePath == "Projects/General.md" } && oldResults.isEmpty,
                                     "App-managed index rebuild must deliver only the new workspace")
                    } catch { fatalError("Index lifecycle search failed: \(error)") }
                    print("TASK04_INDEX app-managed settings/index builder switched OLD to NEW")
                    fflush(stdout)
                    Darwin.exit(EXIT_SUCCESS)
                }
                precondition(Date() < deadline, "App-managed NEW index rebuild did not complete")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: waitForNewIndex)
            }
            func waitForOldIndex() {
                if let oldIndex = searchIndex {
                    do {
                        let oldResults = try oldIndex.search("Task04OldWorkspaceToken")
                        precondition(oldResults.contains { $0.sourcePath == "Projects/task04-old.md" },
                                     "App-managed OLD index must contain the old workspace fixture")
                    } catch { fatalError("Old index search failed: \(error)") }
                    expectedGeneration = indexGeneration + 1
                    settings.stillmatterRootURL = nextRoot
                    settingsStore.settings = settings
                    waitForNewIndex()
                    return
                }
                precondition(Date() < deadline, "App-managed OLD index build did not complete")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: waitForOldIndex)
            }
            waitForOldIndex()
            return true
        }
        #if DEBUG
        if MeetingFixtureLaunch.runIfRequested() { return true }
        #endif
        if ProcessInfo.processInfo.environment["STILLMATTER_TASK04_FOCUSED_LAYOUT"] != nil {
            precondition(ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] != nil &&
                         ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] != nil &&
                         ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] != nil,
                         "Focused Task 04 layout requires three isolated validation roots")
            configureMeetingReadModel(settings: settingsStore.settings)
            guard let mode = ProcessInfo.processInfo.environment["STILLMATTER_TASK04_FOCUSED_LAYOUT"],
                  ["layout-all", "layout-1440", "layout-1200", "layout-720", "tab", "navigation", "keyboard"].contains(mode) else {
                fatalError("Unknown focused Task 04 mode")
            }
            runShellLayoutHarness(focusedMode: mode)
            return true
        }
        if ProcessInfo.processInfo.environment["STILLMATTER_SHELL_LAYOUT_HARNESS"] == "1" {
            precondition(ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] != nil &&
                         ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] != nil &&
                         ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] != nil,
                         "Shell layout harness requires three isolated validation roots")
            configureMeetingReadModel(settings: settingsStore.settings)
            runShellLayoutHarness()
            return true
        }
        return false
    }

    private func runShellLayoutHarness(focusedMode: String? = nil) {
        let window = makeMainWindow()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self = self,
                  let window = window,
                  let shell = window.contentViewController as? ShellViewController else {
                fatalError("Could not create the whole-window shell fixture")
            }
            let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            precondition(
                visibleFrame.width == 0 || window.contentLayoutRect.width >= visibleFrame.width * 0.78,
                "Initial main window must occupy about 80% of the screen width"
            )
            precondition(
                window.minSize.width == 720 && window.minSize.height == 520,
                "Main window must support the 720×520 outer-frame minimum"
            )
            shell.validateReferenceShellLayout()
            func finish(_ marker: String) {
                print(marker)
                fflush(stdout)
                Darwin.exit(EXIT_SUCCESS)
            }
            switch focusedMode {
            case "layout-all":
                shell.validateAdaptiveShellLayout(in: window, focusedAfterAudio: true) {
                    finish("TASK04_FOCUSED adaptive sequence 1440 -> 1200 -> 720 passed (audio/caption excluded)")
                }
            case "layout-1440", "layout-1200", "layout-720":
                let width = Int(focusedMode!.dropFirst("layout-".count))!
                shell.validateAdaptiveShellLayout(in: window, focusedAfterAudio: true, focusedWidth: width) {
                    finish("TASK04_FOCUSED adaptive layout \(width) passed (audio/caption excluded)")
                }
            case "tab":
                shell.validateTabScrolling(in: window)
                finish("TASK04_FOCUSED Tasks/Today tab scrolling passed")
            case "navigation":
                shell.validateDestinationNavigation(in: window)
                self.validateShellMenuParity()
                finish("TASK04_FOCUSED Destination navigation and menu parity passed")
            case "keyboard":
                shell.validateSearchKeyboardFocus(in: window) {
                    print("TASK04_FOCUSED keyboard focus/filter/Escape 720 passed")
                    shell.validateSearchKeyboardFocus(in: window, width: 1200) {
                        finish("TASK04_FOCUSED keyboard focus/filter/Escape 1200 passed")
                    }
                }
            default:
                shell.validateAdaptiveShellLayout(in: window) {
                    self.finishShellLayoutHarness(shell: shell, window: window)
                }
            }
        }
    }

    private func finishShellLayoutHarness(shell: ShellViewController, window: NSWindow) {
        shell.validateTabScrolling(in: window)
        if ProcessInfo.processInfo.environment["STILLMATTER_TAB_SCROLL_HARNESS"] == "1" {
            print("Tab scroll range and switch position passed.")
            fflush(stdout)
            Darwin.exit(EXIT_SUCCESS)
        }
        validateShellMenuParity()
        shell.validateSearchKeyboardFocus(in: window) {
            shell.validateSearchKeyboardFocus(in: window, width: 1200) {
                print("Adaptive shell layout and search keyboard focus passed at 720×520, 1200×760, and 1440×760.")
                fflush(stdout)
                Darwin.exit(EXIT_SUCCESS)
            }
        }
    }

    private func validateShellMenuParity() {
        let actions = menuActions(in: NSApp.mainMenu)
        [#selector(focusAreaSearch(_:)), #selector(toggleSidebar(_:)), #selector(showSettings(_:))]
            .forEach { action in
                precondition(actions.contains(NSStringFromSelector(action)),
                             "Menu parity is missing \(NSStringFromSelector(action))")
            }
        print("TASK04_FOCUSED shell menu parity passed")
    }

    private func menuActions(in menu: NSMenu?) -> Set<String> {
        guard let menu = menu else { return [] }
        return menu.items.reduce(into: Set<String>()) { result, item in
            if let action = item.action {
                result.insert(NSStringFromSelector(action))
            }
            result.formUnion(menuActions(in: item.submenu))
        }
    }

}
#endif
