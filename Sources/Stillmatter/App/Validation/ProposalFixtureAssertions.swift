import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

#if DEBUG
extension ProposalReviewView {
    /// Exercises zero, one, many, selected, edited, long-source, failure, and narrow states.
    func validateFixtures() {
        let wasHidden = isHidden
        let originalResponder = window?.firstResponder
        let originalScrollOrigin = enclosingScrollView?.contentView.bounds.origin
        isHidden = false
        let originalProposals = rows.map(\.proposal)
        let originalEdits = Dictionary(uniqueKeysWithValues: rows.map { ($0.proposal.id, $0.titleField.stringValue) })
        let originalSelected = Set(selectedRows.map(\.proposal.id))

        rebuildRows([])
        precondition(rows.isEmpty && !acceptSelectedButton.isEnabled && !mergeSelectedButton.isEnabled, "Zero-proposal fixture must disable batch review")

        let longSource = "[[Meetings/2026/Quarterly Planning/Extremely Long Durable Source Path/summary#My action items|source]]"
        let one = ActionItemProposal(id: "fixture:one", title: "Edit the launch follow-up", sourceRef: longSource)
        rebuildRows([one])
        precondition(rows.count == 1 && rows[0].pendingLabel.statusText == "Pending proposal", "One-proposal fixture must expose pending meaning")
        precondition(rows[0].sourceLabel.toolTip == longSource, "Long source fixture must retain its durable reference")
        rows[0].titleField.stringValue = "Edited launch follow-up"
        rows[0].selection.state = .on
        updateSelectionControls()
        precondition(acceptSelectedButton.isEnabled && !mergeSelectedButton.isEnabled, "One selected proposal must enable only acceptance")

        let two = ActionItemProposal(id: "fixture:two", title: "Share the recording", sourceRef: "[[Meetings/launch/summary|source]]")
        let many = [
            one,
            two,
            ActionItemProposal(id: "fixture:three", title: "Confirm the launch date", sourceRef: "[[Meetings/launch/summary#Date|source]]"),
            ActionItemProposal(id: "fixture:four", title: "Prepare the release notes", sourceRef: "[[Meetings/launch/summary#Release|source]]"),
            ActionItemProposal(id: "fixture:five", title: "Schedule the retrospective", sourceRef: "[[Meetings/launch/summary#Follow-up|source]]"),
            ActionItemProposal(id: "fixture:six", title: "Close the validation loop", sourceRef: "[[Meetings/launch/summary#Validation|source]]")
        ]
        rebuildRows(many)
        layoutSubtreeIfNeeded()
        if let window = window {
            precondition(window.makeFirstResponder(rows[0].selection), "The first proposal checkbox must accept keyboard focus")
            let keyEvent: (String, UInt16) -> NSEvent = { characters, keyCode in
                NSEvent.keyEvent(
                    with: .keyDown,
                    location: .zero,
                    modifierFlags: [],
                    timestamp: 0,
                    windowNumber: window.windowNumber,
                    context: nil,
                    characters: characters,
                    charactersIgnoringModifiers: characters,
                    isARepeat: false,
                    keyCode: keyCode
                )!
            }
            let initialSelection = rows[0].selection.state
            rows[0].selection.keyDown(with: keyEvent(" ", 49))
            precondition(rows[0].selection.state != initialSelection, "Space must toggle a focused proposal checkbox")
            rows[0].selection.state = initialSelection
            rows[0].selection.keyDown(with: keyEvent("\t", 48))
            precondition(
                rows[0].titleField.currentEditor() === window.firstResponder,
                "Tab must move from a proposal checkbox to its editable title"
            )
            let titleEditor = rows[0].titleField.currentEditor() as! NSTextView
            precondition(
                control(rows[0].titleField, textView: titleEditor, doCommandBy: #selector(NSResponder.insertTab(_:)))
                    && window.firstResponder === rows[0].dismissButton,
                "Tab must move from title editing to the first per-row action"
            )
            rows[1].selection.state = .on
            updateSelectionControls()
            let expectedTraversal = keyboardTraversalControls.dropFirst()
            for (current, next) in zip(expectedTraversal, expectedTraversal.dropFirst()) {
                precondition(
                    moveKeyboardFocus(from: current, movesBackward: false),
                    "Every enabled proposal review control must have a following keyboard target"
                )
                let reachedNext = window.firstResponder === next
                    || (next as? NSTextField)?.currentEditor() === window.firstResponder
                precondition(reachedNext, "Tab must traverse proposal controls in display order")
            }
            rows[1].selection.state = .off
            updateSelectionControls()
            precondition(window.makeFirstResponder(rows[2].titleField), "A proposal title must accept keyboard focus")
            rebuildRows(many)
            precondition(
                rows[2].titleField.currentEditor() === window.firstResponder,
                "Refreshing unchanged proposals must preserve the focused editor"
            )
            let changed = many + [ActionItemProposal(id: "fixture:incoming", title: "New proposal", sourceRef: longSource)]
            rebuildRows(changed)
            precondition(
                rows[2].titleField.currentEditor() === window.firstResponder,
                "Incoming proposals must not steal focus from an active title edit"
            )
            precondition(rows[0].titleField.stringValue == "Edited launch follow-up" && rows[0].selection.state == .on,
                         "Refresh must preserve edits and selection")
            rebuildRows(Array(many.dropFirst()))
            focusAfterRemoval(of: many[0].id, removedIndex: 0)
            precondition(window.firstResponder === rows[0].selection, "After review removes a proposal, focus must move to the next proposal")
            rebuildRows([])
            focusAfterRemoval(of: many[1].id, removedIndex: 0)
            precondition(!isHidden && !emptyStateLabel.isHidden,
                         "The review section and empty-state focus target must remain visible after the last removal")
            precondition(window.firstResponder === emptyStateLabel, "After the last reviewed proposal disappears, focus must stay on the review empty state")
            rebuildRows(many)
            rows[0].titleField.stringValue = "Edited launch follow-up"
            rows[0].selection.state = .on
            updateSelectionControls()
        }
        precondition(
            rows.allSatisfy { $0.container.frame.height >= 80 },
            "Proposal rows must retain enough height to prevent controls from overlapping"
        )
        precondition(
            zip(rows, rows.dropFirst()).allSatisfy { !$0.container.frame.intersects($1.container.frame) },
            "Proposal rows must have non-overlapping interactive frames"
        )
        for row in rows {
            let buttonFrame = row.container.convert(row.acceptButton.bounds, from: row.acceptButton)
            let titleFrame = row.container.convert(row.titleField.bounds, from: row.titleField)
            precondition(
                row.container.bounds.contains(buttonFrame) && row.container.bounds.contains(titleFrame),
                "Every proposal editor and action must stay inside its own interactive row"
            )
        }
        rows[1].selection.state = .on
        updateSelectionControls()
        precondition(mergeSelectedButton.isEnabled && selectionLabel.stringValue == "2 proposals selected", "Many-proposal fixture must update batch controls")

        frame.size.width = 480 // graphite-focus-native-exception: Minimum Operable Window detail width fixture
        layoutSubtreeIfNeeded()
        precondition(rows.allSatisfy { $0.container.frame.maxX <= listStack.bounds.maxX + 1 }, "Narrow proposal rows must not overflow the collection")

        setFailure("Review failed. The proposal was not changed; fixture remains actionable")
        precondition(
            !failureLabel.isHidden && failureLabel.meaning == .destructive && failureLabel.statusText.contains("not changed"),
            "Failed-review fixture must retain static error meaning and say the proposal was not changed"
        )
        precondition(failureLabel.maximumNumberOfLines == 0 && failureLabel.lineBreakMode == .byWordWrapping,
                     "Failed-review details must wrap without hiding retry guidance")

        rebuildRows(originalProposals)
        for row in rows {
            if let edit = originalEdits[row.proposal.id] { row.titleField.stringValue = edit }
            row.selection.state = originalSelected.contains(row.proposal.id) ? .on : .off
        }
        clearFailure()
        updateSelectionControls()
        isHidden = wasHidden
        window?.makeFirstResponder(originalResponder)
        if let originalScrollOrigin = originalScrollOrigin, let scrollView = enclosingScrollView {
            scrollView.contentView.scroll(to: originalScrollOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        print("TASK09_PROPOSAL synthetic walkthrough passed (DEBUG)")
        fflush(stdout)
    }
}
#endif
