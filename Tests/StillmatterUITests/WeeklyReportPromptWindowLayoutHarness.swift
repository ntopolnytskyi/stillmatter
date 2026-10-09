import AppKit

struct WeeklyReportDraft: Equatable {
    let id: String
    let relativePath: String
    let text: String
}

@main
struct WeeklyReportPromptWindowLayoutHarness {
    static func main() {
        _ = NSApplication.shared
        let controller = WeeklyReportPromptWindowController()
        let reportText = Array(repeating: "## Review\n\nA deliberately long editable Weekly Report paragraph.", count: 40).joined(separator: "\n\n")
        controller.present(WeeklyReportDraft(
            id: "layout-test",
            relativePath: "Briefs/Weekly/layout-test.md",
            text: reportText
        ))
        controller.window?.setContentSize(NSSize(width: 560, height: 420))
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        guard let contentView = controller.window?.contentView,
              let scrollView = descendants(of: contentView).compactMap({ $0 as? NSScrollView }).first,
              let editor = scrollView.documentView as? NSTextView,
              let contextLabel = descendants(of: contentView).compactMap({ $0 as? NSTextField })
                .first(where: { $0.identifier?.rawValue == "WeeklyReport.Context" }),
              let feedbackLabel = descendants(of: contentView).compactMap({ $0 as? NSTextField })
                .first(where: { $0.identifier?.rawValue == "WeeklyReport.Feedback" }) else {
            fatalError("Weekly Report editor is missing")
        }
        guard editor.string == reportText else {
            fatalError("Weekly Report editor did not receive long draft text")
        }
        guard editor.frame.width > 0, editor.frame.height > 0,
              contextLabel.stringValue.contains("Briefs/Weekly/layout-test.md") else {
            fatalError("Weekly Report context or minimum-size editor layout is missing")
        }

        enum SaveError: Error { case failed }
        controller.onAccept = { _ in throw SaveError.failed }
        guard let acceptButton = descendants(of: contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Accept" }),
              let remindButton = descendants(of: contentView).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Remind next time" }) else {
            fatalError("Weekly Report review actions are missing")
        }
        guard controller.window?.firstResponder === editor else {
            fatalError("Weekly Report editor must receive initial focus")
        }
        guard acceptButton.keyEquivalent == "\r",
              acceptButton.keyEquivalentModifierMask == .command,
              remindButton.keyEquivalent == "\u{1b}",
              remindButton.keyEquivalentModifierMask.isEmpty else {
            fatalError("Weekly Report must expose Command-Return Accept and Escape Remind shortcuts")
        }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.selectAll(nil)
        guard editor.selectedRange().length == (reportText as NSString).length else {
            fatalError("Command-A selection behavior is unavailable in the focused Weekly Report editor")
        }
        editor.insertText("temporary edit", replacementRange: editor.selectedRange())
        editor.undoManager?.undo()
        guard editor.string == reportText else {
            fatalError("Command-Z undo behavior is unavailable in the Weekly Report editor")
        }
        editor.string = "   "
        acceptButton.performClick(nil)
        guard feedbackLabel.stringValue.contains("Enter Weekly Report content"), controller.window?.isVisible == true else {
            fatalError("Empty Weekly Report validation is not inline and retryable")
        }
        editor.string = reportText
        acceptButton.performClick(nil)
        guard !feedbackLabel.isHidden,
              feedbackLabel.stringValue.contains("Could not save"),
              editor.string == reportText,
              controller.window?.isVisible == true else {
            fatalError("Acceptance failure did not remain inline with editable content preserved")
        }
        var reminded = false
        controller.onRemind = { reminded = true }
        remindButton.performClick(nil)
        guard reminded, controller.window?.isVisible == false else {
            fatalError("Remind next time did not produce a distinct secondary outcome")
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
