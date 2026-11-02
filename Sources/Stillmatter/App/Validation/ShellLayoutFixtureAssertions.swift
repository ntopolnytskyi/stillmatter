#if DEBUG || STILLMATTER_NATIVE_PROBES
import AppKit
import Darwin
import StillmatterCore
import StillmatterPresentation

extension ShellViewController {
    private func configureAdaptiveFixtureRegions(_ enabled: Bool) {
        usesAdaptiveFixtureRegions = enabled
        hasContentListRegion = enabled || stateStore.state.selectedTab == .meetings
        hasInspectorRegion = enabled
        inspectorPreferredVisible = enabled
        showingNarrowDetail = false
        lastAdaptiveLayout = nil
        // The inspector has no production owner yet. A validation run must install
        // its placeholder as a genuinely available split region before testing
        // whether the adaptive policy retains or collapses it at each width.
        if enabled { inspectorContainer.isHidden = false }
        applyAdaptiveLayout()
    }

    private func settleAdaptiveInspectorFixture() {
        guard usesAdaptiveFixtureRegions, lastAdaptiveLayout?.showsInspector == true else { return }
        // The empty placeholder has no intrinsic width. Give the fixture its
        // policy-reserved 280-point column instead of accepting a 2-point sliver.
        let visibleRegions = workspaceSplitView.arrangedSubviews.filter { !$0.isHidden }
        precondition(visibleRegions.last === inspectorContainer && visibleRegions.count >= 2,
                     "Enabled inspector must be an arranged split region")
        workspaceSplitView.setPosition(workspaceSplitView.bounds.width - 300,
                                       ofDividerAt: visibleRegions.count - 2)
        workspaceSplitView.adjustSubviews()
        view.layoutSubtreeIfNeeded()
    }

