import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Owns event selection and keyboard/focus lifecycle; canonical writes stay in the Meeting model.
@MainActor
final class MeetingCalendarEditPanel: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220), styleMask: [.titled], backing: .buffered, defer: false)
    private let controls = GraphiteFocusControls()
    private let status = NSTextField(wrappingLabelWithString: "")
    private(set) lazy var picker = controls.popup(identifier: "meeting-calendar-events")
    private(set) lazy var reset = controls.checkbox("Reset title to calendar title or fallback", identifier: "meeting-calendar-reset-title")
    private(set) lazy var link = controls.button("Link selected event", identifier: "meeting-calendar-link", target: self, action: #selector(saveLink))
    private(set) lazy var unlink = controls.button("Unlink", identifier: "meeting-calendar-unlink", target: self, action: #selector(saveUnlink))
    private(set) lazy var cancelButton = controls.button("Cancel", identifier: "meeting-calendar-cancel", target: self, action: #selector(cancel))
    private var events: [CalendarMeeting] = []
    private weak var parent: NSWindow?
    private weak var previousResponder: NSResponder?
    private var completion: ((CalendarMeeting?, Bool) -> Void)?
    var isOpen: Bool { parent != nil }

    override init() {
        super.init()
        panel.title = "Calendar association"
        panel.isReleasedWhenClosed = false
        picker.setAccessibilityLabel("Calendar event")
        status.font = GraphiteFocusPresentation.Typography.metadata
        cancelButton.keyEquivalent = "\u{1b}"
        link.keyEquivalent = "\r"
        let actions = NSStackView(views: [unlink, NSView(), cancelButton, link])
        actions.spacing = GraphiteFocusPresentation.Space.compact
        let layout = NSStackView(views: [status, picker, reset, actions])
        layout.orientation = .vertical
        layout.alignment = .leading
        layout.spacing = GraphiteFocusPresentation.Space.compact
        layout.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: GraphiteFocusPresentation.Space.page),
            layout.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -GraphiteFocusPresentation.Space.page),
            layout.topAnchor.constraint(equalTo: panel.contentView!.topAnchor, constant: GraphiteFocusPresentation.Space.page),
            layout.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor, constant: -GraphiteFocusPresentation.Space.page),
            status.widthAnchor.constraint(equalTo: layout.widthAnchor),
            picker.widthAnchor.constraint(equalTo: layout.widthAnchor),
            actions.widthAnchor.constraint(equalTo: layout.widthAnchor)
        ])
    }

    func present(over window: NSWindow, snapshot: CalendarMeetingSnapshot, context: MeetingCalendarContext?,
                 completion: @escaping (CalendarMeeting?, Bool) -> Void) {
        guard !isOpen else { return }
        previousResponder = window.firstResponder
        parent = window
        self.completion = completion
        events = snapshot.events.filter { $0.eventIdentifier != nil && $0.calendarIdentifier != nil }
        status.stringValue = snapshot.status + "\nManual titles stay unless Reset title is selected."
        picker.removeAllItems()
        for (index, event) in events.enumerated() {
            let scheduled = event.eventStart.map { DateFormatter.localizedString(from: $0, dateStyle: .short, timeStyle: .short) } ?? "Unknown time"
            picker.addItem(withTitle: "\(event.title) · \(scheduled) · \(index + 1)")
        }
        if let event = context?.event, let index = events.firstIndex(of: event) { picker.selectItem(at: index) }
        reset.state = .off
        link.isEnabled = !events.isEmpty
        unlink.isEnabled = context?.event != nil
        window.beginSheet(panel)
        panel.makeFirstResponder(events.isEmpty ? cancelButton : picker)
    }

    @objc private func saveLink() {
        guard events.indices.contains(picker.indexOfSelectedItem) else { return }
        finish(event: events[picker.indexOfSelectedItem])
    }

    @objc private func saveUnlink() { finish(event: nil) }

    @objc func cancel() {
        completion = nil
        close()
    }

    private func finish(event: CalendarMeeting?) {
        let callback = completion
        let resetTitle = reset.state == .on
        completion = nil
        close()
        callback?(event, resetTitle)
    }

    private func close() {
        parent?.endSheet(panel)
        panel.orderOut(nil)
        parent?.makeFirstResponder(previousResponder)
        previousResponder = nil
        parent = nil
    }
}
