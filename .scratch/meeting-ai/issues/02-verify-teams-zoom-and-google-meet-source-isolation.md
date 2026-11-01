# 02: Verify Teams, Zoom, and Google Meet source isolation

**What to build:** Research exact supported source selection, permission/OS limits, stop/reconnect evidence, and capture while inference runs. Produce reproducible probes and a capability matrix; explicitly block any unsupported meeting-only requirement rather than substituting browser-wide/system capture. Tests/probes use synthetic call audio and scope checks.

**Blocked by:** None (can start immediately)

**Status:** resolved

**Type:** research

**Requirements:** R2, R15.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

## User experience

This slice introduces no new interactive page or control. Verify its observable outputs and existing behavior as specified below; avoid adding unrelated UI.

## Acceptance criteria

- [x] Prove or disprove meeting-source isolation separately for Teams, Zoom, and Google Meet on the supported platform.
- [ ] Measure start/end/reconnect evidence and audio continuity while background inference is active; distinguish detection from permission to capture.
- [x] Publish a capability matrix, supported OS/API constraints, reproducible synthetic probes, and evidence for downstream recording tickets.
- [x] An unsupported browser/tab source stays an explicit blocker; do not replace meeting-only capture with unrelated browser/system audio.

## Required tests

- [ ] Emit distinguishable synthetic signals in the call source and an unrelated app/tab; verify retained tracks include only authorized source content.
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
