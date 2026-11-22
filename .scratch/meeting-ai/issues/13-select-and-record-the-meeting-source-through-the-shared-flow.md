# 13: Select and record the meeting source through the shared flow

**What to build:** UI: Recording defaults to Teams and lets the user select Teams/Zoom/Google Meet; show microphone/source state, elapsed time, scoped warnings and permission actions. Teams (manual/automatic) captures Teams app audio only; manual Zoom/Meet explicitly capture all system audio. Meet is a manual-only label/icon and does not affect microphone capture. Tests cover source loss, mic-only degraded continuation, delayed callbacks, repeated Stop, device changes and original evidence; real scope checks follow 02.

**Blocked by:** [02: Verify Teams-only scope and explicit manual system-audio scope](02-verify-teams-zoom-and-google-meet-source-isolation.md); [05: Use shared controls in Recording and Settings](05-use-shared-controls-in-recording-and-settings.md); [12: Start capture immediately while previous work finalizes or processes](12-start-capture-immediately-while-previous-work-finalizes-or-processes.md)

**Status:** resolved

**Type:** task

**Requirements:** R2, R7, R14.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/UI_PRINCIPALS.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

## User experience

- Entry: Recording destination; selected source defaults to Teams, with Zoom/Google Meet choices before start.
- Layout: selected meeting source, microphone/source health, elapsed time, principal Record and active Stop remain readable.
- Actions: Record performs preflight and starts the shared capture flow; Stop ends the active session and hands it off durably.
- States: missing permission gives a setup action; source loss shows a persistent degraded warning and mic continuation, not false success.
- Keyboard/persistence: start/stop/source selection are reachable by keyboard; saved tracks retain original identity and source scope.

## Acceptance criteria

- [x] Use the selected meeting-source contract verified in 02, with microphone and synchronized selected-source tracks.
- [x] Default to Teams and allow manual Teams/Zoom/Google Meet selection through the same flow. Teams always selects Teams-app-only audio. Manual Zoom/Meet select all-system audio deliberately with explicit pre-Start and active/retained scope disclosure; Meet supplies only the manual label/icon, with no mic effect or tab-only claim.
- [x] If Teams-app audio capture fails, retain mic capture and show the actual degraded scope; never silently widen to all-system audio. Manual all-system permission/source failure likewise leaves mic and a warning, not a false scope claim.
- [x] Handle repeated Stop, device/source changes and session callbacks without destroying original evidence.

## Required tests

**UI test execution:** Run UI tests only when this implementation changes UI code. If UI code is unchanged, do not run UI tests; record “UI tests skipped: no UI code changed” in the completion evidence. This condition applies to all UI/native interaction test requirements in this ticket. Continue running relevant non-UI tests.

- [x] Capture distinguishable synthetic signals and assert selected scope, shared session identity/timing, and retained track samples. Real unrelated-app filtering evidence remains limited to the qualitative Teams observation recorded in 02.
- [x] Lose source/device midway, deliver late events and repeated Stop, and verify retained mic evidence and truthful warning/state.
- [x] Exercise blocked permissions and next-session capture while earlier processing runs; real source-isolation evidence comes from 02.

- [x] Native interaction tests cover the changed controls, applicable shortcuts/focus, resulting persisted state, and the relevant empty/disabled/error case. Use semantic test identifiers and observable waits; source-text checks or screenshots without assertions do not substitute for behavior.

## Completion evidence

- [x] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [x] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [x] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.

### Dependency and completion review

Prerequisites 02, 05 and 12 are resolved. The remaining real-device source/permission measurements are tracked in [51](51-verify-real-device-meeting-source-scope-and-permission.md).

### 2026-11-08 — Ticket 13 implementation and verification

Added live propagation of a system-source failure from the ScreenCaptureKit stream through track metadata and the capture service into a persistent Recording warning. A delegate-confirmed source stop now finalizes as partial retained system audio and leaves microphone capture available; an unconfirmed manual stop still blocks another capture. The warning includes the selected scope and never implies a broader successful capture.

Verification in the isolated ticket-only worktree at `9ce94c6`:

- Release package: **398 tests, 4 skipped, 0 failed**.
- Release hosted: **30/30 passed**, including synthetic source loss, retained PCM, callback propagation, and next-session start.
- Release Controls native UI: **11/11 passed**, including keyboard start, source/scope disclosure and persistence, mid-capture loss warning, microphone continuation, and Stop.
- Ticket-only 95% incremental gate: **61/62 changed executable lines = 98.39%, PASS**. The temporary worktree excluded unrelated pre-existing dirty changes in the shared checkout. Report: `/private/tmp/stillmatter-ticket13-gate/.build/coverage/ticket13-incremental.json`.
- Focused timing assertion: microphone and selected system tracks share Capture Session ID, Meeting path, start/end timestamps, and selected scope. Existing A/B synthetic PCM tests verify sample ownership across delayed callbacks.
- `git diff --check` passed. Fixtures used disposable roots and synthetic audio; no user library or physical microphone was used.

Capability limit: synthetic streams verify source selection, callback handling, retained evidence, and session timing. They do not establish actual macOS Teams filtering, unrelated-app rejection, Zoom/Meet permission behavior, or sample-level real-device synchronization. Ticket 02 records a qualitative Teams call with an unrelated tone and explicitly does not claim quantitative isolation; remaining device checks stay in ticket 51. No fake provider is presented as OS capability evidence.