    func validateReferenceShellLayout() {
        view.layoutSubtreeIfNeeded()
        installToolbarIfNeeded()
        view.window?.layoutIfNeeded()
        prepareForWindowResize(to: 1200)
        view.window?.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()

        precondition(
            abs(sidebarContainer.frame.width - AdaptiveShellLayout.sidebarWidth) < 1,
            "Icon rail must start at its fixed width"
        )
        let fixedSidebarWidth = sidebarContainer.frame.width
        splitView.setPosition(AdaptiveShellLayout.sidebarWidth * 2, ofDividerAt: 0)
        view.layoutSubtreeIfNeeded()
        precondition(abs(sidebarContainer.frame.width - fixedSidebarWidth) < 1, "Sidebar divider must stay fixed")
        sidebarPreferredVisible = false
        applyAdaptiveLayout()
        sidebarPreferredVisible = true
        applyAdaptiveLayout()
        view.layoutSubtreeIfNeeded()
        precondition(
            abs(sidebarContainer.frame.width - fixedSidebarWidth) < 1,
            "Sidebar width must remain fixed across visibility changes"
        )
        precondition(sidebarContainer.frame.height > 0, "Sidebar must have a visible non-zero frame")
        precondition(splitView.arrangedSubviews.count == 2 && splitView.arrangedSubviews[1].frame.width > 0, "Detail region must have a visible non-zero frame")
        precondition(sidebarTabs.count == 5 && navigationButtons.count == 5, "Navigation rail must show all five areas")
        precondition(aboutButton.frame.minY >= 0 && aboutButton.frame.minY <= GraphiteFocusPresentation.Space.panel,
                     "About icon must remain at the bottom of the rail")
        if let settingsButton = navigationButtons[.settings] {
            precondition(settingsButton.superview === sidebarContainer,
                         "Settings must remain outside the scrolling destinations")
            // Native NSButton's frame includes 2 pt below its 44 pt alignment rect.
            // Auto Layout anchors (and the visible control geometry) use alignment rects.
            let settingsAlignment = settingsButton.alignmentRect(forFrame: settingsButton.frame)
            let aboutAlignment = aboutButton.alignmentRect(forFrame: aboutButton.frame)
            precondition(settingsAlignment.height == 44 && aboutAlignment.height == 44 &&
                         abs(settingsAlignment.minY - aboutAlignment.maxY - GraphiteFocusPresentation.Space.compact) < 1 &&
                         settingsButton.frame.minY > aboutButton.frame.maxY,
                         "Settings must stay anchored immediately above About without overlapping")
            precondition(abs(settingsButton.frame.midX - sidebarContainer.bounds.midX) < 1,
                         "Settings must stay centered in the fixed icon rail")
        }
        if let todayButton = navigationButtons[.today] {
            let topInset = sidebarContainer.bounds.maxY - todayButton.convert(todayButton.bounds, to: sidebarContainer).maxY
            precondition((0..<140).contains(topInset), "Navigation icons must start at the top of the rail")
        }
        precondition(navigationButtons[stateStore.state.selectedTab]?.accessibilityValue() as? String == "Selected", "Navigation selection must follow shell state")
        precondition(contentTitle.stringValue == stateStore.state.selectedTab.rawValue, "Page Header must follow shell state")
        precondition(toolbarAreaLabel.stringValue == stateStore.state.selectedTab.rawValue, "Toolbar location must follow shell state")
        precondition(searchField.placeholderString == "Search", "Toolbar Search placeholder must remain area-neutral")
        precondition(searchField.accessibilityLabel() as? String == "Search", "Toolbar Search must have a distinct VoiceOver name")
        precondition(searchField.accessibilityHelp()?.contains("Today") == true, "Toolbar Search must expose current area scope")
        precondition((searchKindPopup.accessibilityValue() as? String) == "All types", "Search type picker must default to All types")
        validateJobProgressPresentationFixture()

        let identifiers = Set(toolbar.items.map(\.itemIdentifier.rawValue))
        [
            "Stillmatter.ToggleSidebar", "Stillmatter.CurrentArea", "Stillmatter.RecordingStatus",
            "Stillmatter.JobStatus"
        ].forEach { precondition(identifiers.contains($0), "Toolbar is missing \($0)") }

        let removableToolbarItems = toolbar.items.enumerated().compactMap { index, item in
            item.itemIdentifier == .currentArea ? index : nil
        }
        removableToolbarItems.sorted(by: >).forEach(toolbar.removeItem)
        focusAreaSearch(nil)
        precondition(!statusBar.isHidden && !searchField.isHidden && searchField.window === view.window,
                     "Toolbar customization must not remove global Search from the Status Bar")
        precondition(view.window?.makeFirstResponder(searchKindPopup) == true,
                     "Status Bar Search result type must accept native keyboard focus")
        toolbar.insertItem(withItemIdentifier: .currentArea, at: min(1, toolbar.items.count))

        stateStore.state.select(.tasks)
        view.layoutSubtreeIfNeeded()
        precondition(contentTitle.stringValue == ShellTab.tasks.rawValue, "Navigation did not synchronize the Page Header")
        precondition(toolbarAreaLabel.stringValue == ShellTab.tasks.rawValue, "Navigation did not synchronize the toolbar")
        stateStore.state.select(.today)
    }

