import AppKit
import UserNotifications
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Owns attention routing and system delivery; AppDelegate supplies the domain
/// actions without depending on notification identifiers or focus policy.
final class AppAttentionController: NSObject, UNUserNotificationCenterDelegate {
    private let inbox: () -> TasksInbox?
    private let onPopup: (AttentionTarget) -> Void
    private let onOpen: (AttentionTarget) -> Void
    private let notice = AttentionNoticeWindowController()
    private var observedInboxIDs: Set<String> = []
    private var meetingActive = false
    private lazy var delivery = AttentionDeliveryCoordinator { [weak self] event in
        self?.deliver(event)
    }

    init(inbox: @escaping () -> TasksInbox?, onPopup: @escaping (AttentionTarget) -> Void,
         onOpen: @escaping (AttentionTarget) -> Void) {
        self.inbox = inbox
        self.onPopup = onPopup
        self.onOpen = onOpen
        super.init()
        notice.onOpen = onOpen
    }

    func start() {
        UNUserNotificationCenter.current().delegate = self
    }

    func setEnvironment(meetingActive: Bool, focusedWindow: NSWindow?) {
        self.meetingActive = meetingActive
        if meetingActive || focusedWindow == nil { notice.dismiss() }
        notice.focusedWindow = focusedWindow
        delivery.setEnvironment(isMeetingOrRecordingActive: meetingActive, isAppFocused: focusedWindow != nil)
    }

    func offer(_ request: AttentionRequest) {
        delivery.offer(request)
    }

    func clear(_ target: AttentionTarget) {
        delivery.clear(target)
        notice.remove(target)
    }

    func refreshInbox(titleEligible: (InboxItem) -> Bool) {
        guard let inbox = inbox() else { return }
        do {
            let items = try inbox.items()
            let currentIDs = Set(items.map(\.id))
            for id in observedInboxIDs.subtracting(currentIDs) {
                clear(.inboxItem(id))
                clear(.titleReview(id))
            }
            observedInboxIDs = currentIDs
            for item in items where item.category == .attention {
                offer(AttentionRequest(target: .inboxItem(item.id), title: item.title, kind: .attention))
            }
            if let title = items.first(where: titleEligible) {
                offer(AttentionRequest(target: .titleReview(title.id), title: "Review meeting title", kind: .required))
            }
        } catch {
            NSLog("Could not load Inbox attention: \(error)")
        }
    }

    private func deliver(_ event: AttentionDelivery) {
        switch event {
        case let .popup(target): onPopup(target)
        case let .inline(request): notice.present(request)
        case let .notification(request): sendNotification(request)
        }
    }

    private func sendNotification(_ request: AttentionRequest) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
                    if let error = error { NSLog("Notification permission failed: \(error)") }
                    if granted { self?.postNotification(request, center: center) }
                }
            } else if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                self?.postNotification(request, center: center)
            }
        }
    }

    private func postNotification(_ request: AttentionRequest, center: UNUserNotificationCenter) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Authorization may have completed after capture started. Requeue
            // rather than allow a stale non-critical banner into a Meeting.
            if self.meetingActive && request.kind != .recordingCritical {
                self.delivery.clear(request.target)
                self.delivery.offer(request)
                return
            }
            guard let data = try? JSONEncoder().encode(request.target) else { return }
            let token = data.base64EncodedString()
            let content = UNMutableNotificationContent()
            content.title = request.title
            content.body = request.kind == .recordingCritical
                ? "Open Stillmatter to inspect recording status and recovery options."
                : "Open Stillmatter to review this item."
            content.sound = .default
            content.userInfo = ["attentionTarget": token]
            center.add(UNNotificationRequest(identifier: "stillmatter:\(token)", content: content, trigger: nil)) { error in
                if let error = error { NSLog("Could not send attention notification: \(error)") }
            }
        }
    }

    private func target(from notification: UNNotification) -> AttentionTarget? {
        guard let token = notification.request.content.userInfo["attentionTarget"] as? String,
              let data = Data(base64Encoded: token) else { return nil }
        return try? JSONDecoder().decode(AttentionTarget.self, from: data)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if case .captureFailure = target(from: notification) {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let target = target(from: response.notification)
        DispatchQueue.main.async { [weak self] in
            if let target = target { self?.onOpen(target) }
            completionHandler()
        }
    }
}

/// Non-modal, non-activating focused-app notice. Items remain actionable in
/// Today even after this transient surface is dismissed.
private final class AttentionNoticeWindowController: NSObject {
    var onOpen: ((AttentionTarget) -> Void)?
    private var queued: [AttentionRequest] = []
    private var panel: NSPanel?
    weak var focusedWindow: NSWindow?

    func present(_ request: AttentionRequest) {
        queued.append(request)
        showNext()
    }

    func remove(_ target: AttentionTarget) {
        if queued.first?.target == target { panel?.orderOut(nil); panel = nil }
        queued.removeAll { $0.target == target }
        showNext()
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
        queued.removeAll()
    }

    private func showNext() {
        guard panel == nil, let request = queued.first, let parent = focusedWindow else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 132),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Stillmatter Attention"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let label = NSTextField(wrappingLabelWithString: request.title)
        label.font = GraphiteFocusPresentation.Typography.body
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        let open = NSButton(title: "Open", target: self, action: #selector(openCurrent))
        open.translatesAutoresizingMaskIntoConstraints = false
        let later = NSButton(title: "Later", target: self, action: #selector(closeCurrent))
        later.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        GraphiteFocusPresentation.applyDarkAppearance(to: content)
        [label, open, later].forEach(content.addSubview)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            label.bottomAnchor.constraint(lessThanOrEqualTo: open.topAnchor, constant: -8),
            open.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            open.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            later.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -8),
            later.bottomAnchor.constraint(equalTo: open.bottomAnchor)
        ])
        let visible = parent.screen?.visibleFrame ?? parent.frame
        panel.setFrameTopLeftPoint(NSPoint(
            x: max(visible.minX, min(parent.frame.maxX - 376, visible.maxX - 360)),
            y: min(parent.frame.maxY - 36, visible.maxY)
        ))
        panel.orderFront(nil)
        self.panel = panel
    }

    @objc private func openCurrent() {
        guard let target = queued.first?.target else { return }
        closeCurrent()
        onOpen?(target)
    }

    @objc private func closeCurrent() {
        panel?.orderOut(nil)
        panel = nil
        if !queued.isEmpty { queued.removeFirst() }
        showNext()
    }
}
