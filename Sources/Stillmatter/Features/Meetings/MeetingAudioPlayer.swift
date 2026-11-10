import AVFoundation
#if SWIFT_PACKAGE
import StillmatterCore
import StillmatterPresentation
#endif

/// Plays the immutable Recording Bundle tracks together without rendering a new media file.
final class MeetingAudioPlayer {
    private let players: [AVAudioPlayer]
    private let clock: AVAudioPlayer
    private let offsets: [Double]
    private var timer: Timer?
    private var position = 0.0
    private var deviceStart = 0.0
    private var playing = false
    private var stopped = false
    private(set) var speed = 1.0
    private(set) var track = MeetingPlaybackTrack.both
    let duration: Double
    var onTimeChange: ((Double, Bool) -> Void)?
    #if DEBUG
    /// Disposable validation hook; false includes the harmless deinit stop after an explicit stop.
    var onStopAttempt: ((Bool) -> Void)?
    #endif
    var isPlaying: Bool { playing }
    var activeTrackCount: Int { players.filter(\.isPlaying).count }
    var elapsed: Double { playing ? min(duration, max(position, position + (clock.deviceCurrentTime - deviceStart) * speed)) : position }
    var trackVolumes: [Float] { players.map(\.volume) }
    var trackPositions: [Double] { players.map(\.currentTime) }

    init(playback: MeetingPlayback) throws {
        guard let microphone = playback.microphonePath else { throw PlayerError.unavailable }
        let paths = [microphone, playback.systemPath].compactMap { $0 }
        let prepared = try paths.map { path -> AVAudioPlayer in
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else {
                throw PlayerError.unavailable
            }
            player.enableRate = true
            return player
        }
        let trackOffsets = [playback.microphoneOffsetSeconds, playback.systemPath == nil ? nil : playback.systemOffsetSeconds].compactMap { $0 }
        guard trackOffsets.count == prepared.count,
              trackOffsets.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let longestIndex = prepared.indices.max(by: { trackOffsets[$0] + prepared[$0].duration < trackOffsets[$1] + prepared[$1].duration }) else {
            throw PlayerError.unavailable
        }
        players = prepared
        offsets = trackOffsets
        clock = prepared[longestIndex]
        duration = trackOffsets[longestIndex] + clock.duration
    }

    func play() {
        guard !stopped, !playing else { return }
        if elapsed >= duration - 0.01 { seek(to: 0) }
        let start = clock.deviceCurrentTime + 0.05
        let current = elapsed
        let active = players.indices.filter { current < offsets[$0] + players[$0].duration }
        guard !active.isEmpty else { return }
        let started = active.map { index in
            // AVAudioPlayer applies its rate to the scheduled source-time delay.
            players[index].play(atTime: start + max(0, offsets[index] - current))
        }
        guard started.allSatisfy({ $0 }) else {
            players.forEach { $0.pause() }
            playing = false
            onTimeChange?(elapsed, false)
            return
        }
        position = current
        deviceStart = start
        playing = true
        onTimeChange?(elapsed, true)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.elapsed >= self.duration - 0.01 {
                self.timer?.invalidate()
                self.timer = nil
                self.playing = false
                self.position = self.duration
                self.players.forEach { $0.pause() }
                self.onTimeChange?(self.duration, false)
            } else {
                self.onTimeChange?(self.elapsed, true)
            }
        }
    }

    func pause() {
        guard !stopped else { return }
        position = elapsed
        // pause() leaves a future play(atTime:) request queued. Cancel it before
        // restoring the common source position, or an old start can move a later seek.
        for (index, player) in players.enumerated() {
            player.stop()
            player.currentTime = min(player.duration, max(0, position - offsets[index]))
            player.prepareToPlay()
        }
        playing = false
        timer?.invalidate()
        timer = nil
        onTimeChange?(position, false)
    }

    func selectTrack(_ selection: MeetingPlaybackTrack) {
        guard !stopped, selection.isAvailable(hasOtherTrack: players.count > 1) else { return }
        track = selection
        for (index, player) in players.enumerated() {
            player.volume = selection == .both || (selection == .mine ? index == 0 : index == 1) ? 1 : 0
        }
        onTimeChange?(elapsed, playing)
    }

    func setSpeed(_ value: Double) {
        guard !stopped, MeetingPlaybackTransportState.supportedSpeeds.contains(value) else { return }
        let resume = playing
        pause()
        speed = value
        players.forEach { $0.rate = Float(value) }
        if resume { seek(to: position); play() }
        else { onTimeChange?(position, false) }
    }

    func seek(to seconds: Double) {
        guard !stopped else { return }
        let target = seconds.isFinite ? min(duration, max(0, seconds)) : 0
        let wasPlaying = playing
        if wasPlaying { pause() }
        for (index, player) in players.enumerated() {
            player.currentTime = min(player.duration, max(0, target - offsets[index]))
        }
        position = target
        onTimeChange?(target, false)
        if wasPlaying && target < duration { play() }
    }

    func stop() {
        #if DEBUG
        onStopAttempt?(!stopped)
        #endif
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        players.forEach { $0.stop() }
        playing = false
        onTimeChange = nil
    }

    deinit { stop() }
    enum PlayerError: Error { case unavailable }
}
