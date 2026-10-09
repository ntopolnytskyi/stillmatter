import AppKit
import ApplicationServices
import AVFoundation
import CoreAudio
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// Polls read-only macOS signals for native Teams meeting detection. It never invokes capture.
final class MacTeamsDetectionMonitor {
    private enum HangupObservation {
        case found
        case absent(nodes: Int)
        case failed(String)
    }

    private static let teamsBundleIdentifiers = ["com.microsoft.teams2", "com.microsoft.teams"]
    private static let hangupDOMIdentifier = "hangup-button"
    private static let maximumAXDepth = 60
    private static let maximumAXNodes = 20_000

    private let detector: TeamsDetectionService
    private let scanQueue = DispatchQueue(label: "Stillmatter.TeamsAccessibilityScan", qos: .utility)
    private var timer: Timer?
    private var isRefreshing = false
    private var observers: [(TeamsDetectionSnapshot) -> Void] = []
    private(set) var snapshot: TeamsDetectionSnapshot

    init(detector: TeamsDetectionService = TeamsDetectionService()) {
        self.detector = detector
        self.snapshot = detector.observe(TeamsDetectionObservation(
            process: .observed(false, detail: "Waiting for first process scan"),
            hangupControl: .unavailable(reason: "Waiting for first Accessibility scan"),
            microphoneActivity: .observed(false, detail: "Waiting for first input-device scan")
        ))
    }

    func start() {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func observe(_ observer: @escaping (TeamsDetectionSnapshot) -> Void) {
        observers.append(observer)
        observer(snapshot)
    }

    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let teamsApps = NSWorkspace.shared.runningApplications.filter(Self.isNativeTeams)
        let process: TeamsDetectionSignalSample = teamsApps.isEmpty
            ? .observed(false, detail: "Native Microsoft Teams is not running")
            : .observed(true, detail: teamsApps.map { "\($0.localizedName ?? "Microsoft Teams") (\($0.bundleIdentifier ?? "unknown bundle"))" }.joined(separator: ", "))
        scanQueue.async { [weak self] in
            guard let self else { return }
            let hangupControl = self.hangupControlSignal(teamsApps: teamsApps)
            let microphoneActivity = self.microphoneActivitySignal()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isRefreshing = false
                self.snapshot = self.detector.observe(TeamsDetectionObservation(
                    process: process,
                    hangupControl: hangupControl,
                    microphoneActivity: microphoneActivity
                ))
                self.observers.forEach { $0(self.snapshot) }
            }
        }
    }

    private static func isNativeTeams(_ app: NSRunningApplication) -> Bool {
        let identifier = app.bundleIdentifier?.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        return teamsBundleIdentifiers.contains(identifier) || name == "microsoft teams"
    }

    private func hangupControlSignal(teamsApps: [NSRunningApplication]) -> TeamsDetectionSignalSample {
        guard let teamsApp = teamsApps.first else {
            return .unavailable(reason: "No Teams process is available to inspect; this is not treated as a confirmed meeting end")
        }
        guard AXIsProcessTrusted() else {
            return .unavailable(reason: "Accessibility permission is required to inspect Teams for its hang-up control")
        }
        switch Self.scanForHangupControl(pid: teamsApp.processIdentifier) {
        case .found:
            return .observed(true, detail: "Teams exposes AXDOMIdentifier=hangup-button")
        case let .absent(nodes):
            return .observed(false, detail: "No Teams hang-up control found in \(nodes) accessible UI elements")
        case let .failed(message):
            return .unavailable(reason: "Teams Accessibility scan was inconclusive: \(message)")
        }
    }

    /// Traverses only the selected native Teams process. Partial AX trees are unknown,
    /// never a conclusive absence that could end a detected meeting.
    private static func scanForHangupControl(pid: pid_t) -> HangupObservation {
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 1.5)
        var stack: [(element: AXUIElement, depth: Int)] = [(root, 0)]
        var nodeCount = 0
        var failures = 0
        var successfulChildrenReads = 0

        while let current = stack.popLast() {
            nodeCount += 1
            if nodeCount > maximumAXNodes {
                return .failed("node limit exceeded")
            }

            var identifier: CFTypeRef?
            let identifierResult = AXUIElementCopyAttributeValue(
                current.element,
                "AXDOMIdentifier" as CFString,
                &identifier
            )
            if identifierResult == .success,
               let identifier = identifier as? String,
               identifier == hangupDOMIdentifier {
                var role: CFTypeRef?
                let roleResult = AXUIElementCopyAttributeValue(
                    current.element,
                    kAXRoleAttribute as CFString,
                    &role
                )
                if roleResult == .success,
                   let role = role as? String,
                   role == (kAXButtonRole as String) {
                    return .found
                }
            }

            guard current.depth < maximumAXDepth else { continue }
            var children: CFTypeRef?
            let childrenResult = AXUIElementCopyAttributeValue(
                current.element,
                kAXChildrenAttribute as CFString,
                &children
            )
            if childrenResult == .success {
                successfulChildrenReads += 1
                if let children = children as? [AXUIElement] {
                    for child in children.reversed() {
                        stack.append((child, current.depth + 1))
                    }
                }
            } else if childrenResult == .cannotComplete
                        || childrenResult == .invalidUIElement
                        || childrenResult == .failure {
                failures += 1
            }
        }

        guard failures == 0, successfulChildrenReads > 0 else {
            return .failed("incomplete tree (failures=\(failures), nodes=\(nodeCount))")
        }
        return .absent(nodes: nodeCount)
    }

    private func microphoneActivitySignal() -> TeamsDetectionSignalSample {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return .unavailable(reason: "Microphone permission is missing; meeting detection still uses the Teams hang-up control")
        }
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0,
            nil,
            &size,
            &deviceID
        ) == noErr, deviceID != 0 else {
            return .unavailable(reason: "No default input device is available")
        }
        var runningAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var running = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &runningAddress, 0, nil, &size, &running) == noErr else {
            return .unavailable(reason: "macOS could not read input-device activity")
        }
        let active = running != 0
        return .observed(
            active,
            detail: "Default input device is \(active ? "running" : "idle") (corroborating activity is not attributed to Teams)"
        )
    }
}
