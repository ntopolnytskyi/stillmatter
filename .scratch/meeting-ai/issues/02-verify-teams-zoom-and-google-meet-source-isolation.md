# 02: Verify Teams-only scope and explicit manual system-audio scope

**What to build:** Verify Teams-only application audio for automatic and manual Teams capture and explicitly selected all-system audio for manual Zoom/Meet capture. Meet is a manual label/icon, not tab isolation; its selection does not affect microphone audio. Research permission/OS limits, stop/reconnect and capture continuity during inference. Never silently fall back from Teams-only to all-system audio. Tests/probes use actual synthetic call routing and scope checks.

**Blocked by:** None (can start immediately)

**Status:** resolved

**Type:** research

**Requirements:** R2, R15.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

## User experience

This slice introduces no new interactive page or control. Verify its observable outputs and existing behavior as specified below; avoid adding unrelated UI.

## Acceptance criteria

- [x] Establish the old backend's broad scope and document the API limits (research, not implementation proof).
- [ ] Verify Teams application-only filtering for detected and manually selected Teams with real synthetic-call routing and unrelated-app rejection; do not claim call-only filtering of other Teams sounds.
- [ ] Verify the explicitly selected all-system scope for manual Zoom and Meet, with truthful UI/metadata disclosure; no Meet-tab or Zoom-only isolation claim.
- [ ] Measure start/end/reconnect evidence and audio continuity while local inference runs; distinguish detection from permission to capture.
- [x] Publish a capability matrix, supported OS/API constraints, reproducible synthetic probes, and evidence for downstream recording tickets.
- [ ] Failed Teams selection/permission remains mic-only with warning, never a silent system-audio fallback.

## Required tests

**UI test execution:** Run UI tests only when this implementation changes UI code. If UI code is unchanged, do not run UI tests; record “UI tests skipped: no UI code changed” in the completion evidence. This condition applies to all UI/native interaction test requirements in this ticket. Continue running relevant non-UI tests.

- [ ] Emit distinguishable synthetic signals in an actual Teams call and unrelated app; verify retained Teams tracks reject unrelated audio. Manual Zoom/Meet runs must verify/disclose intentionally broader system audio, not reject it.
- [ ] Exercise permission denial, source disappearance/reappearance and hidden call controls; record exact observed behavior and latency.
- [ ] Repeat the probe while controlled heavy work runs; inspect actual samples/duration and retain logs sufficient to reproduce the finding.

## Completion evidence

- [ ] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [ ] Save a reproducible finding/contract artifact for dependent tickets, distinguishing verified capability, failed experiments, and unresolved constraints. Do not weaken a product requirement silently.
- [ ] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [ ] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.

### 2026-11-01 — Initial capability investigation (real-call lanes incomplete)

Evidence and executable probes: [capability evaluation](../../../docs/meeting_ai_handoff/capability-evaluation-2026-11-01.md), [disposable probes](../../../experiments/meeting-ai-capabilities/README.md). No production Swift or UI changes. The later disposition below closes the research finding with explicit source-scope constraints; it does not complete the unrun real-call lanes or unblock claims of source isolation.

Executed read-only native preflight both inside/outside sandbox; outside has one display and granted screen/AX/mic permissions for helper identity. Teams/Zoom/Chrome installation versions recorded. Source audit finds current recorder captures every app except itself. Apple documents application-level audio filtering even for a single selected window; existing ScreenCaptureKit backend cannot establish Meet-only tab scope. Added generated target/unrelated tones, PCM leakage assertion (per-channel), and a reproducible exact-source/denial/reconnect/concurrent-inference evaluation lane. Scope checker self-tests pass; actual Teams/Zoom/Meet call samples, continuity/latency under inference, and packaged permission/device behavior have not been measured. No browser/system-wide fallback was substituted.

Validation: `python3 -m unittest discover -s experiments/meeting-ai-capabilities -v` — 12 passed; native helper compiled and executed; actual Pi unavailable-provider probe returned accepted/settled/providerFailed true and validArtifact false. Probe/fixture checks do not count as production coverage or UI ticket verification.

