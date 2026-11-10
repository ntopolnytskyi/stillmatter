# Ticket 22 — Transcript playback evidence

Scope: [ticket 22](../../.scratch/meeting-ai/issues/22-play-synchronized-tracks-through-the-transcript-waveform.md), based on `3686cc1f1ea3c94b315d52b2daf0d3c0c858c4de`. Dependencies 13 and 21 are resolved. The user approved controller, generated-audio hosted integration, and native UI test boundaries and this review baseline.

## Behavior

The Transcript player uses the original validated microphone and system tracks. Both / My speech / Other participants changes their volumes without replacing the player or resetting the source position. Missing Other evidence disables that choice. Speed choices are 0.5×, 1×, 1.5× and 2×. Seek and speed changes preserve playing/paused intent; Play at EOF restarts. A shared device clock accounts for track starting offsets and rate. Source files are never rewritten by playback.

The player is visible only in Transcript. It has waveform mouse/arrow-key seeking, elapsed/total time, backward/forward ten seconds, and previous/next source markers. Speech, Decisions, Actions and Questions use S/D/A/Q labels and an explicit legend; marker drawing is bounded for dense recordings while navigation retains all validated markers. Shortcuts are Option-Space (play/pause), Option-Left/Right (ten seconds), and Option-1/2/3 (tracks). They apply in the selected Meeting's Transcript workspace and exclude text editors. Native popup/slider/button keyboard behavior remains available.

Clock offsets also apply to Transcript seeks and current-phrase highlights. Saved track-local timestamps and citation identity remain unchanged. Relocated recordings read their relocated timing metadata. Waveforms are sampled once per loaded source and cached per mix. Ticks publish small transport values and update active phrase styling; they do not rebuild the Transcript or reread full audio files. An unrelated source-equivalent document refresh retains the player, position, speed and mix. Replacing a Meeting invalidates player and waveform callbacks.

## Unsupported capability — not accepted as complete

**Discontinuous capture-clock playback remains unsupported.** `AudioClockSpan` can describe host-time gaps between contiguous file frames. The existing AVAudioPlayer transport cannot insert that missing silence. Furthermore, canonical Transcript segments and speaker turns currently retain per-file times; simply adding silence to playback without mapping those source references would shift Transcript/citation navigation. This change refuses playback when supplied clock anchors contain unrepresented gaps or invalid timing instead of silently compressing the recording. It also reports malformed/unreadable metadata explicitly. Legacy recordings without clock anchors retain the existing file-timeline fallback; they do not establish measured original-clock alignment.

To finish this requirement, add a validated common-timeline projection for track-local Transcript/citation timing and a gap-aware player/composition or background bounded-memory aligned derivative, preserving originals and handling cancellation/cleanup. Tests must verify actual decoded samples and navigation on both sides of capture gaps, rate changes and Meeting replacement. File silence and starting offsets tested here do **not** prove capture-gap playback.

Ticket 22 must remain unresolved while that acceptance criterion is unmet. No source-isolation, ASR/diarization quality, real-device synchronization or other hardware capability is established by these generated fixtures.

## Verification

Final coverage, suite and independent review results are recorded below after execution. All fixtures use disposable synthetic workspace, media, support and preferences. No new persistent setting or Meeting-file migration is introduced; playback preferences are session-local and reset when another source is selected.
