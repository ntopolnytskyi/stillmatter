import AppKit

final class ContextualAskService {
    enum Mode { case success, noSources, failure, invalidCitation }
    var mode: Mode = .success

    func ask(_ request: ContextualAskRequest) throws -> ContextualAskAnswer {
        Thread.sleep(forTimeInterval: 0.03)
        if mode == .failure { throw ContextualAskError.fixtureFailure }
        if mode == .invalidCitation { throw ContextualAskError.invalidCitation }
        if mode == .noSources { return ContextualAskAnswer(answer: "General guidance without workspace evidence.", citations: [], sources: []) }
        return ContextualAskAnswer(
            answer: Array(repeating: "The team decided to launch Orchid on October 20. Jordan owns preparing the release announcement.", count: 20).joined(separator: " "),
            citations: [
                ContextualAskCitation(title: "Decisions", sourcePath: "Meetings/orchid/meeting.md", transcriptStartSeconds: nil),
                ContextualAskCitation(title: "Other action items", sourcePath: "Meetings/orchid/meeting.md", transcriptStartSeconds: nil)
            ],
            sources: (0..<12).map {
                ContextualAskSource(
                    kind: SourceKind(displayName: "Transcript"),
                    sourcePath: "Meetings/2026/09/21/14-28-untitled-meeting-\($0)/transcript.json",
                    title: "Transcript 2.700s"
                )
            }
        )
    }
}

enum ContextualAskContext: CaseIterable, Equatable {
    case today
    case meetings
    case tasks
    case settings

    var displayName: String {
        switch self {
        case .today: return "Today"
        case .meetings: return "Meetings"
        case .tasks: return "Tasks"
        case .settings: return "Settings"
        }
    }
}

struct ContextualAskRequest {
    init(question: String, context: ContextualAskContext, includesBroaderVault: Bool) {}
}

struct ContextualAskAnswer {
    let answer: String
    let citations: [ContextualAskCitation]
    let sources: [ContextualAskSource]
}

struct ContextualAskCitation {
    let title: String
    let sourcePath: String
    let transcriptStartSeconds: Double?
    let transcriptEndSeconds: Double?

    init(title: String, sourcePath: String, transcriptStartSeconds: Double?, transcriptEndSeconds: Double? = nil) {
        self.title = title
        self.sourcePath = sourcePath
        self.transcriptStartSeconds = transcriptStartSeconds
        self.transcriptEndSeconds = transcriptEndSeconds
    }
}

struct ContextualAskSource {
    let kind: SourceKind
    let sourcePath: String
    let title: String
    let transcriptStartSeconds: Double?
    let transcriptEndSeconds: Double?

    init(
        kind: SourceKind,
        sourcePath: String,
        title: String,
        transcriptStartSeconds: Double? = nil,
        transcriptEndSeconds: Double? = nil
    ) {
        self.kind = kind
        self.sourcePath = sourcePath
        self.title = title
        self.transcriptStartSeconds = transcriptStartSeconds
        self.transcriptEndSeconds = transcriptEndSeconds
    }
}

struct SourceKind { let displayName: String }

enum ContextualAskError: Error, CustomStringConvertible {
    case emptyQuestion
    case fixtureFailure
    case invalidCitation
    var description: String {
        switch self {
        case .emptyQuestion: return "Enter a question first."
        case .fixtureFailure: return "Fixture request failed."
        case .invalidCitation: return "The answer cited a source that was not visible."
        }
    }
}