### 2026-11-01 — Research outcome and explicit limits

**Resolved as a capability investigation, not as proof that source-isolated capture is implemented.** The source audit found the production recorder excludes only Stillmatter and otherwise captures applications broadly. Apple's current ScreenCaptureKit contract supports audio filtering by application; it does not expose a browser-tab audio filter. Thus current Teams/Zoom/Meet capture is not isolated, and Meet-tab-only audio is unsupported by this backend. The capability matrix and official API links are in [the evaluation report](../../../docs/meeting_ai_handoff/capability-evaluation-2026-11-01.md).

`python3 -m unittest discover -s experiments/meeting-ai-capabilities -v` passed **12 tests**. They validate synthetic fixture discrimination and RPC/ASR probe behavior; they do not perform ScreenCaptureKit capture. Actual Teams/Zoom/Meet source tones, unrelated-app/tab leakage, start/end/reconnect and hidden-control timing, packaged-app permission denial, and audio continuity/latency during active inference were **not measured**. Those criteria remain unchecked and must be satisfied before claiming or shipping source-isolated capture. The failure to verify them is recorded, not papered over. No production code, UI, storage, or capture fallback changed.

### Revised product scope (supersedes original isolation goal)

Teams capture (automatic or manual) is application-only; manual Zoom/Meet explicitly select all-system audio. Meet is a manual label/icon and never alters microphone capture. The historical investigation above describes the former requirement and unmodified backend. A later candidate source-selecting implementation is on `codex/meeting-ai-12`; it is not actual-call proof. Run Teams leakage and concurrent-inference continuity, permission, disappearance/reconnect, and intentional manual-scope checks in a signed packaged app before making hardware capability claims. The original API research was resolved; the revised acceptance criteria are not. Status is ready-for-human until those actual-call/permission measurements are captured. An opt-in hosted integration probe (`ControlBehaviorRegressionTests.testAuthorizedTeamsCallAudioScopeProbe`) is prepared; without a one-use `/private/tmp/stillmatter-teams-synthetic-call-approval` file it skips. The approval file is consumed before capture and must contain the exact authorization marker and a disposable output directory. It records only after a human explicitly arranges a synthetic-only Teams call. The generated 440 Hz target and 997 Hz unrelated WAV fixtures are under `.build/capabilities/tones/` in the `addb` worktree. The probe has only been compiled and verified to skip; it has not captured a call or established scope/continuity. Disposable operator wizard: `.build/capabilities/run-teams-call-probe.sh` in the `addb` worktree. It gates capture behind consent, waits until the Teams capture stream is live, asks the remote participant to say one unique synthetic phrase (no file playback or loop), records for 20 seconds, plays a separate local 997 Hz tone, and reports per-channel RMS and 997 Hz amplitude from a private retained derivative. A human must confirm the phrase from the retained recording; the speech diagnostic has no automatic source-isolation pass threshold. This is an easier actual-call capture smoke test, not yet a complete leakage, reconnect or inference-continuity gate.

2026-11-06: First human run failed before stream creation at a test-only output-path guard; the wizard's valid `/private/tmp/stillmatter-teams-call.*` path had a different symlink-resolved spelling inside Xcode's test host. No call audio was captured in that run. The guard now validates the original `mktemp` path (exact six-character suffix) and confirms that it names an existing directory. A safe focused host run using an approved path to a *regular file* passed the location guard and failed at the expected directory check, before any capture. The real-call probe must be rerun with human consent; this safe negative-path check is not call evidence.

