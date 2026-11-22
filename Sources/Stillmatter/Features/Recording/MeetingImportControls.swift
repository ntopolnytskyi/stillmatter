import AppKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import StillmatterCore
#endif

/// A preparation operation stays bound to the service captured when its picker opens.
final class MeetingImportControls: NSStackView {
    let importButton: NSButton
    let cancelButton: NSButton
    let status = GraphiteFocusStatusLabel()
    let progress = GraphiteFocusProgressStatusView()
    private let serviceProvider: () -> MeetingImportService?
    private let onImported: () -> Void
    private var cancellation: JobExecutionCancellation?
    private var panel: NSOpenPanel?

    init(controls: GraphiteFocusControls, serviceProvider: @escaping () -> MeetingImportService?,
         onImported: @escaping () -> Void) {
        self.serviceProvider = serviceProvider
        self.onImported = onImported
        importButton = controls.button("Import…", identifier: "recording-import")
        cancelButton = controls.button("Cancel import", identifier: "recording-import-cancel")
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = GraphiteFocusPresentation.Space.compact
        let actions = NSStackView(views: [importButton, cancelButton])
        actions.spacing = GraphiteFocusPresentation.Space.compact
        addArrangedSubview(actions)
        addArrangedSubview(status)
        addArrangedSubview(progress)
        progress.isHidden = true
        status.setAccessibilityIdentifier("recording-import-status")
        cancelButton.isHidden = true
        importButton.target = self; importButton.action = #selector(chooseFile)
        cancelButton.target = self; cancelButton.action = #selector(cancelImport)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc func chooseFile() {
        guard cancellation == nil else { return }
        guard let service = serviceProvider() else {
            show("Import unavailable. Select a writable workspace and recording-media folder in Settings.", meaning: .attention)
            return
        }
        let picker = NSOpenPanel()
        picker.title = "Import audio or video"
        picker.prompt = "Import"
        picker.message = "Prepare a private audio copy. Your original file stays unchanged."
        picker.allowsMultipleSelection = false
        picker.canChooseDirectories = false
        picker.allowedContentTypes = MeetingImportService.supportedExtensions.compactMap { UTType(filenameExtension: $0) }
        panel = picker
        importButton.isEnabled = false
        picker.begin { [weak self] response in
            guard let self else { return }
            self.panel = nil
            self.importButton.isEnabled = true
            guard response == .OK, let url = picker.url else { return }
            self.start(url, service: service)
        }
    }

    func start(_ url: URL, service: MeetingImportService) {
        guard cancellation == nil else { return }
        let token = JobExecutionCancellation()
        cancellation = token
        importButton.isEnabled = false
        cancelButton.isHidden = false
        cancelButton.isEnabled = true
        show("Preparing \(url.lastPathComponent)…")
        progress.configure(title: "Preparing import", value: nil, valueDescription: url.lastPathComponent, colors: GraphiteFocusPresentation.Colors(environment: .system(window: window)))
        progress.isHidden = false
        progress.progressIndicator.startAnimation(nil)
        let access = url.startAccessingSecurityScopedResource()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Swift.Result { try service.importFile(url, cancelled: { token.isCancelled }, progress: { phase in
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    switch phase {
                    case .copying: self.show("Copying \(url.lastPathComponent)…")
                    case .extracting: self.show("Preparing audio from \(url.lastPathComponent)…")
                    case .prepared, .published, .enqueued:
                        self.cancelButton.isEnabled = false
                        self.show("Saving prepared Meeting…")
                    }
                }
            }) }
            if access { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let restoreFocus = self.window?.firstResponder === self.cancelButton
                self.cancellation = nil
                self.importButton.isEnabled = true
                self.cancelButton.isHidden = true
                self.progress.progressIndicator.stopAnimation(nil)
                self.progress.isHidden = true
                switch result {
                case .success: self.show("Imported \(url.lastPathComponent). Select its Meeting to follow processing.", meaning: .success)
                case let .failure(error): self.show(error.localizedDescription, meaning: .destructive)
                }
                self.onImported()
                if restoreFocus { self.window?.makeFirstResponder(self.importButton) }
            }
        }
    }

    private func show(_ text: String, meaning: GraphiteFocusStatusMeaning = .informational) {
        status.setStatus(text, meaning: meaning, colors: GraphiteFocusPresentation.Colors(environment: .system(window: window)))
    }

    @objc func cancelImport() { _ = cancellation?.cancelAndWait() }
}
