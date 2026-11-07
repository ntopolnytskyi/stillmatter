# 13: Select and record the meeting source through the shared flow

**What to build:** UI: Recording defaults to Teams and lets the user select Teams/Zoom/Google Meet; show microphone/source state, elapsed time, scoped warnings and permission actions. Teams (manual/automatic) captures Teams app audio only; manual Zoom/Meet explicitly capture all system audio. Meet is a manual-only label/icon and does not affect microphone capture. Tests cover source loss, mic-only degraded continuation, delayed callbacks, repeated Stop, device changes and original evidence; real scope checks follow 02.

**Blocked by:** [02: Verify Teams-only scope and explicit manual system-audio scope](02-verify-teams-zoom-and-google-meet-source-isolation.md); [05: Use shared controls in Recording and Settings](05-use-shared-controls-in-recording-and-settings.md); [12: Start capture immediately while previous work finalizes or processes](12-start-capture-immediately-while-previous-work-finalizes-or-processes.md)

**Status:** ready-for-agent

**Type:** task

**Requirements:** R2, R7, R14.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

## User experience

- Entry: Recording destination; selected source defaults to Teams, with Zoom/Google Meet choices before start.
- Layout: selected meeting source, microphone/source health, elapsed time, principal Record and active Stop remain readable.
- Actions: Record performs preflight and starts the shared capture flow; Stop ends the active session and hands it off durably.
- States: missing permission gives a setup action; source loss shows a persistent degraded warning and mic continuation, not false success.
- Keyboard/persistence: start/stop/source selection are reachable by keyboard; saved tracks retain original identity and source scope.

## Acceptance criteria

- [ ] Use the selected meeting-source contract verified in 02, with microphone and synchronized selected-source tracks.
- [ ] Default to Teams and allow manual Teams/Zoom/Google Meet selection through the same flow. Teams always selects Teams-app-only audio. Manual Zoom/Meet select all-system audio deliberately with explicit pre-Start and active/retained scope disclosure; Meet supplies only the manual label/icon, with no mic effect or tab-only claim.
- [ ] If Teams-app audio capture fails, retain mic capture and show the actual degraded scope; never silently widen to all-system audio. Manual all-system permission/source failure likewise leaves mic and a warning, not a false scope claim.
- [ ] Handle repeated Stop, device/source changes and session callbacks without destroying original evidence.

## Required tests

**UI test execution:** Run UI tests only when this implementation changes UI code. If UI code is unchanged, do not run UI tests; record “UI tests skipped: no UI code changed” in the completion evidence. This condition applies to all UI/native interaction test requirements in this ticket. Continue running relevant non-UI tests.

- [ ] Capture distinguishable synthetic source/unrelated signals and assert source scope plus synchronized saved tracks.
- [ ] Lose source/device midway, deliver late events and repeated Stop, and verify retained mic evidence and truthful warning/state.
- [ ] Exercise blocked permissions and next-session capture while earlier processing runs; real source-isolation evidence comes from 02.

- [ ] Native interaction tests cover the changed controls, applicable shortcuts/focus, resulting persisted state, and the relevant empty/disabled/error case. Use semantic test identifiers and observable waits; source-text checks or screenshots without assertions do not substitute for behavior.

## Completion evidence

- [ ] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [ ] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [ ] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.

### Dependency and completion review

Prerequisites 02, 05 and 12 are now marked resolved; ticket 02's outstanding human/device measurements are separately tracked in [51](51-verify-real-device-meeting-source-scope-and-permission.md), not represented as passed. The source selector, deliberate Teams-versus-all-system scope, microphone-only start failure, A/B stale callback protection and native Controls UI interaction have related implementation/tests merged from ticket 12. **Ticket 13 is not yet resolved on dependency status alone.** Its own checklist still needs evidence for source/device loss *mid-capture* with a persistent degraded warning, repeat Stop, microphone retention, keyboard/focus and permission error actions in the integrated native flow, synchronized saved tracks, and its own 95% incremental gate (or an explicit owner exception for ticket 13). Device-free fake streams cannot establish OS filtering or permission behavior; those hardware claims belong to ticket 51. Do not mark these unexecuted cases passing merely because ticket 02 or 12 was closed.
