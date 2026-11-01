import AppKit
import StillmatterCore

/// Test-only window containing actual form consumers. It never constructs an OS recorder.
final class ControlsTestApplication: NSObject, NSApplicationDelegate {
    let root: URL
    let scenario: String
    let settingsStore: SettingsStore
    let service: MeetingCaptureService
    let installer: TranscriptionComponentInstaller
    private var window: NSWindow!
    private var scroll: NSScrollView!
    private var recording: CaptureRecordingView!
    private var settings: SettingsFormView!
    private var settingsObserver: UUID?
    private var validationAttempts = 0

    init(root: URL, scenario: String) throws {
        self.root = root
        self.scenario = scenario
        let workspace = root.appendingPathComponent("workspace")
        let support = root.appendingPathComponent("support")
        for directory in [workspace, support, root.appendingPathComponent("media")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let suite = "works.stillmatter.controls.\(root.lastPathComponent)"
        let defaults = UserDefaults(suiteName: suite)!
        settingsStore = SettingsStore(userDefaults: defaults)
        if settingsStore.settings.stillmatterRootURL == nil {
            var initial = settingsStore.settings
            initial.stillmatterRootURL = workspace
            initial.recordingMediaURL = root.appendingPathComponent("media")
            settingsStore.settings = initial
        }
        installer = TranscriptionComponentInstaller(paths: TranscriptionComponentPaths(applicationSupportURL: support), acquirer: ControlsTestNoModelAcquirer())
        service = MeetingCaptureService(vault: WorkspaceVault(workspaceRootURL: workspace, appSupportRootURL: support),
            preflight: { .readyForTesting })
        super.init()
        if scenario == "invalid-setting" {
            settingsStore.requestWorkspace(.init(root: root.appendingPathComponent("rejected-destination"), media: nil))
            settingsStore.reportPendingWorkspaceBlocked("Invalid destination awaiting validation.")
        }
        settingsObserver = settingsStore.observeScoped { [weak self] value in
            guard let self, let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: self.root.appendingPathComponent("effective-settings.json"), options: .atomic)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        recording = CaptureRecordingView(serviceProvider: { [weak self] in
            guard let self, self.scenario != "unconfigured" else { return nil }
            return self.service
        }, rootURLProvider: { [weak self] in self?.settingsStore.settings.stillmatterRootURL },
           teamsDetectionProvider: { nil }, jobRecordsProvider: { [] }, onOpenSettings: { [weak self] in self?.showSettings(nil) })
        settings = SettingsFormView(settingsStore: settingsStore, transcriptionComponentInstaller: installer,
            onRetryPendingWorkspace: { [weak self] in
                guard let self else { return }
                self.validationAttempts += 1
                self.settingsStore.applyPendingWorkspace { _ in
                    throw NSError(domain: "ControlsTestValidation", code: self.validationAttempts,
                        userInfo: [NSLocalizedDescriptionKey: "Controlled validation failure \(self.validationAttempts)"])
                }
            })
        let rootView = NSView()
        let recordingNavigation = NSButton(title: "Recording", target: self, action: #selector(showRecording(_:)))
        recordingNavigation.setAccessibilityIdentifier("controls-nav-recording")
        let settingsNavigation = NSButton(title: "Settings", target: self, action: #selector(showSettings(_:)))
        settingsNavigation.setAccessibilityIdentifier("controls-nav-settings")
        let navigation = NSStackView(views: [recordingNavigation, settingsNavigation])
        navigation.translatesAutoresizingMaskIntoConstraints = false
        scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        rootView.addSubview(navigation)
        rootView.addSubview(scroll)
        // Settings already owns its scrolling region; give it the same viewport
        // as the real shell instead of nesting it in a content-sized scroll view.
        rootView.addSubview(settings)
        NSLayoutConstraint.activate([
            navigation.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 12),
            navigation.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
            scroll.topAnchor.constraint(equalTo: navigation.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            settings.topAnchor.constraint(equalTo: scroll.topAnchor),
            settings.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 16),
            settings.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
            settings.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
        window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1100, height: 850),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Shared Controls Test"
        window.minSize = NSSize(width: 720, height: 520)
        window.contentView = rootView
        if scenario == "invalid-setting" { showSettings(nil) } else { showRecording(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if scenario == "invalid-setting", let retry = descendants(settings).first(where: { $0.accessibilityIdentifier() == "settings-retry-workspace" }) {
            window.makeFirstResponder(retry)
        }
    }

    @objc private func showRecording(_ sender: Any?) {
        settings.isHidden = true
        scroll.isHidden = false
        recording.refresh(isVisible: true)
        show(recording)
    }

    @objc private func showSettings(_ sender: Any?) {
        recording.refresh(isVisible: false)
        settings.isHidden = false
        scroll.isHidden = true
    }

    private func show(_ view: NSView) {
        let document = NSStackView(views: [view])
        document.orientation = .vertical
        document.alignment = .width
        document.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        document.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = document
        document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        document.layoutSubtreeIfNeeded()
        document.scroll(NSPoint(x: 0, y: document.bounds.height))
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

private struct ControlsTestNoModelAcquirer: TranscriptionModelAcquiring {
    func acquireModel(_ model: TranscriptionModelChoice, in stagingURL: URL, cancellation: TranscriptionInstallCancellation,
                      progress: @escaping (TranscriptionInstallProgress) -> Void) throws -> URL {
        throw CocoaError(.featureUnsupported)
    }
}
