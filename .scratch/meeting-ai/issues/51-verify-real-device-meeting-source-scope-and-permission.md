# 51: Verify real-device Meeting source scope and permission with a human

**What to build:** Complete the consented, signed-app, synthetic-call measurements deferred from ticket 02. Record reproducible, sanitized non-audio findings for Teams application-only filtering, manual Zoom/Meet all-system scope, permission denial, source disappearance/reconnect, and capture continuity during actual local inference. This is a human/device evaluation, not an authorization for unattended capture.

**Blocked by:** [02: Verify Teams-only scope and explicit manual system-audio scope](02-verify-teams-zoom-and-google-meet-source-isolation.md)

**Status:** ready-for-human

**Type:** research

**Requirements:** R2, R15.

## Scope and safety

- Ticket 02 is owner-resolved as capability research; its unchecked real-device acceptance/test items are **transferred here, not represented as verified**. The existing signed single-call Teams probe and its qualitative observation are useful partial evidence, not quantitative leakage or full multi-source verification.
- Only a human may approve each synthetic-only call and every permission change. Use disposable workspace/media/support roots and a locally signed app; keep raw recordings private and ephemeral. Do not open, upload, or share previous private audio without new authorization.
- This ticket does not reopen the product owner's accepted real-call A→B continuity result for ticket 12. It evaluates source selection, OS permissions/reconnect and inference-load measurements independently.
- Source contract: Teams detected/manual = Teams **application** audio (never silent all-system fallback); manual Zoom/Meet = disclosed **all-system** audio; Meet is a manual label/icon and never implies tab isolation or a microphone change.

## Acceptance criteria

- [ ] In an actual synthetic Teams call, distinguish target speech/audio and an unrelated local app, inspect retained tracks and report calibrated leakage against an appropriate control. Include detected and manual Teams selection; do not claim Teams-call-only filtering.
- [ ] In separate consented manual Zoom and Meet runs, verify intentional all-system scope, truthful before/during/retained disclosure, and unchanged microphone behavior; do not claim Zoom-only or Meet-tab-only isolation.
- [ ] Exercise signed-app permission denial and missing Teams/source disappearance/reappearance, and record mic-only warning, no silent fallback, timing, hidden-control behavior and restored permissions.
- [ ] While an actual working local inference Job runs, measure capture start/end/reconnect, retained frame counts/audio-clock spans and audio gaps. A fake provider or synthetic-only unit test does not satisfy this measurement.
- [ ] Preserve sanitized observations, exact executed procedures/test results, OS/app identity and limits in a reproducible finding; distinguish observed, failed and unrun checks. Keep audio private.

## Operator aid

The ephemeral `.build/capabilities/run-ticket02-verification.sh` wizard in the ticket-12 worktree can guide human steps. It is not a test result or a persistent dependency; recreate it if unavailable. Its underlying signed Teams probe is single-call only; Zoom/Meet, denial, reconnect and inference still require separate consented operator work.

## Comments

Created at the product owner's direction to separate outstanding human/device verification from owner-resolved ticket 02 and ticket-12 acceptance. No new hardware verification is claimed by creating this ticket.
