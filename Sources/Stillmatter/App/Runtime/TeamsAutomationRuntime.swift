import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Owns detection, policy decisions, Ask consent and policy-owned capture.
/// Manual capture revokes automation for that call without changing native menu actions.
final class TeamsAutomationRuntime {
    private let monitor = MacTeamsDetectionMonitor()
    private let policy = TeamsRecordingPolicy()
    private let mode: () -> TeamsRecordingMode
    private let capture: () -> MeetingCaptureService?
    private let askWindow: () -> NSWindow?
    private let onStatus: () -> Void
    private let onDetection: (TeamsDetectionSnapshot) -> Void
    private var lastObservation: String?
    private var lastMode: TeamsRecordingMode?
    private var askAlert: NSAlert?
    private var stopped = false
    private(set) var diagnostic = "No capture decision yet"
    var snapshot: TeamsDetectionSnapshot { monitor.snapshot }

    init(mode: @escaping () -> TeamsRecordingMode, capture: @escaping () -> MeetingCaptureService?,
         askWindow: @escaping () -> NSWindow?, onStatus: @escaping () -> Void,
         onDetection: @escaping (TeamsDetectionSnapshot) -> Void) {
        self.mode = mode
        self.capture = capture
        self.askWindow = askWindow
        self.onStatus = onStatus
        self.onDetection = onDetection
    }

    func start(polling: Bool = true) {
        monitor.observe { [weak self] snapshot in
            guard let self, !self.stopped else { return }
            // Reconcile before publishing detection; a confirmed call end flushes capture now.
            self.reconcile(snapshot)
            self.onDetection(snapshot)
            self.onStatus()
        }
        if polling { monitor.start() }
    }

    func stop() {
        stopped = true
        monitor.stop()
        dismissAsk()
    }

    func reconcileCurrent() { reconcile(snapshot) }

    #if DEBUG
    var hasPendingFixtureAsk: Bool { askAlert != nil }
    func observeFixture(_ detection: TeamsDetectionSnapshot) {
        precondition(ProcessInfo.processInfo.environment["STILLMATTER_TASK05_LIFECYCLE"] != nil)
        reconcile(detection)
    }
    #endif

    func manualOverride() {
        policy.manualOverride()
        dismissAsk()
        diagnostic = "Manual capture override; detection will not control this call"
        NSLog("Teams capture: \(diagnostic)")
        onStatus()
    }

    private func dismissAsk() {
        if let alert = askAlert {
            askAlert = nil
            alert.window.sheetParent?.endSheet(alert.window)
        }
    }

    private func reconcile(_ detection: TeamsDetectionSnapshot) {
        guard !stopped else { return }
        if detection.diagnosticSummary != lastObservation {
            lastObservation = detection.diagnosticSummary
            NSLog("Teams detection: \(detection.diagnosticSummary)")
        }
        let currentMode = mode()
        if !detection.isMeetingDetected || (lastMode != nil && lastMode != currentMode) { dismissAsk() }
        if lastMode != nil && lastMode != currentMode {
            _ = policy.answerAsk(accepted: false, captureState: capture()?.snapshot.state ?? .idle)
        }
        lastMode = currentMode
        perform(policy.observe(detection, mode: currentMode,
                               captureState: capture()?.snapshot.state ?? .idle), detection: detection)
    }

    private func perform(_ action: TeamsRecordingAction, detection: TeamsDetectionSnapshot) {
        guard !stopped, action != .none else { return }
        diagnostic = "\(action) — \(detection.diagnosticSummary)"
        NSLog("Teams capture decision: \(diagnostic)")
        onStatus()
        switch action {
        case .none: break
        case .ask:
            guard let window = askWindow() else { return }
            let alert = NSAlert()
            alert.messageText = "Record this Teams meeting?"
            alert.informativeText = "A native Teams call was detected. Capture preflight will run before creating a Meeting."
            alert.addButton(withTitle: "Start Recording")
            alert.addButton(withTitle: "Not Now")
            askAlert = alert
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self, !self.stopped, self.askAlert === alert else { return }
                self.askAlert = nil
                let current = self.snapshot
                if !current.isMeetingDetected || self.mode() != .ask {
                    _ = self.policy.answerAsk(accepted: false, captureState: self.capture()?.snapshot.state ?? .idle)
                    return
                }
                let consent = self.policy.answerAsk(accepted: response == .alertFirstButtonReturn,
                                                     captureState: self.capture()?.snapshot.state ?? .idle)
                self.perform(consent, detection: current)
            }
        case .start:
            guard let service = capture() else {
                policy.recordStartFailed()
                diagnostic = "Cannot start: configure the Stillmatter root and recording media in Settings"
                NSLog("Teams capture: \(diagnostic)")
                return
            }
            do {
                _ = try service.startManual()
                policy.recordStartSucceeded()
                diagnostic = "Started automatic/approved Teams recording"
                NSLog("Teams capture: \(diagnostic)")
            } catch {
                policy.recordStartFailed()
                diagnostic = "Start failed: \(error) — check recording Settings and preflight"
                NSLog("Teams capture: \(diagnostic)")
                NSApp.requestUserAttention(.criticalRequest)
            }
        case .stop:
            guard let service = capture(), service.snapshot.state == .recording else { return }
            service.stopManualAsync { [weak self] result in
                guard let self, !self.stopped else { return }
                switch result {
                case .success: self.diagnostic = "Stopped policy-owned Teams recording after confirmed call end"
                case let .failure(error):
                    self.diagnostic = "Stop failed: \(error) — inspect recording artifacts and retry manually"
                    NSApp.requestUserAttention(.criticalRequest)
                }
                NSLog("Teams capture: \(self.diagnostic)")
                self.onStatus()
            }
        }
        onStatus()
    }
}