2026-11-06 second human attempt: the valid output guard passed, but ScreenCaptureKit returned `The user declined TCCs for application, window, display capture` before the stream started. A separate read-only hosted preflight ran **25 tests (1 opted-in probe skipped, 0 failed)** and reported `screenCaptureAuthorized=false` for `works.stillmatter.StillmatterHostedTestHost`. The earlier read-only helper's `true` permission was a different process identity and cannot authorize this host. The wizard now builds/uses a fixed `.build/capabilities/teams-probe-derived` app path and runs a no-capture host permission preflight **before** asking for a Teams call; if denied, it stops and guides the human to System Settings → Privacy & Security → Screen & System Audio Recording for that host identity. Granting permission is a human action. No call audio was retained by either failed attempt; neither establishes source scope.

Follow-up after the human reported the test host failing to load even after adding permissions: the fixed-path Xcode-host preflight still prints `screenCaptureAuthorized=false` for `works.stillmatter.StillmatterHostedTestHost` (latest successful no-capture lane: `.build/coverage/agent-teams-restored-host2`, 25 tests, 1 opted-in probe skipped). The hosted app is intentionally headless and does not present a window if opened directly. An attempt to give the Xcode host a fixed designated signing requirement through Xcode's general sign flags also altered nested XCTest framework signatures; it was reverted, the generated test host was rebuilt, and `codesign --verify --deep --strict` now passes. Do not request another Teams call via this Xcode host. The wizard now builds a **separately packaged, locally signed probe** using the same stable designated requirement/bundle ID as `scripts/build-app.sh` (`works.stillmatter.Stillmatter`), and invokes `--permission` before asking for a call; no XCTest host is involved. A read-only invocation of that signed process returned `screenCaptureAuthorized=true` on this Mac. The opt-in `--capture` mode requires and consumes the one-use authorization file before recording; an invocation without it exited with no capture. The normal app build excludes the probe's CLI through `#if STILLMATTER_CAPTURE_PROBE` and built successfully. Signed-app capture itself has **not** yet run; this preflight is not actual-call or source-isolation evidence. The wizard's new signed-app route supersedes its old Xcode-host instructions.

2026-11-07 — **First human-observed Teams call scope smoke test.** The user ran the opt-in signed probe with a real Teams participant speaking and a separate local 997 Hz tone; they report hearing only Teams in the retained recording, with no audible unrelated tone. The latest private output `/private/tmp/stillmatter-teams-call.0B6fFS/` contains `capture-started`, a successful `capture.log`, and a 20.073-second retained system-audio track (963,520 frames at 48 kHz); its diagnostic JSON reports peak one-second RMS 0.09679 and 997 Hz amplitude 0.001816 in each channel. A previous successful private run `/private/tmp/stillmatter-teams-call.WR8AUB/` also retained 963,520 frames, with lower RMS (0.00678) and 997 Hz amplitude (0.0000139). The user did not identify which take they audited; their listening report is qualitative. The speech diagnostic sets `scopePassed: null` by design: no calibrated all-system control, fixed speech-relative leakage threshold, automated word recognition, reconnect/disappearance, or inference-load continuity test ran. This is useful actual-call evidence for Teams-app audio, **not** proof of -40 dB leakage rejection, meeting-call-only isolation, or full ticket-02 completion. Raw WAV/CAF/M4A remain private under `/private/tmp` and must not be committed.

## Answer

The product owner reports that ticket-02 verification was completed and explicitly directs that this ticket be marked **resolved**. This is an **owner-accepted disposition**, not independent confirmation of every unchecked criterion above: no sanitized wizard observations, Zoom/Meet measurements, permission/reconnect timing, or inference-load measurements were provided in this exchange. The unchecked acceptance/test boxes remain unchecked to avoid representing absent evidence as an executed pass. Retain the previously documented scope contract: Teams application audio only with no silent all-system fallback; manually selected Zoom/Meet intentionally use disclosed all-system audio; Meet is not tab-isolated. No quantitative leakage, reconnection, or model-load performance claim follows from the status change. If those observations are supplied later, append them without opening or sharing private recordings. The outstanding human/device checks are tracked separately in [ticket 51](51-verify-real-device-meeting-source-scope-and-permission.md); their transfer does not turn the unchecked criteria above into passing evidence.
