import Foundation
import AVFoundation

/// Read-only resolution of retained Meeting evidence. Each read verifies current files;
/// no cached result can authorize audio that has since changed.
struct MeetingPlaybackEvidence {
    struct Resolution {
        let playback: MeetingPlayback
        let transcript: [MeetingTranscriptSegment]
        let bundleArtifact: MeetingArtifact
        let sourceArtifacts: [MeetingArtifact]
    }

    let recordingMediaURL: URL?

    /// Listing duration is recorded metadata, not decoded playback or gap duration.
    func recordedDuration(bundlePath: String?, meetingPath: String, session: String?) -> Double? {
        guard let bundlePath,
              let bundle = locatedBundle(path: bundlePath, meetingPath: meetingPath, session: session)?.0,
              bundle.meetingRelativePath == meetingPath,
              bundle.schemaVersion == RecordingBundle.currentSchemaVersion else { return nil }
        return max(bundle.mic.durationSeconds, bundle.system?.durationSeconds ?? 0)
    }

    func resolve(doorwayText: String, meetingPath: String, transcript: TranscriptDocument?) -> Resolution {
        let metadata = MeetingDoorwayMetadata(doorwayText)
        let bundlePath = metadata.bundlePath
        let located = bundlePath.flatMap {
            locatedBundle(path: $0, meetingPath: meetingPath, session: metadata.sessionID)
        }
        let playback = resolvePlayback(bundlePath: bundlePath, path: meetingPath,
                                       session: metadata.sessionID, located: located)
        let actualBundlePath = located.flatMap { match in
            match.1?.appendingPathComponent("recording-bundle.json").path ?? bundlePath
        }
        let bundleAvailable = actualBundlePath.map { FileManager.default.isReadableFile(atPath: $0) } ?? false
        let bundleArtifact = MeetingArtifact(role: .recordingBundle,
            relativePath: actualBundlePath ?? bundlePath ?? "", available: bundleAvailable,
            message: bundleAvailable ? nil : "Recording Bundle unavailable")
        return Resolution(playback: playback, transcript: makeTranscriptSegments(transcript, playback: playback),
                          bundleArtifact: bundleArtifact, sourceArtifacts: sourceArtifacts(located: located, playback: playback))
    }

    private func sourceArtifacts(located: (RecordingBundle, URL?)?, playback: MeetingPlayback) -> [MeetingArtifact] {
        var artifacts: [MeetingArtifact] = []
        // Recording Bundle paths are absolute media paths, not fabricated workspace-relative paths.
        let bundle = located?.0
        for track in [bundle?.mic, bundle?.system].compactMap({ $0 }) {
            let mediaPath = track.role != "system-audio" ? (playback.microphonePath ?? track.preferredAudioFilePath)
                : (playback.systemPath ?? track.preferredAudioFilePath)
            let available = FileManager.default.isReadableFile(atPath: mediaPath)
            artifacts.append(MeetingArtifact(role: .source, relativePath: mediaPath, available: available,
                                             message: available ? nil : "\(track.role) audio unavailable"))
        }
        if bundle == nil {
            artifacts.append(MeetingArtifact(role: .source, relativePath: "", available: false, message: "Recording media unavailable"))
        }
        return artifacts
    }

