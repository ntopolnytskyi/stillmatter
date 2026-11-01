# 08: Load and edit canonical Meeting Markdown artifacts

**What to build:** Deliver recoverable migration to separate human-readable artifacts including My Notes. UI: current editors reflect valid external changes; conflicting drafts retain local text with Reload/resolve feedback; malformed files show a precise error. Tests cover old/new load, restart mid-migration, externally renamed files, text/JSON consistency, and no duplicate items or overwritten notes.

**Blocked by:** [01: Measure all shipped source and enforce incremental coverage](01-measure-all-shipped-source-and-enforce-incremental-coverage.md); [04: Prove Markdown item identity and legacy migration](04-prove-markdown-item-identity-and-legacy-migration.md)

**Status:** claimed

**Type:** task

**Requirements:** R4, R6, R14.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

Relevant accepted decisions: [file authority and shared identity](../../../docs/adr/0002-file-authority-and-shared-action-item-identity.md), [Person-owned profiles](../../../docs/adr/0003-people-own-independent-voice-profiles.md), and [serial workflows with independent capture](../../../docs/adr/0004-serial-meeting-workflows-with-independent-capture.md). Apply only those affecting this slice.

## User experience

- Entry: open an existing Meeting and use its current text editor, with new files handled transparently.
- Layout: editors retain human-readable content and render/save controls; storage diagnostics do not replace normal reading flow.
- Actions: Save uses the current version; Reload Latest imports newer file content; cancel retains the external source unchanged.
- States: conflict feedback names the affected content, keeps the local draft, and offers resolution; malformed input is an error, not an empty document.
- Keyboard/persistence: save/cancel and editor typing keep existing shortcuts; successful edits and migrations survive relaunch.

## Acceptance criteria

- [ ] Migrate legacy Meeting content into canonical Markdown artifacts and a separate My Notes file using the contract from 04.
- [ ] Load valid external edits as authoritative and refresh current views; do not overwrite existing user content during migration.
- [ ] Preserve an unsaved in-app draft when an external update conflicts, with explicit reload/resolve instead of silent replacement.
- [ ] Unreadable/malformed files produce a localized actionable error and do not turn into empty successful content.

## Required tests

- [ ] Load old/new fixtures and verify notes, accepted items, references, archive metadata and Transcript representations survive round trips.
- [ ] Interrupt each migration/write phase, reopen and assert recoverable old/new content with no duplicated task identities.
- [ ] Externally edit/rename content while a draft is open; assert updated source remains intact and the draft remains available.

- [ ] Native interaction tests cover the changed controls, applicable shortcuts/focus, resulting persisted state, and the relevant empty/disabled/error case. Use semantic test identifiers and observable waits; source-text checks or screenshots without assertions do not substitute for behavior.

## Completion evidence

- [ ] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [ ] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [ ] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.
