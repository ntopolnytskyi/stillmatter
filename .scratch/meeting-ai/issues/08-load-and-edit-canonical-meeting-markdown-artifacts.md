# 08: Load and edit canonical Meeting Markdown artifacts

**What to build:** Deliver recoverable migration to separate human-readable artifacts including My Notes. UI: current editors reflect valid external changes; conflicting drafts retain local text with Reload/resolve feedback; malformed files show a precise error. Tests cover old/new load, restart mid-migration, externally renamed files, text/JSON consistency, and no duplicate items or overwritten notes.

**Blocked by:** [01: Measure all shipped source and enforce incremental coverage](01-measure-all-shipped-source-and-enforce-incremental-coverage.md); [04: Prove Markdown item identity and legacy migration](04-prove-markdown-item-identity-and-legacy-migration.md)

**Status:** resolved

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

<<<<<<< HEAD
<<<<<<< HEAD
=======
>>>>>>> aef10c7 (Resolve ticket 08 with test and coverage evidence)
- [x] Migrate legacy Meeting content into canonical Markdown artifacts and a separate My Notes file using the contract from 04.
- [x] Load valid external edits as authoritative and refresh current views; do not overwrite existing user content during migration.
- [x] Preserve an unsaved in-app draft when an external update conflicts, with explicit reload/resolve instead of silent replacement.
- [x] Unreadable/malformed files produce a localized actionable error and do not turn into empty successful content.
<<<<<<< HEAD

## Required tests

- [x] Load old/new fixtures and verify notes, accepted items, references, archive metadata and Transcript representations survive round trips.
- [x] Interrupt each migration/write phase, reopen and assert recoverable old/new content with no duplicated task identities.
- [x] Externally edit/rename content while a draft is open; assert updated source remains intact and the draft remains available.

- [x] Native interaction tests cover the changed controls, applicable shortcuts/focus, resulting persisted state, and the relevant empty/disabled/error case. Use semantic test identifiers and observable waits; source-text checks or screenshots without assertions do not substitute for behavior.

## Completion evidence

- [x] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [x] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [x] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.
=======
- [ ] Migrate legacy Meeting content into canonical Markdown artifacts and a separate My Notes file using the contract from 04.
- [ ] Load valid external edits as authoritative and refresh current views; do not overwrite existing user content during migration.
- [ ] Preserve an unsaved in-app draft when an external update conflicts, with explicit reload/resolve instead of silent replacement.
- [ ] Unreadable/malformed files produce a localized actionable error and do not turn into empty successful content.
=======
>>>>>>> aef10c7 (Resolve ticket 08 with test and coverage evidence)

## Required tests

- [x] Load old/new fixtures and verify notes, accepted items, references, archive metadata and Transcript representations survive round trips.
- [x] Interrupt each migration/write phase, reopen and assert recoverable old/new content with no duplicated task identities.
- [x] Externally edit/rename content while a draft is open; assert updated source remains intact and the draft remains available.

- [x] Native interaction tests cover the changed controls, applicable shortcuts/focus, resulting persisted state, and the relevant empty/disabled/error case. Use semantic test identifiers and observable waits; source-text checks or screenshots without assertions do not substitute for behavior.

## Completion evidence

<<<<<<< HEAD
- [ ] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [ ] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [ ] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.
>>>>>>> 5e136c9 (Claim ticket 08 canonical Meeting artifact implementation)
=======
- [x] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [x] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [x] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.
>>>>>>> aef10c7 (Resolve ticket 08 with test and coverage evidence)

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.
<<<<<<< HEAD
<<<<<<< HEAD
=======
>>>>>>> aef10c7 (Resolve ticket 08 with test and coverage evidence)

### 2026-11-02 — implementation and verification complete

Implemented ticket 08 only. Legacy Meeting content now migrates through a recoverable publication plan into canonical Markdown artifacts and a separate `my-notes.md`; Transcript text/JSON edits reconcile against their synchronized base. Current capture/processing writers continue using legacy files until they finish, and generated output updates canonical files while retaining Notes and reviewed user work. External edits remain authoritative, editors retain conflicting drafts with reload feedback, and malformed inputs produce actionable errors. Artifact IDs, CRLF content, unknown Markdown sections, archive state, approved Todos, and Transcript timing/metadata survive the tested round trips.

Executed final-source checks:

- Full package Release coverage lane: **346 tests, 4 skipped, 0 failed**. Focused final-source suites passed **31 artifact/edge tests** and **7 canonical Todo reference tests**.
- Hosted Release coverage lane: **7 tests, 0 skipped, 0 failed**.
- Native Release UI coverage lane: **19 tests, 0 skipped, 0 failed**. Tests assert cancel/save shortcuts, focus, empty and archived states, persisted edits after relaunch, valid external refresh, conflict draft retention/reload, rename, and malformed-file repair/reload.
- Fresh compatible package, hosted, and native reports were combined with `--base 93329d7`. Incremental coverage passed at **1,027/1,058 (97.07%)**: Core 961/985 (97.56%), Presentation 25/30 (83.33%), and app/UI 41/43 (95.35%). The aggregate gate is 95%; the per-module breakdown is reported for diagnosis.
- The separately enforced whole-source gate remains below target at **15,527/20,072 (77.36%)**: Core 91.00%, Presentation 88.00%, runtime 50.82%, app/UI/platform 65.29%. This is existing coverage debt assigned to later coverage tickets; it is not represented as passing.
- Review since `93329d7`: Standards **0 remaining findings**; Spec **0 findings**. Final `git diff --check` passed. All workspace, support, and media fixtures were isolated and synthetic.

Capability limits: ticket 08 establishes file migration/edit behavior only. It does not establish real Teams/Zoom/Meet source isolation, OS permission/device behavior, ASR/diarization quality, or model quality; those remain separate research/evaluation lanes. Legacy accepted Todo copies without a proposal ID cannot be matched back to an exact proposal without guessing; migration preserves one canonical approved task and unresolved association evidence for explicit downstream resolution. No real hardware/model evaluation was required or claimed for this storage/UI slice.
<<<<<<< HEAD
=======
>>>>>>> 5e136c9 (Claim ticket 08 canonical Meeting artifact implementation)
=======
>>>>>>> aef10c7 (Resolve ticket 08 with test and coverage evidence)