    private func makeTranscriptSegments(_ document: TranscriptDocument?, playback: MeetingPlayback) -> [MeetingTranscriptSegment] {
        guard let document else { return [] }
        let ordered: [TranscriptSegment] = document.segments.sorted(by: { $0.startSeconds < $1.startSeconds })
        var result: [MeetingTranscriptSegment] = []
        for segment in ordered {
            let offset = segment.track != .systemAudio ? playback.microphoneOffsetSeconds : playback.systemOffsetSeconds
            let start = segment.startSeconds + offset
            let end = segment.endSeconds + offset
            let valid = start.isFinite && end.isFinite && segment.startSeconds >= 0 && end >= start && end <= playback.durationSeconds
            let timeline = segment.track != .systemAudio ? playback.microphoneRanges : playback.systemRanges
            let mapped: [Range<Double>]
            let target: Double?
            if !playback.microphoneRanges.isEmpty {
                let fileEnd = timeline.last?.fileEnd ?? 0
                if segment.startSeconds >= 0, segment.startSeconds <= segment.endSeconds, segment.endSeconds <= fileEnd {
                    mapped = MeetingPlaybackRange.project(segment.startSeconds..<segment.endSeconds, through: timeline)
                } else {
                    mapped = []
                }
                target = mapped.first?.lowerBound
            } else {
                mapped = []
                target = playback.capability != .unavailable && valid ? start : nil
            }
            result.append(MeetingTranscriptSegment(id: segment.id, startSeconds: segment.startSeconds, endSeconds: segment.endSeconds,
                track: segment.track.speakerLabel, speaker: segment.speaker, text: segment.text, seekSeconds: target, playbackRanges: mapped))
        }
        return result
    }
    /// A moved media root may leave absolute bundle and track paths stale. Never scan for
    /// arbitrary audio: require exactly one sidecar with the doorway's original bundle path,
    /// meeting identity, and (when present) capture session before validating each track.
    private func locatedBundle(path: String, meetingPath: String, session: String?) -> (RecordingBundle, URL?)? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
            return (try? decoder.decode(RecordingBundle.self, from: data)).map { ($0, nil) }
        }
        guard let media = recordingMediaURL,
              let walker = FileManager.default.enumerator(at: media, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        let originalFolder = URL(fileURLWithPath: path).deletingLastPathComponent()
        var match: (RecordingBundle, URL?)?
        for case let candidate as URL in walker where candidate.lastPathComponent == "recording-bundle.json" &&
            candidate.deletingLastPathComponent().lastPathComponent == originalFolder.lastPathComponent {
            guard let data = try? Data(contentsOf: candidate),
                  let bundle = try? decoder.decode(RecordingBundle.self, from: data),
                  bundle.bundleFilePath == path, bundle.meetingRelativePath == meetingPath,
                  session == nil || bundle.captureSessionID == session else { continue }
            if match != nil { return nil } // Ambiguous relocation: refuse to select either copy.
            match = (bundle, candidate.deletingLastPathComponent())
        }
        return match
    }

    private func resolvePlayback(bundlePath: String?, path: String, session: String?, located: (RecordingBundle, URL?)?) -> MeetingPlayback {
        func unavailable(_ reason: String) -> MeetingPlayback { MeetingPlayback(capability: .unavailable, message: reason) }
        guard let bundlePath, !bundlePath.isEmpty else {
            return unavailable("Recording Bundle unavailable. Check the recording media location.")
        }
        guard let (bundle, relocated) = located else {
            return unavailable(FileManager.default.fileExists(atPath: bundlePath)
                ? "Recording Bundle invalid. Inspect the source file."
                : "Recording Bundle unavailable. Check the recording media location.")
        }
        guard bundle.bundleFilePath == bundlePath,
              bundle.meetingRelativePath == path,
              session == nil || bundle.captureSessionID == session,
              bundle.schemaVersion == RecordingBundle.currentSchemaVersion else {
            return unavailable("Recording Bundle does not match this Meeting or its supported version.")
        }
        // The optional System Audio Track must not make sound microphone evidence unusable.
        // Check the required evidence independently before attempting full bundle validation.
        let finalizer = RecordingBundleFinalizer()
        func verifiedAudio(_ track: RecordingBundleTrack) -> String? {
            if let relocated {
                return try? finalizer.validatedRelocatedAudio(track: track,
                    originalDirectory: URL(fileURLWithPath: bundlePath).deletingLastPathComponent(),
                    relocatedDirectory: relocated)
            }
            return Self.hasIntactEvidence(track) ? track.preferredAudioFilePath : nil
        }
        let mic = bundle.mic
        guard ["microphone", "imported-audio"].contains(mic.role), let micPath = verifiedAudio(mic),
              let micDuration = Self.audioDuration(micPath) else {
            return unavailable("Microphone audio missing, changed, or cannot be decoded. Inspect the Recording Bundle.")
        }
        let system = bundle.system
        let systemPath = system.flatMap { $0.role == "system-audio" ? verifiedAudio($0) : nil }
        let systemDuration = systemPath.flatMap(Self.audioDuration)
        let mixed = systemDuration != nil
        // Validate the entire original bundle when mixing tracks; relocated tracks were
        // independently checked against their recorded existence and hashes above.
        if mixed && relocated == nil && (try? finalizer.validate(bundle)) == nil {
            return unavailable("Recording Bundle validation failed. Inspect the source recordings.")
        }
        let optionalSystemSpans: [AudioClockSpan]? = mixed ? system.flatMap { Self.playbackClockSpans($0, relocated: relocated) } : []
        guard let micSpans = Self.playbackClockSpans(mic, relocated: relocated), let systemSpans = optionalSystemSpans else {
            return unavailable("Playback unavailable: recording timing metadata is malformed or unreadable. Original evidence is preserved.")
        }
        guard let micRanges = MeetingPlaybackRange.trackRanges(micSpans, duration: micDuration),
              let systemRanges = MeetingPlaybackRange.trackRanges(systemSpans, duration: systemDuration ?? 0) else {
            return unavailable("Playback unavailable: invalid clock anchors. Original evidence is preserved.")
        }
        let hasGaps = micRanges.count > 1 || systemRanges.count > 1
        if hasGaps && mixed && (micSpans.isEmpty || systemSpans.isEmpty) {
            return unavailable("Playback unavailable: both tracks need clock anchors to align across a capture gap.")
        }
        let partial = bundle.state == .partial
        let offsets: (mic: Double, system: Double)
        if mixed { offsets = Self.playbackOffsets(mic: micSpans, system: systemSpans) }
        else { offsets = (0, 0) }
        return MeetingPlayback(capability: mixed ? .mixed : .microphoneOnly,
            microphonePath: micPath,
            systemPath: mixed ? systemPath : nil,
            durationSeconds: max(offsets.mic + (micRanges.last?.timelineEnd ?? 0),
                                 offsets.system + (systemRanges.last?.timelineEnd ?? 0)),
            microphoneOffsetSeconds: offsets.mic, systemOffsetSeconds: offsets.system,
            microphoneRanges: hasGaps ? micRanges.map { $0.shifted(by: offsets.mic) } : [],
            systemRanges: hasGaps && mixed ? systemRanges.map { $0.shifted(by: offsets.system) } : [],
            message: mic.role == "imported-audio" ? "Imported audio" : mixed ? (partial ? "Microphone and system audio (partial recording)" : "Microphone and system audio")
                : (partial ? "Partial recording: microphone-only audio; system audio unavailable." : "Microphone-only audio; system audio unavailable."))
    }

    private static func playbackClockSpans(_ track: RecordingBundleTrack, relocated: URL?) -> [AudioClockSpan]? {
        struct Timing: Decodable { let audioClockSpans: [AudioClockSpan]? }
        let original = URL(fileURLWithPath: track.metadataFilePath)
        let url = relocated?.appendingPathComponent(original.lastPathComponent) ?? original
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let timing = try? decoder.decode(Timing.self, from: data) else { return nil }
        return timing.audioClockSpans ?? []
    }

    private static func playbackOffsets(mic: [AudioClockSpan], system: [AudioClockSpan]) -> (mic: Double, system: Double) {
        guard let micFirst = mic.first, let systemFirst = system.first else { return (0, 0) }
        let micZero = micFirst.hostStart - Double(micFirst.startFrame) / micFirst.sampleRate
        let systemZero = systemFirst.hostStart - Double(systemFirst.startFrame) / systemFirst.sampleRate
        let start = min(micZero, systemZero)
        return (max(0, micZero - start), max(0, systemZero - start))
    }

    private static func hasIntactEvidence(_ track: RecordingBundleTrack) -> Bool {
        (try? RecordingBundleFinalizer().validate(track: track)) != nil
    }

    private static func audioDuration(_ path: String) -> Double? {
        guard FileManager.default.isReadableFile(atPath: path),
              let audio = try? AVAudioFile(forReading: URL(fileURLWithPath: path)), audio.length > 0,
              audio.processingFormat.sampleRate > 0 else { return nil }
        return Double(audio.length) / audio.processingFormat.sampleRate
    }

}
