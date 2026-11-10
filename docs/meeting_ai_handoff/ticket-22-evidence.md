# Ticket 22 — Transcript playback evidence

Scope: [ticket 22](../../.scratch/meeting-ai/issues/22-play-synchronized-tracks-through-the-transcript-waveform.md), based on `3686cc1f1ea3c94b315d52b2daf0d3c0c858c4de`. Dependencies 13 and 21 are resolved. The user approved controller, generated-audio hosted integration, and native UI test boundaries and this review baseline.

## Behavior

The Transcript player uses the original validated microphone and system tracks. Both / My speech / Other participants changes their volumes without replacing the player or resetting the source position. Missing Other evidence disables that choice. Speed choices are 0.5×, 1×, 1.5× and 2×. Seek and speed changes preserve playing/paused intent; Play at EOF restarts. A shared device clock accounts for track starting offsets and rate. Source files are never rewritten by playback.

The player is visible only in Transcript. It has waveform mouse/arrow-key seeking, elapsed/total time, backward/forward ten seconds, and previous/next source markers. Speech, Decisions, Actions and Questions use S/D/A/Q labels and an explicit legend; marker drawing is bounded for dense recordings while navigation retains all validated markers. Shortcuts are Option-P (play/pause; Option-Space also works when not reserved by macOS), Option-Left/Right (ten seconds), and Option-1/2/3 (tracks). They apply in the selected Meeting's Transcript workspace and exclude text editors. Native popup/slider/button keyboard behavior remains available.

Clock offsets also apply to Transcript seeks and current-phrase highlights. Saved track-local timestamps and citation identity remain unchanged. Relocated recordings read their relocated timing metadata. Waveforms are sampled once per loaded source and cached per mix. Ticks publish small transport values and update active phrase styling; they do not rebuild the Transcript or reread full audio files. An unrelated source-equivalent document refresh retains the player, position, speed and mix. Replacing a Meeting invalidates player and waveform callbacks.

## Unsupported capability — not accepted as complete

**Discontinuous capture-clock playback remains unsupported.** `AudioClockSpan` can describe host-time gaps between contiguous file frames. The existing AVAudioPlayer transport cannot insert that missing silence. Furthermore, canonical Transcript segments and speaker turns currently retain per-file times; simply adding silence to playback without mapping those source references would shift Transcript/citation navigation. This change refuses playback when supplied clock anchors contain unrepresented gaps or invalid timing instead of silently compressing the recording. It also reports malformed/unreadable metadata explicitly. Legacy recordings without clock anchors retain the existing file-timeline fallback; they do not establish measured original-clock alignment.

To finish this requirement, add a validated common-timeline projection for track-local Transcript/citation timing and a gap-aware player/composition or background bounded-memory aligned derivative, preserving originals and handling cancellation/cleanup. Tests must verify actual decoded samples and navigation on both sides of capture gaps, rate changes and Meeting replacement. File silence and starting offsets tested here do **not** prove capture-gap playback.

Ticket 22 must remain unresolved while that acceptance criterion is unmet. No source-isolation, ASR/diarization quality, real-device synchronization or other hardware capability is established by these generated fixtures.

## Verification

Final coverage, suite and independent review results are recorded below after execution. All fixtures use disposable synthetic workspace, media, support and preferences. No new persistent setting or Meeting-file migration is introduced; playback preferences are session-local and reset when another source is selected.

## Timing regression and review

The stronger real-driver test exposed two independent scheduling defects. A disposable AVAudioPlayer probe reproduced resumed track drift in five out of five runs (approximately 0.15–0.16 source seconds), and a later-starting track advanced before its intended offset at 2×. Testing one change at a time showed that stopping and restoring track positions cancels old scheduled starts, while removing the second rate scaling corrects future start scheduling. Combined checks at 0.5×/1×/1.5×/2× observed no early Other track and resumed drift below 0.014 source seconds in that probe. The retained regression tests assert wall time and actual AVAudioPlayer track positions with their original tolerances. Corrected focused hosted tests: 8/8 passed. Probe evidence: `/private/tmp/stillmatter-22-timing-probe/{baseline,stop,delay,combined}.log`; passing focused log: `/private/tmp/stillmatter-22-hosted-scheduling-fixed.log`.

Two architecture iterations approved Object Oriented Design, Clean Architecture and API Design. API-001 (hidden/repeated supported rates) was fixed with one documented public supported-speed collection shared by transport and controls. Immutable transport snapshots remain separate from mutable player lifetime.

Independent code review of `git diff 3686cc1f1ea3c94b315d52b2daf0d3c0c858c4de...HEAD` through `a146dda`:

### Standards

No documented-standard violations. One low-priority judgment: possible Primitive Obsession in the four private S/D/A/Q marker strings repeated by producer and renderer. A typed marker category could consolidate their identity/order. This is accepted as a nonblocking maintenance suggestion for the fixed internal category set; no untrusted category input is accepted.

### Spec

One P1 finding remains: the requirement to “Expose synchronized Both/My speech/Other participants playback using validated retained tracks and original timing,” including “source offsets, gaps, EOF and speed/seek behavior,” is incomplete for capture-clock gaps. Fail-closed behavior and this documentation do not remove that requirement. The reviewer found no additional scope creep or implemented-but-wrong behavior.

Review summary: Standards 0 hard violations + 1 low-priority judgment (marker category typing); Spec 1 finding (capture-gap playback).

### Native shortcut conflict

Two native runs demonstrated that Option-Space never reached the app, including with the waveform explicitly focused. The local macOS symbolic-hotkey configuration has input-source switching enabled on Option-Space (binding 60, parameters `[32, 49, 524288]`). No system preference was changed. Option-P is now the primary play/pause shortcut; Option-Space remains an alternative where the OS delivers it. Native tests use Option-P and verify that the shortcut does not start playback while editing Transcript search text. This is an implementation shortcut choice, not a waiver of keyboard support.
