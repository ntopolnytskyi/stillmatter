import AVFoundation
#if SWIFT_PACKAGE
import StillmatterCore
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
    let duration: Double
    var onTimeChange: ((Double, Bool) -> Void)?
    var isPlaying: Bool { playing }
    var activeTrackCount: Int { players.filter(\.isPlaying).count }
    var elapsed: Double { playing ? min(duration, max(position, position + clock.deviceCurrentTime - deviceStart)) : position }

    init(playback: MeetingPlayback) throws {
        guard let microphone = playback.microphonePath else { throw PlayerError.unavailable }
        let paths = [microphone, playback.systemPath].compactMap { $0 }
        let prepared = try paths.map { path -> AVAudioPlayer in
            let player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path))
            guard player.duration.isFinite, player.duration > 0, player.prepareToPlay() else {
                throw PlayerError.unavailable
            }
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
        if elapsed >= duration - 0.01 { seek(to: 0) }
        let start = clock.deviceCurrentTime + 0.05
        let current = elapsed
        let active = players.indices.filter { current < offsets[$0] + players[$0].duration }
        guard !active.isEmpty else { return }
        let started = active.map { index in
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
                self.onTimeChange?(self.duration, false)
            } else {
                self.onTimeChange?(self.elapsed, true)
            }
        }
    }

    func pause() {
        position = elapsed
        players.forEach { $0.pause() }
        playing = false
        timer?.invalidate()
        timer = nil
        onTimeChange?(position, false)
    }

    func seek(to seconds: Double) {
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
        timer?.invalidate()
        timer = nil
        players.forEach { $0.stop() }
        playing = false
        onTimeChange = nil
    }

    deinit { stop() }
    enum PlayerError: Error { case unavailable }
}
