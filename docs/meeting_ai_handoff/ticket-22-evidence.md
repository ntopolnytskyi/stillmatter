# Ticket 22 — Transcript playback evidence

Status is resolved. Dependencies 13 and 21 are resolved. The user approved controller, generated-audio hosted integration and native UI test boundaries. The original review baseline is `3686cc1f1ea3c94b315d52b2daf0d3c0c858c4de`. The capture-gap follow-up starts at `3be51cc3ebbfd0119b368a64538fa5511934ee7c`.

## Completed behavior

Transcript contains the waveform, play/pause, elapsed/total time, 0.5×/1×/1.5×/2× speed and previous/next source markers. At the user’s request on 2026-11-11, all available tracks play together; the track selector and fixed ten-second skip controls were removed. S/D/A/Q markers identify speech, Decisions, Actions and Questions. Drawing caches up to 64 groups and preserves collocated categories. Native tests verify player visibility across the five Meeting tabs.

Option-P toggles playback. The dedicated Option-Left/Right skip and Option-1/2/3 track-selection handlers were removed with their controls. Shortcuts apply within the Transcript workspace and exclude text editors. Option-Space is an alternative where macOS delivers it. The evaluation Mac reserves Option-Space for input-source switching. Native assertions exercise Option-P and verify that typing in Transcript search does not control playback.

Recorded clock spans now map each track's file ranges onto a common Meeting timeline. Internal capture gaps play as silence on the affected track. Transcript and outcome links seek to the mapped position. A phrase crossing a gap has separate active ranges, so highlighting clears through the dropout. Saved source timestamps and citation identities retain their existing representation.

Playback preparation streams 8,192-frame buffers into a private temporary CAF directory. Contiguous tracks reuse their retained files directly. This keeps the existing tested transport and its supported rates. Waveforms sample the same prepared inputs. Stop, source replacement, cancellation, preparation errors and loss of an original during playback release temporary audio. A source click during preparation retains the latest requested seek and applies it when the player is ready. Replacement and failure clear it.

Original recordings remain read-only during preparation and playback. Filesystem readability checks detect removed originals on playback ticks. Ticks update transport and phrase styling without rebuilding the Transcript or rereading complete media files. Source-equivalent content refresh retains the player, position, speed and mix.

## Timing and compatibility limits

Malformed, overlapping, inconsistent or undecodable timing receives an explicit unavailable message. Anchor validation retains the capture clock's five-millisecond tolerance. Mixed recordings with internal gaps require clock anchors for both retained tracks. Missing evidence cannot establish their original relative timing. Legacy recordings without clock anchors retain file-offset playback.

The temporary rendering path requires sufficient disk space and reports capacity errors. No persisted Meeting schema or setting migration is introduced. Existing legacy, relocated-recording and restart scenarios pass. Synthetic fixtures isolate workspace, media, support and preferences.

Hardware source isolation and speech-model quality remain covered by their declared evaluation tickets.

## Final verification

Production source is committed through `39ba19e`.

- Full Release package passed **462 tests with four existing opt-in skips and zero failures**. Evidence is `/private/tmp/stillmatter-22-gap-package-final/{execution.json,tests.log,report.json}`.
- Full Release app-hosted suite passed **51/51**. Generated CAF and AAC cases verify waveform silence, playback through gaps, source preservation, queued seeks, replacement, cancellation, cleanup and disk-space rejection. Existing tests verify actual driver timing at all four offered rates. Evidence is `/private/tmp/stillmatter-22-gap-hosted-final/{execution.json,results.xcresult,tests.log,report.json}`.
- Focused main-app native flow passed **1/1**. Mouse and keyboard seeking, mix/speed/shortcuts, markers, editor focus, tab visibility, refresh stability, Meeting switching and purged audio are asserted. After a two-second capture gap, clicking the source timestamp at file time 0:02 moves the playhead to Meeting time 0:04 on the ten-second timeline. Retained audio and Transcript bytes are checked. Evidence is `/private/tmp/stillmatter-22-gap-native-final/{execution.json,results.xcresult,tests.log,report.json}`.

All three reports use fresh profiles and source inventories with compatible Release/-Onone compilation. Compiler artifacts were reused through the documented external-lane collection path, with source and build-input fingerprints checked before and after execution.

The 95% changed-line gate passed against both baselines.

| Scope | Covered / executable changed lines | Coverage |
| --- | ---: | ---: |
| Capture-gap follow-up | 272 / 273 | 99.63% |
| Complete ticket 22 | 526 / 527 | 99.81% |

Follow-up Core coverage is 107/107 and app/UI coverage is 165/166. Complete ticket coverage is Core 130/130, Presentation 8/8 and app/UI 388/389. Reports are `/private/tmp/stillmatter-22-gap-gate.json` and `/private/tmp/stillmatter-22-complete-gate.json`. Both gate commands exited zero.

Whole-source coverage is **18,950/23,358 = 81.13%**. Core is 9,544/10,153, Presentation 1,197/1,391, runtime 327/347 and app/UI 7,882/11,467. Ticket 50 retains its 95% whole-source requirement.

## Reviews

Object Oriented Design, Clean Architecture and API Design approved the implementation. The public paired-range coverage contract was clarified after API review.

### Standards

No hard documented violations. One accepted low-priority maintenance judgment remains about using a shared type for the four marker-category strings.

### Spec

No remaining findings. The capture-gap requirement is implemented. Review also found a source seek that could be dropped during preparation. Commit `39ba19e` queues it for the current source and adds regression assertions for refresh, paused intent and replacement isolation.

`git diff --check` passes. Ticket 22 is resolved with the above evidence.

## 2026-11-11 — Simplified playback controls

At the user's explicit request, removed the fixed −10s/+10s buttons and the Both / My speech / Other participants selector, together with their dedicated Option-Left/Right and Option-1/2/3 handlers. Playback uses all available retained tracks together. Play/pause (Option-P), speed, waveform/native arrow seeking, source links, and Previous/Next marker navigation remain. Original independent track evidence, clock alignment, gap preparation and rendering are preserved. The approved local spec records this user-directed change to R13; the earlier selection/skip evidence above is historical.

Final Release validation passed **465 package tests (four existing opt-in skips, zero failures)**, **52 hosted tests**, and **three focused native UI scenarios**. The native playable-media scenario asserts that the removed controls are absent, changes speed, seeks by waveform, navigates markers and source links, checks editor/shortcut scope and tab visibility, and verifies retained media/Transcript bytes. Empty/unavailable and five-tab behavior also pass.

Compatible evidence roots: `/private/tmp/stillmatter-playback-simple-{package,hosted,native}/`. Against baseline `816469a23f92c02ee9a0549adcff498ad3365e8a`, the unchanged 95% incremental gate exited **0**, **1/1 changed executable app/UI lines (100%)**; this slice primarily deletes code. Report: `/private/tmp/stillmatter-playback-simple-gate.json`. All shipped files have executable maps. Whole-source measured coverage is 19,168/23,487 (81.61%) with the focused native lane, existing debt for ticket 50 rather than a whole-app completion claim. No exclusion or threshold was added.

Independent Standards and Spec reviews of the control-removal diff found **zero findings per axis**. `git diff --check` passed. No storage migration or model-quality capability change is involved.
