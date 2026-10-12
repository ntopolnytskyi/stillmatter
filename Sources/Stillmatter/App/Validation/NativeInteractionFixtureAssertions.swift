#if DEBUG || STILLMATTER_NATIVE_PROBES
import AppKit

extension SearchResultsView {
    func validateEscapeDismissesResults() {
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false, keyCode: 53
        )!
        tableView.keyDown(with: event)
    }

    func validateArrowNavigationKeepsFocus() {
        for (keyCode, character, expectedRow) in [(125, "\u{F701}", 1), (125, "\u{F701}", 1), (126, "\u{F700}", 0)] {
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window?.windowNumber ?? 0, context: nil,
                characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: UInt16(keyCode)
            )!
            tableView.keyDown(with: event)
            precondition(tableView.selectedRow == expectedRow && resultsHaveKeyboardFocus,
                         "Arrow navigation must keep focus and selection in search results")
        }
    }
}

extension CaptureRecordingView {
    /// Verifies the actual shell embedding rather than only the view's isolated fitting size.
    func validateVisibleLayout() {
        layoutSubtreeIfNeeded()
        guard let parent = superview else { preconditionFailure("Capture workspace must be embedded in the shell") }
        precondition(parent.bounds.maxX - frame.maxX <= 33, "Capture workspace must fill the shell detail width")
        precondition((90...120).contains(statePanel.frame.height), "Capture state panel must keep a compact stable height")
        precondition(statusLabel.frame.width > 0 && statusLabel.frame.height > 0, "Capture state text must have a visible frame")
    }
}

extension ProposalReviewView {
    func acceptFirstForValidation() {
        precondition(rows.count == 1 && rows[0].acceptButton.isEnabled && !isHidden,
                     "Task 04 acceptance requires one visible, enabled proposal row")
        rows[0].acceptButton.performClick(nil)
        precondition(failureLabel.isHidden, "Proposal review button must not report an error: \(failureLabel.stringValue)")
    }
}
#endif
