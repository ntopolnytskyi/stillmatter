import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
#endif

#if DEBUG
extension CaptureRecordingView {
    /// Exercises all contract states and constrained-width behavior in the whole-window harness.
    func validateFixtures() {
        let previousOperationFailure = operationFailure
        let ready = AudioCapturePreflightItem.ready(
            id: "microphone",
            title: "Microphone permission",
            detail: "Microphone access is granted."
        )
        let degraded = AudioCapturePreflightItem(
            id: "system-audio",
            title: "System audio",
            status: .degraded,
            detail: "Capture may continue with microphone audio only.",
            settingsAction: .openScreenRecordingPrivacy
        )
        let blocked = AudioCapturePreflightItem(
            id: "media-output",
            title: "Media output",
            status: .blocked,
            detail: "Choose a writable recording media location.",
            settingsAction: .chooseMediaFolder
        )

        let states: [(CaptureState, String)] = [
            (.idle, "Ready to capture"),
            (.detecting, "Detecting a Meeting signal"),
            (.starting, "Starting Capture Session"),
            (.recording, "Recording microphone + system audio"),
            (.stopping, "Stopping Capture Session"),
            (.finalizing, "Finalizing capture artifacts"),
            (.failed, "Capture failed"),
            (.recovered, "Capture recovered")
        ]
        precondition(startButton.isDescendant(of: statePanel) && stopButton.isDescendant(of: statePanel),
                     "Capture start and stop must share the status panel")
        for (state, title) in states {
            render(Presentation(
                state: state,
                stateTitle: title,
                stateDetail: stateDetail(state),
                elapsedSeconds: state == .recording ? 3_661 : 0,
                meetingPath: state == .idle || state == .detecting ? nil : "Meetings/2026/09/fixture/meeting.md",
                preflight: AudioCapturePreflightReport(items: [ready]),
                artifactRows: state == .recording
                    ? [
                        ("Microphone Track — Recording", "linear PCM recovery, 48000 Hz", .attention),
                        ("System Audio Track — Recording", "linear PCM recovery, 48000 Hz", .attention)
                    ]
                    : [],
                failureMessage: state == .failed ? "Fixture recorder failure" : nil,
                isConfigured: true,
                canRegenerateTranscript: state == .recovered
            ))
            precondition(statusLabel.stringValue == title, "Capture fixture did not render \(state.rawValue)")
            precondition(!stateSymbolLabel.stringValue.isEmpty, "Capture state requires a non-color cue")
            precondition(startButton.isHidden == ![.idle, .detecting, .failed, .recovered].contains(state),
                         "Start must appear only when a new capture can begin")
            precondition(stopButton.isHidden == (state != .recording),
                         "Stop must replace Start in the status panel while recording")
        }

        render(Presentation(
            state: nil,
            stateTitle: "Capture unavailable",
            stateDetail: "Choose an Stillmatter root in Settings.",
            elapsedSeconds: 0,
            meetingPath: nil,
            preflight: nil,
            artifactRows: [],
            failureMessage: nil,
            isConfigured: false,
            canRegenerateTranscript: false
        ))
        precondition(renderedPreflightCount == 1 && !startButton.isEnabled, "Unconfigured capture must offer a Settings route")

        render(Presentation(
            state: .failed,
            stateTitle: "Capture failed",
            stateDetail: stateDetail(.failed),
            elapsedSeconds: 0,
            meetingPath: nil,
            preflight: AudioCapturePreflightReport(items: [ready, blocked]),
            artifactRows: [],
            failureMessage: "Preflight blocked capture.",
            isConfigured: true,
            canRegenerateTranscript: false
        ))
        precondition(renderedPreflightCount == 2 && !errorLabel.isHidden, "Blocked Preflight must expose findings and failure details")

        render(Presentation(
            state: .recording,
            stateTitle: "Recording microphone only",
            stateDetail: stateDetail(.recording),
            elapsedSeconds: 125,
            meetingPath: "Meetings/2026/09/fixture/meeting.md",
            preflight: AudioCapturePreflightReport(items: [ready, degraded]),
            artifactRows: [
                ("Microphone Track — Recording", "linear PCM recovery, 48000 Hz", .attention),
                ("System Audio Track — Unavailable", "Microphone-only Capture Session.", .attention)
            ],
            failureMessage: nil,
            isConfigured: true,
            canRegenerateTranscript: false
        ))
        precondition(renderedPreflightCount == 2 && stopButton.isEnabled && noteField.isEnabled, "Degraded recording must preserve capture and live notes")
        operationFailure = "Could not update capture: fixture write failure"
        refresh(isVisible: true)
        precondition(!errorLabel.isHidden && errorLabel.stringValue.contains("fixture write failure"), "Operation failures must survive a timed refresh")
        operationFailure = previousOperationFailure

        render(Presentation(
            state: .finalizing,
            stateTitle: "Finalizing capture artifacts",
            stateDetail: stateDetail(.finalizing),
            elapsedSeconds: 125,
            meetingPath: "Meetings/2026/09/fixture/meeting.md",
            preflight: AudioCapturePreflightReport(items: [ready]),
            artifactRows: [
                ("Microphone Track — Completed", "mic.m4a", .success),
                ("System Audio Track — Completed", "system.m4a", .success),
                ("Recording Bundle — Ready", "recording-bundle.json", .success),
                ("Transcript", "Job queued", .informational),
                ("Summary", "Waiting for Transcript", .informational),
                ("Job", "Processing", .attention)
            ],
            failureMessage: nil,
            isConfigured: true,
            canRegenerateTranscript: true
        ))
        precondition(Set(renderedArtifactTitles).isSuperset(of: [
            "Microphone Track — Completed", "System Audio Track — Completed", "Recording Bundle — Ready",
            "Transcript", "Summary", "Job"
        ]), "Processing fixture must expose every artifact role")

        artifactsDisclosure.state = .on
        toggleArtifacts(artifactsDisclosure)
        teamsDisclosure.state = .on
        toggleTeams(teamsDisclosure)
        frame = NSRect(x: 0, y: 0, width: 420, height: fittingSize.height)
        layoutSubtreeIfNeeded()
        precondition(contentStack.frame.width <= bounds.width + 1, "Capture workspace must not force a narrow detail canvas wider")
        precondition(elapsedLabel.stringValue == "00:02:05", "Elapsed time must use stable HH:MM:SS formatting")
        precondition(!artifactsContainer.isHidden && !teamsContainer.isHidden, "Supporting evidence must remain reachable")

        artifactsDisclosure.state = .off
        toggleArtifacts(artifactsDisclosure)
        teamsDisclosure.state = .off
        toggleTeams(teamsDisclosure)
        refresh(isVisible: true)
        print("TASK09_CAPTURE synthetic walkthrough passed (DEBUG)")
        fflush(stdout)
    }
}
#endif