    func validateAdaptiveShellLayout(in window: NSWindow, focusedAfterAudio: Bool = false,
                                     focusedWidth: Int? = nil, completion: @escaping () -> Void) {
        let originalSidebarPreference = sidebarPreferredVisible
        let originalInspectorPreference = inspectorPreferredVisible
        sidebarPreferredVisible = true
        inspectorPreferredVisible = true
        configureAdaptiveFixtureRegions(true)
        stateStore.state.select(.today)
        #if DEBUG
        todayWorkbenchView.validateFixtures()
        #endif
        #if DEBUG
        searchResultsView.validateFixtures()
        #endif
        #if DEBUG
        captureRecordingView.validateFixtures()
        todoLedgerView.validateFixtures()
        proposalReviewView.validateFixtures()
        #endif
        #if DEBUG
        settingsFormView.validateFixtures()
        #endif
        // The native keyboard-focus probe owns its results; the synthetic Search
        // walkthrough may be debug-only and may leave any state behind.
        searchResultsView.render(query: "focus fixture", scope: "Today", type: "All types", state: .results([
            SearchResult(kind: .todo, sourcePath: "Todos/todo.md", title: "First focus result", body: "Disposable result"),
            SearchResult(kind: .todo, sourcePath: "Todos/todo.md", title: "Second focus result", body: "Disposable result")
        ]))
        precondition(searchResultsView.resultCountForValidation == 2 && searchResultsView.tableView.selectedRow == 0,
                     "Area Search focus fixture must expose two selected disposable results")
        searchResultsView.isHidden = false
        precondition(
            control(searchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))),
            "Down Arrow in Area Search must move keyboard focus into available results"
        )
        precondition(searchResultsView.resultsHaveKeyboardFocus, "Area Search must hand keyboard focus to the results table")
        isSearchPresented = false
        render()
        precondition(!todayWorkbenchView.isHidden, "Today must use the Structured Workbench")
        stateStore.state.select(.meetings)
        view.layoutSubtreeIfNeeded()
        #if DEBUG
        meetingManagementView.validateBrowserFilterPresentationFixture()
        #endif
        meetingManagementView.validateLongContentOverflowFixture()
        meetingManagementView.prepareCaptionLayoutFixture { [self] in
            validateAdaptiveShellLayoutAfterMeeting(in: window,
                originalSidebarPreference: originalSidebarPreference,
                originalInspectorPreference: originalInspectorPreference,
                focusedAfterAudio: focusedAfterAudio, focusedWidth: focusedWidth, completion: completion)
        }
    }

    private func validateAdaptiveShellLayoutAfterMeeting(in window: NSWindow,
        originalSidebarPreference: Bool, originalInspectorPreference: Bool,
        focusedAfterAudio: Bool, focusedWidth: Int?, completion: @escaping () -> Void) {
        meetingManagementView.validateCaptionLayoutFixture()
        meetingManagementView.validateTimelineSelectionFixture()
        if !focusedAfterAudio {
            meetingManagementView.validateAudioTransportFixture { [self] in
                validateAdaptiveShellLayoutAfterAudio(in: window, focusedWidth: focusedWidth, checkMeetingTop: true,
                    originalSidebarPreference: originalSidebarPreference,
                    originalInspectorPreference: originalInspectorPreference)
                completion()
            }
            return
        }
        validateAdaptiveShellLayoutAfterAudio(in: window, focusedWidth: focusedWidth, checkMeetingTop: false,
            originalSidebarPreference: originalSidebarPreference,
            originalInspectorPreference: originalInspectorPreference)
        completion()
    }

    private func validateAdaptiveShellLayoutAfterAudio(in window: NSWindow, focusedWidth: Int?, checkMeetingTop: Bool,
        originalSidebarPreference: Bool, originalInspectorPreference: Bool) {
        if checkMeetingTop {
            let meetingTop = meetingManagementView.convert(NSPoint(x: 0, y: meetingManagementView.bounds.height), to: view).y
            let detailTop = detailContainer.convert(.zero, to: view).y
            precondition(abs(meetingTop - detailTop) < 65, "Meeting caption must not sit below a blank shell header")
        }
        // Focused Task 04 runs the original subsequent layout assertions without
        // representing the two separately tracked Meeting guards as passed.
        captureRecordingView.validateVisibleLayout()
        stateStore.state.select(.tasks)
        precondition(!todoLedgerView.isHidden, "Tasks must use the Precision Ledger")
        stateStore.state.select(.meetings)
        stateStore.state.searchText = "preserved draft"
        let detailIdentity = ObjectIdentifier(detailContainer)
        let detailScrollOrigin = contentScrollView?.contentView.bounds.origin

        if focusedWidth == nil || focusedWidth == 1440 {
            prepareForWindowResize(to: 1440)
            window.setContentSize(NSSize(width: 1440, height: 760))
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            applyAdaptiveLayout()
            settleAdaptiveInspectorFixture()
            precondition(lastAdaptiveLayout?.showsInspector == true, "Spacious layout must show the inspector")
            precondition(lastAdaptiveLayout?.showsSidebar == true, "Spacious layout must show the preferred sidebar")
            precondition(lastAdaptiveLayout?.detailMode == .listAndDetail, "Spacious layout must show list and detail")
            precondition(!contentListContainer.isHidden && !detailContainer.isHidden && !inspectorContainer.isHidden &&
                         inspectorContainer.frame.width >= 280 && inspectorContainer.frame.height > 0,
                         "Spacious regions must have visible, useful frames")
        }
        if focusedWidth == 1440 { return }

        prepareForWindowResize(to: 1200)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        applyAdaptiveLayout()
        if focusedWidth != 720 {
            settleAdaptiveInspectorFixture()
            precondition(lastAdaptiveLayout?.showsInspector == true, "Narrow rail must leave room for inspector at reference width")
            precondition(lastAdaptiveLayout?.showsSidebar == true, "Sidebar must remain after inspector collapse")
            precondition(lastAdaptiveLayout?.detailMode == .listAndDetail, "Reference layout must retain list/detail continuity")
            precondition(!inspectorContainer.isHidden && inspectorContainer.frame.width >= 280 &&
                         inspectorContainer.frame.height > 0,
                         "Reference inspector must have a useful visible frame")
        }
        if focusedWidth == 1200 { return }

        window.makeFirstResponder(searchField)
        precondition(searchControlHasFocus(searchField), "Reference Search field must accept keyboard focus before resize")
        prepareForWindowResize(to: 720)
        window.setFrame(NSRect(origin: window.frame.origin, size: AppDelegate.minimumWindowFrameSize), display: true)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        applyAdaptiveLayout()
        precondition(abs(window.frame.width - 720) < 2 && abs(window.frame.height - 520) < 2,
                     "The outer window must reach the 720×520 Minimum Operable Window")
        precondition(lastAdaptiveLayout?.showsSidebar == true, "Navigation rail must remain available at minimum width")
        precondition(lastAdaptiveLayout?.detailMode == .listOnly, "Narrow layout must replace detail with the content list")
        precondition(lastAdaptiveLayout?.showsInspector == false && inspectorContainer.isHidden,
                     "Minimum width must collapse the optional inspector")
        precondition(!statusBar.isHidden && !searchField.isHidden && searchField.window === window,
                     "Global Search must remain physically visible in the Status Bar at minimum width")
        precondition(searchControlHasFocus(searchField),
                     "Resize must preserve focus in the always-visible Status Bar Search field")
        precondition(searchField.stringValue == "preserved draft", "Resize must preserve focused Search input")
        precondition(searchKindPopup.selectedItem?.title == "All types",
                     "The fixed Status Bar Search type must remain available at minimum width")
        prepareForWindowResize(to: 1200)
        precondition(searchControlHasFocus(searchField), "Expanding must preserve Status Bar Search focus")
        prepareForWindowResize(to: 720)
        precondition(!statusBar.isHidden && searchControlHasFocus(searchField),
                     "Recompacting must preserve always-visible Search focus")
        prepareForWindowResize(to: 1200)
        precondition(window.makeFirstResponder(searchKindPopup), "Toolbar Search type must accept keyboard focus")
        prepareForWindowResize(to: 720)
        precondition(window.firstResponder === searchKindPopup,
                     "Compacting must preserve focus in the fixed Status Bar type picker")
        prepareForWindowResize(to: 1200)
        precondition(window.firstResponder === searchKindPopup,
                     "Expanding must preserve focus in the Status Bar type picker")
        prepareForWindowResize(to: 720)
        precondition(abs(view.bounds.width - 720) < 2, "Compact Area Search must not force the window wider")
        precondition(!contentListContainer.isHidden && detailContainer.isHidden,
                     "Narrow layout must initially present the list")

        showingNarrowDetail = true
        applyAdaptiveLayout()
        precondition(!narrowBackButton.isHidden, "Narrow detail must expose a native back affordance")
        precondition(contentListContainer.isHidden && !detailContainer.isHidden,
                     "Narrow navigation must be able to present detail")
        showNarrowList(nil)
        precondition(!contentListContainer.isHidden && detailContainer.isHidden,
                     "Back must return to the narrow content list")
        configureAdaptiveFixtureRegions(false)
        isSearchPresented = true
        render()
        precondition(!searchResultsView.isHidden && workspaceSplitView.arrangedSubviews.contains { $0 === detailContainer },
                     "Area Search must remain visible in narrow Meetings")
        isSearchPresented = false
        render()
        precondition(!contentListContainer.isHidden && detailContainer.isHidden,
                     "Dismissing Search must restore the narrow Meeting list")

        precondition(stateStore.state.selectedTab == .meetings, "Resize must preserve the selected area")
        precondition(stateStore.state.searchText == "preserved draft", "Resize must preserve in-progress input")
        precondition(ObjectIdentifier(detailContainer) == detailIdentity, "Resize must preserve the detail canvas")
        precondition(contentScrollView?.contentView.bounds.origin == detailScrollOrigin, "Resize must preserve detail scroll position")

        configureAdaptiveFixtureRegions(false)
        sidebarPreferredVisible = originalSidebarPreference
        inspectorPreferredVisible = originalInspectorPreference
        stateStore.state.searchText = ""
        stateStore.state.select(.today)
        prepareForWindowResize(to: 1200)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        applyAdaptiveLayout()
    }

    func validateDestinationNavigation(in window: NSWindow) {
        for width: CGFloat in [1440, 1200, 720] {
            prepareForWindowResize(to: width)
            window.setContentSize(NSSize(width: width, height: width == 720 ? 520 : 760))
            window.layoutIfNeeded()
            view.layoutSubtreeIfNeeded()
            stateStore.state.select(.tasks)
            view.layoutSubtreeIfNeeded()
            precondition(contentTitle.stringValue == ShellTab.tasks.rawValue &&
                         toolbarAreaLabel.stringValue == ShellTab.tasks.rawValue &&
                         !todoLedgerView.isHidden && todoLedgerView.frame.width > 0 &&
                         todoLedgerView.frame.height > 0 &&
                         todoLedgerView.frame.minX >= 0 &&
                         todoLedgerView.frame.maxX <= todoLedgerView.superview!.bounds.maxX + 1,
                         "Tasks must remain visible within shell content at \(width)")
            print("TASK04_FOCUSED Destination navigation layout \(Int(width)) passed")
        }
        stateStore.state.select(.today)
    }

    func validateTabScrolling(in window: NSWindow) {
        prepareForWindowResize(to: 1200)
        window.setContentSize(NSSize(width: 1200, height: 760))
        window.layoutIfNeeded()
        stateStore.state.select(.tasks)
        let tallTask = todoLedgerView.heightAnchor.constraint(greaterThanOrEqualToConstant: 1100)
        tallTask.isActive = true
        defer { tallTask.isActive = false }
        view.layoutSubtreeIfNeeded()
        guard let scroll = contentScrollView, let document = scroll.documentView else {
            preconditionFailure("Missing detail scroller")
        }
        precondition(document.frame.height > scroll.contentView.bounds.height + 100, "Fixture must overflow on Tasks")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 180))
        scroll.reflectScrolledClipView(scroll.contentView)
        precondition(scroll.contentView.bounds.minY > 100, "Fixture must scroll Tasks")
        stateStore.state.select(.today)
        view.layoutSubtreeIfNeeded()
        precondition(scroll.contentView.bounds.minY == 0, "Today must start at the top after scrolling Tasks")
        stateStore.state.select(.today)
        view.layoutSubtreeIfNeeded()
    }

    private func validateJobProgressPresentationFixture() {
        let colors = GraphiteFocusPresentation.Colors(environment: currentPresentationEnvironment)
        updateJobPresentation(status: "1 Job queued", colors: colors)
        precondition(!jobProgress.isHidden && jobBadge.isHidden,
                     "Queued Jobs must use shared native progress presentation")
        precondition(jobProgress.progressIndicator.isIndeterminate,
                     "Queued Jobs must expose indeterminate native progress")
        precondition(jobProgress.statusLabel.meaning == .informational,
                     "Job progress must not borrow attention status meaning")
        precondition(jobProgress.statusLabel.statusText == "1 Job queued",
                     "Job progress must retain visible stage text")
        precondition(jobPresentationContainer.frame.height <= 22,
                     "Job progress must fit the native toolbar height")

        updateJobPresentation(status: "1 Job running", colors: colors)
        precondition(!jobProgress.isHidden && jobProgress.valueLabel.stringValue == "Running",
                     "Running Jobs must remain progress with an accessible activity value")
        updateJobPresentation(status: "1 Job failed", colors: colors)
        precondition(!jobBadge.isHidden && jobBadge.meaning == .destructive,
                     "Failed Job meaning must remain destructive")
        updateJobPresentation(status: "Jobs ready", colors: colors)
        precondition(!jobBadge.isHidden && jobBadge.meaning == .informational,
                     "Ready/idle Job meaning must remain unchanged")
        updateJobBadge(colors: colors)
    }

    func validateSearchKeyboardFocus(in window: NSWindow, width: CGFloat = 720, completion: @escaping () -> Void) {
        let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent("StillmatterSearchFocus-\(UUID().uuidString)")
        let vault = fixtureRoot.appendingPathComponent("Vault")
        do {
            try FileManager.default.createDirectory(at: vault.appendingPathComponent("Todos"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: vault.appendingPathComponent("Meetings/planning"), withIntermediateDirectories: true)
            try Data("# Todos\n\n## Queue\n\n- [ ] First planning item\n- [ ] Second planning item\n".utf8)
                .write(to: vault.appendingPathComponent("Todos/todo.md"))
            try Data("# Planning meeting\n\nPlanning follow-up.\n".utf8)
                .write(to: vault.appendingPathComponent("Meetings/planning/meeting.md"))
            let index = try SearchIndex(databaseURL: fixtureRoot.appendingPathComponent("search.sqlite"), workspaceRootURL: vault)
            try index.startupScan()
            let previousProvider = searchIndexProvider
            searchIndexProvider = { index }
            stateStore.state.select(.today)
            stateStore.state.searchText = "planning"
            prepareForWindowResize(to: width)
            window.setContentSize(NSSize(width: width, height: 520))
            window.layoutIfNeeded()
            focusAreaSearch(nil)
            // Search is debounced; wait for the indexed fixture before exercising result focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
                precondition(searchResultsView.resultCountForValidation == 3, "Fixture must produce typed Todo and Meeting results")
                validateSearchTypeFilteringWithFixture {
                    self.validateSearchKeyboardFocusWithFixture(in: window, width: width) {
                        self.searchKindPopup.selectItem(at: 0)
                        self.updateSearchAccessibilityContext(area: self.stateStore.state.selectedTab)
                        self.searchIndexProvider = previousProvider
                        try? FileManager.default.removeItem(at: fixtureRoot)
                        completion()
                    }
                }
            }
        } catch {
            fatalError("Could not set up search focus fixture: \(error)")
        }
    }

    private func validateSearchTypeFilteringWithFixture(completion: @escaping () -> Void) {
        guard let todoIndex = searchKindPopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == SearchChunkKind.todo.rawValue
        }) else {
            preconditionFailure("Compact Search fixture is missing the Todo result type")
        }
        searchKindPopup.selectItem(at: todoIndex)
        searchKindChanged(searchKindPopup)
        precondition(searchKindPopup.selectedItem?.representedObject as? String == SearchChunkKind.todo.rawValue,
                     "Changing compact result type must update toolbar selection")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
            precondition(searchResultsView.resultCountForValidation == 2,
                         "Changing Search result type must narrow indexed results")
            searchKindPopup.selectItem(at: 0)
            searchKindChanged(searchKindPopup)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                precondition(searchResultsView.resultCountForValidation == 3,
                             "All types must restore results without changing query or scope")
                searchKindPopup.selectItem(at: todoIndex)
                searchKindChanged(searchKindPopup)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [self] in
                    precondition(searchResultsView.resultCountForValidation == 2,
                                 "Filtered fixture must retain two rows for keyboard navigation")
                    completion()
                }
            }
        }
    }

    private func validateSearchKeyboardFocusWithFixture(in window: NSWindow, width: CGFloat, completion: @escaping () -> Void) {
        let activeSearchField = searchField
        precondition(control(activeSearchField, textView: NSTextView(), doCommandBy: #selector(NSResponder.moveDown(_:))),
                     "Down Arrow must hand keyboard focus to search results")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in
            precondition(searchResultsView.resultsHaveKeyboardFocus,
                         "Search results must retain keyboard focus after compact search closes")
            searchResultsView.validateArrowNavigationKeepsFocus()
            stateStore.publish(.jobStatus) // Status must not touch search results or focus.
            precondition(searchResultsView.resultsHaveKeyboardFocus,
                         "A background status refresh must not return focus to Area Search")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                precondition(searchResultsView.resultsHaveKeyboardFocus,
                             "After two arrows and a pause, focus must not return to Area Search")
                validateSearchDismissalWithFixture(width: width)
                completion()
            }
        }
    }

    private func validateSearchDismissalWithFixture(width: CGFloat) {
        searchResultsView.validateEscapeDismissesResults()
        precondition(!isSearchPresented && searchResultsView.isHidden, "Escape in results must close search")
        stateStore.state.searchText = ""
        focusAreaSearch(nil)
        precondition(isSearchPresented && searchResultsView.isHidden,
                     "Focus Area Search must not replace the page before a query is entered")
        let field = searchField
        precondition(control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))),
                     "Escape in Area Search must be handled")
        precondition(!isSearchPresented && searchResultsView.isHidden, "Escape in the search field must close search")
    }

}
#endif