@main
struct ContextualAskViewLayoutHarness {
    static func main() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 520))
        let hostWindow = NSWindow(contentRect: container.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        hostWindow.contentView = container
        let service = ContextualAskService()
        var providedService: ContextualAskService? = service
        let askView = ContextualAskView(serviceProvider: { providedService })
        container.addSubview(askView)
        NSLayoutConstraint.activate([
            askView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            askView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            askView.topAnchor.constraint(equalTo: container.topAnchor, constant: 32),
            askView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -32)
        ])
        container.layoutSubtreeIfNeeded()

        guard let heading = descendants(of: askView)
            .compactMap({ $0 as? NSTextField })
            .first(where: { $0.stringValue == "Ask your workspace" }) else {
            fatalError("Ask AI heading is missing")
        }
        guard askView.frame.width > 0, askView.frame.height > 0,
              !askView.isHidden, !heading.isHidden,
              heading.frame.width > 0, heading.frame.height > 0 else {
            fatalError("Ask AI panel is not visibly laid out: panel=\(askView.frame), heading=\(heading.frame)")
        }
        let headingFrame = heading.convert(heading.bounds, to: askView)
        guard abs(headingFrame.minX) < 3 else {
            fatalError("Ask AI content must remain leading-aligned, not shifted right: heading=\(headingFrame), panel=\(askView.bounds)")
        }

        let controls = descendants(of: askView)
        guard let contextPopup = controls.compactMap({ $0 as? NSPopUpButton }).first,
              let questionField = controls.compactMap({ $0 as? NSTextField })
                .first(where: { $0.placeholderString == "Ask about the current context…" }),
              let broaderVault = controls.compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "Include broader vault" }),
              let askButton = controls.compactMap({ $0 as? NSButton })
                .first(where: { $0.title == "Ask" }),
              controls.contains(where: { $0.identifier?.rawValue == "ContextualAsk.PrivacyDisclosure" }) else {
            fatalError("Ask AI controls or privacy disclosure are missing")
        }
        broaderVault.performClick(nil)
        guard broaderVault.state == .on,
              broaderVault.accessibilityValue() as? String == "Broader vault included" else {
            fatalError("Broader-vault selection lacks an explicit accessible selected state")
        }
        questionField.stringValue = "Question"
        hostWindow.makeFirstResponder(askButton)
        askButton.performClick(nil)
        guard !askButton.isEnabled, !questionField.isEnabled,
              descendants(of: askView).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("Asking pi/Codex") }) else {
            fatalError("Asking state did not disable controls or expose static progress text")
        }
        waitUntil(in: askView) { $0.contains("Visible sources") }
        guard hostWindow.firstResponder === askButton, askButton.isEnabled, questionField.isEnabled else {
            fatalError("Completed request did not restore the invoking control and availability")
        }
        container.layoutSubtreeIfNeeded()
        let popupFrame = contextPopup.convert(contextPopup.bounds, to: askView)
        guard askView.bounds.contains(popupFrame) else {
            fatalError("Search context was laid out outside Ask AI's clickable bounds: popup=\(popupFrame), bounds=\(askView.bounds)")
        }
        let evidenceRows = descendants(of: askView).filter { $0.identifier?.rawValue == "ContextualAsk.EvidenceRow" }
        guard evidenceRows.count >= 12 else {
            fatalError("Visible sources were not rendered as structured evidence rows: \(evidenceRows.count)")
        }
        guard evidenceRows.allSatisfy({ $0.frame.width > 0 && $0.frame.height > 0 }),
              descendants(of: askView).compactMap({ $0 as? NSScrollView }).contains(where: { $0.hasVerticalScroller }) else {
            fatalError("Evidence rows are not reachable through a vertical results scroller")
        }

        service.mode = .noSources
        askButton.performClick(nil)
        waitUntil(in: askView) { $0.contains(where: { $0.contains("No workspace source matched") }) }
        service.mode = .failure
        askButton.performClick(nil)
        waitUntil(in: askView) { $0.contains(where: { $0.contains("Ask failed") }) }
        service.mode = .invalidCitation
        askButton.performClick(nil)
        waitUntil(in: askView) { $0.contains(where: { $0.contains("not visible") }) }
        providedService = nil
        questionField.stringValue = "Question"
        askButton.performClick(nil)
        guard descendants(of: askView).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("Contextual Ask is unavailable") }) else {
            fatalError("Unavailable service lacks static recovery meaning")
        }
        providedService = service
        questionField.stringValue = ""
        askButton.performClick(nil)
        guard descendants(of: askView).compactMap({ $0 as? NSTextField }).contains(where: { $0.stringValue.contains("Enter a question first") }) else {
            fatalError("Empty-question validation lacks static textual meaning")
        }
        let reducedMotion = GraphiteFocusEnvironment(increasedContrast: false, reducedTransparency: false, reducedMotion: true, activeWindow: true)
        guard GraphiteFocusPresentation.Motion.local(reducedMotion) == 0,
              GraphiteFocusPresentation.Motion.region(reducedMotion) == 0 else {
            fatalError("Reduce Motion must remove custom Contextual Ask transitions")
        }
    }

    private static func waitUntil(in view: NSView, matches: ([String]) -> Bool) {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            let values = descendants(of: view).compactMap { ($0 as? NSTextField)?.stringValue }
            if matches(values) { return }
        }
        fatalError("Timed out waiting for Contextual Ask fixture state")
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants)
    }
}
