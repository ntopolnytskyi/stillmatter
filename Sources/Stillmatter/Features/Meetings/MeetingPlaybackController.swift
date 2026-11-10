import AppKit
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

/// App-layer owner of AVAudioPlayer and waveform lifetime. Presentation sees only transport values.
@MainActor
final class MeetingAudioPlaybackController: MeetingPlaybackTransport {
    private(set) var state = MeetingPlaybackTransportState()
    var onChange: ((MeetingPlaybackTransportState) -> Void)?
    private(set) var activePlayer: MeetingAudioPlayer?
    private var waveformRevision = UUID()
    private var waveforms: [MeetingPlaybackTrack: [Double]] = [:]
    #if DEBUG
    private var stopInvocations = 0
    private var playerStopInvocations = 0
    private var effectiveStops = 0
    private var diagnosticEnabled: Bool {
        ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_PLAYBACK_DIAGNOSTICS"] == "1" &&
        ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_WORKSPACE_ROOT"] != nil &&
        ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_APPLICATION_SUPPORT_ROOT"] != nil &&
        ProcessInfo.processInfo.environment["STILLMATTER_VALIDATION_RECORDING_MEDIA_ROOT"] != nil
    }
    private func trace(_ event: String) {
        guard diagnosticEnabled else { return }
        NSLog("[VALIDATION-PLAYBACK] %@ stopCalls=%d playerStopCalls=%d effectiveStops=%d", event,
              stopInvocations, playerStopInvocations, effectiveStops)
    }
    #endif

    var activeTrackCount: Int { activePlayer?.activeTrackCount ?? 0 }

    func load(_ source: MeetingPlayback) {
        let missing = [source.microphonePath, source.systemPath].compactMap { $0 }
            .contains { !FileManager.default.isReadableFile(atPath: $0) }
        if missing {
            stop()
            state = MeetingPlaybackTransportState(source: source, duration: source.durationSeconds,
                errorMessage: "Source no longer retained or readable. Playback unavailable.")
            publish()
            return
        }
        guard state.source != source || source.capability != .unavailable && activePlayer == nil && state.errorMessage != nil else { return }
        stopCurrentPlayer()
        waveformRevision = UUID()
        waveforms = [:]
        state = MeetingPlaybackTransportState(source: source, duration: source.durationSeconds)
        publish()
        guard source.capability != .unavailable else { return }
        do {
            let nextPlayer = try MeetingAudioPlayer(playback: source)
            activePlayer = nextPlayer
            #if DEBUG
            nextPlayer.onStopAttempt = { [weak self] effective in
                guard let self else { return }
                self.playerStopInvocations += 1
                if effective { self.effectiveStops += 1 }
                self.trace(effective ? "player-stopped" : "player-stop-noop")
            }
            trace("player-loaded")
            #endif
            nextPlayer.onTimeChange = { [weak self, weak nextPlayer] position, isPlaying in
                // Player commands and its timer run on the controller's main run loop.
                MainActor.assumeIsolated {
                    guard let self, let nextPlayer, self.activePlayer === nextPlayer else { return }
                    self.state = MeetingPlaybackTransportState(
                        source: source,
                        position: position,
                        duration: nextPlayer.duration,
                        isPlaying: isPlaying,
                        isAvailable: true,
                        waveform: self.state.waveform,
                        track: nextPlayer.track, speed: nextPlayer.speed
                    )
                    self.publish()
                }
            }
            state = MeetingPlaybackTransportState(source: source, duration: nextPlayer.duration, isAvailable: true)
            publish()
            loadWaveform(source, duration: nextPlayer.duration, revision: waveformRevision)
        } catch {
            state = MeetingPlaybackTransportState(source: source, duration: source.durationSeconds,
                errorMessage: "Audio cannot be prepared for playback. Inspect the Recording Bundle and its source recordings.")
            publish()
        }
    }

    func play() {
        if let source = state.source {
            let paths = [source.microphonePath, source.systemPath].compactMap { $0 }
            if paths.contains(where: { !FileManager.default.isReadableFile(atPath: $0) }) { load(source); return }
        }
        activePlayer?.play()
    }
    func pause() { activePlayer?.pause() }

    func seek(to seconds: Double) {
        guard state.isAvailable else { return }
        activePlayer?.seek(to: seconds)
    }

    func selectTrack(_ track: MeetingPlaybackTrack) {
        activePlayer?.selectTrack(track)
        updateWaveform()
    }

    func setSpeed(_ speed: Double) { activePlayer?.setSpeed(speed) }

    func stop() {
        #if DEBUG
        stopInvocations += 1
        trace("stop-requested")
        #endif
        guard activePlayer != nil || state.source != nil else { return }
        waveformRevision = UUID()
        waveforms = [:]
        stopCurrentPlayer()
        state = MeetingPlaybackTransportState()
        publish()
    }

    private func stopCurrentPlayer() {
        guard let oldPlayer = activePlayer else { return }
        activePlayer = nil
        oldPlayer.onTimeChange = nil
        #if DEBUG
        trace("replacing-or-unloading-player")
        #endif
        oldPlayer.stop()
    }

    private func loadWaveform(_ source: MeetingPlayback, duration: Double, revision: UUID) {
        let microphonePath = source.microphonePath
        let systemPath = source.systemPath
        let microphoneOffset = source.microphoneOffsetSeconds
        let systemOffset = source.systemOffsetSeconds
        Task { [weak self] in
            let samples = await Task.detached(priority: .utility) {
                sampleMeetingWaveform(microphonePath: microphonePath, systemPath: systemPath,
                    duration: duration, microphoneOffset: microphoneOffset, systemOffset: systemOffset)
            }.value
            guard let self, self.waveformRevision == revision, self.state.source == source else { return }
            self.waveforms = samples
            self.updateWaveform()
        }
    }

    private func updateWaveform() {
        state = MeetingPlaybackTransportState(source: state.source, position: state.position,
            duration: state.duration, isPlaying: state.isPlaying, isAvailable: state.isAvailable,
            waveform: waveforms[state.track] ?? [], errorMessage: state.errorMessage,
            track: state.track, speed: state.speed)
        publish()
    }

    private func publish() { onChange?(state) }
}

private func sampleMeetingWaveform(microphonePath: String?, systemPath: String?, duration: Double,
                                   microphoneOffset: Double, systemOffset: Double) -> [MeetingPlaybackTrack: [Double]] {
    let microphone: [Double] = microphonePath.map { path in
        MeetingWaveformView.sample(path: path, duration: duration, offset: microphoneOffset).map { Double($0) }
    } ?? []
    let system: [Double] = systemPath.map { path in
        MeetingWaveformView.sample(path: path, duration: duration, offset: systemOffset).map { Double($0) }
    } ?? []
    let count = max(microphone.count, system.count)
    let both = (0..<count).map { index in
        let microphoneLevel = index < microphone.count ? microphone[index] : 0
        let systemLevel = index < system.count ? system[index] : 0
        return max(microphoneLevel, systemLevel)
    }
    return [.both: both, .mine: microphone, .other: system]
}
