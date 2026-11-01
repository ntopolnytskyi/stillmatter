# 04: Prove Markdown item identity and legacy migration

**What to build:** Produce a runnable fixture/round-trip prototype for generated and My Notes canonical checkboxes, stable references, Todo projections, tags/owners/approval, external edits, and separate Transcript text/JSON. Exercise existing accepted Todos/notes/archive fixtures and failed migration. Record the chosen source/serializer contract before callers depend on it.

**Blocked by:** None (can start immediately)

**Status:** resolved

**Type:** prototype

**Requirements:** R4, R5, R6, R15.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

Relevant accepted decisions: [file authority and shared identity](../../../docs/adr/0002-file-authority-and-shared-action-item-identity.md), [Person-owned profiles](../../../docs/adr/0003-people-own-independent-voice-profiles.md), and [serial workflows with independent capture](../../../docs/adr/0004-serial-meeting-workflows-with-independent-capture.md). Apply only those affecting this slice.

## User experience

This slice introduces no new interactive page or control. Verify its observable outputs and existing behavior as specified below; avoid adding unrelated UI.

## Acceptance criteria

- [x] Choose and demonstrate stable checkbox/item identity, owner/status/tag metadata and references that survive ordinary user text edits.
- [x] Demonstrate a single canonical note-authored item with Todo/Meeting projections, not independently mutable copies.
- [x] Define Transcript text/JSON round trips and migration from existing doorway notes, accepted Todos/review states and archive metadata.
- [x] Produce a disposable runnable prototype plus an explicit chosen serializer/migration contract; keep experiments out of production paths.

## Required tests

- [x] Round-trip representative old/new fixtures, Unicode names, checkbox edits/removal and duplicate-looking tasks without identity collision.
- [x] Interrupt migration between file replacements, reopen and prove recoverable content and preserved approved-state/source references.
- [x] Change files externally during an unsaved app edit and prove the contract preserves the external version and local draft rather than guessing.

## Completion evidence

- [x] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [x] Save a reproducible finding/contract artifact for dependent tickets, distinguishing verified capability, failed experiments, and unresolved constraints. Do not weaken a product requirement silently.
- [x] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [x] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.

### 2026-11-01 — prototype evidence ready for review

Implemented a disposable stdlib Python prototype and 21 behavioral tests under `docs/meeting_ai_handoff/prototypes/markdown_identity/`. The chosen serializer/migration contract and exact evidence are in [markdown-identity-contract.md](../../../docs/meeting_ai_handoff/markdown-identity-contract.md). This does not enable a production migration.

Executed `python3 -W error::ResourceWarning -m unittest discover -s docs/meeting_ai_handoff/prototypes/markdown_identity -v`: **21 tests passed, 0 failures**, Python 3.15.2, macOS 15.8.1, using freshly isolated temporary workspace/support roots. Tests exercise canonical Meeting/Todo projection mutations, checkbox removal/reassignment/completion, Unicode duplicate text, stable IDs after line/path changes, actual-format SQLite review states/scopes, preserved accepted edits/status/comments/source refs, persisted unsaved-draft/external conflicts, interruption after every migration replacement and reopen, byte-exact rollback, Transcript text/JSON reconciliation and recovered pair publication.

Discovered constraints: legacy copied accepted Todos have no proposal ID, so automatic exact identity reconstruction would be a guess. Preserve the same approved canonical item and review/source evidence; flag unresolved mappings for explicit confirmation rather than creating duplicates. Legacy archive markers have no archive timestamp: preserve archive and prohibit inferred evidence purge. The prototype refuses nested linked-task migration before any write; production must support the hierarchy or retain the old readable format. It does not claim OS-coordinated multi-process saves or all Jobs/index migration. See the contract for required production follow-through in tickets 08/16/34.

No shipped Swift source changed. Prototype tests provide storage-design evidence; they do not satisfy production/native UI coverage or hardware/model quality gates. All original ticket acceptance criteria remain available for the coordinator's review before advancing dependent tickets.

### 2026-11-01 — architecture iteration 2, CA-001

Corrected Transcript parsing to use LF-only record framing instead of Python's Unicode-aware `splitlines()`. A single trailing LF is handled explicitly. Added a behavioral round-trip test for U+2028 LINE SEPARATOR and U+2029 PARAGRAPH SEPARATOR in utterance text, speaker text, document metadata, and segment extension metadata, with and without the final LF. Executed the full prototype suite with ResourceWarnings treated as errors: **22 tests passed, 0 failures**. No shipped Swift or coverage policy changed.

### 2026-11-01 — ticket-only verification and coverage gates

Re-audited the existing prototype against this ticket on a branch based on `b206d08` (main), excluding the separate ticket 03 capability work. Corrected local conflict drafts to derive solely from the editor's base snapshot, retained drafts after external checkbox/file deletion, preserved Unicode separators inside Markdown task text, and preserved CRLF bytes during adoption, edits and interrupted-migration rollback. The executable prototype and [chosen contract](../../../docs/meeting_ai_handoff/markdown-identity-contract.md) remain disposable; no production migration or UI was introduced.

Ran the actual ticket 01 coverage tool with the source-hashed package/hosted/native reports under `/private/tmp/stillmatter-meeting-ai-01-exported/`: `python3 scripts/coverage.py report --reports /private/tmp/stillmatter-meeting-ai-01-exported/package/report.json /private/tmp/stillmatter-meeting-ai-01-exported/hosted/report.json /private/tmp/stillmatter-meeting-ai-01-exported/native/report.json --base origin/main --output /private/tmp/stillmatter-meeting-ai-04-incremental.json`. It exited **0**, with **0/0 changed shipped executable Swift lines**, so the incremental 95% denominator is not applicable. These are reused instrumentation reports validated against the current shipping source/build hashes, not a claim of fresh native test execution. Repeating with `--whole` in place of `--base origin/main` exited **1** at **14,355/19,055 (75.33%)**. Existing whole-source debt remains assigned to tickets 43–46/50; no coverage exclusions or thresholds changed.

Unsupported capabilities remain explicit in the contract: automatic exact legacy proposal/copy matching, nested linked-task migration, inferred archive timestamps, OS-coordinated multi-process publication, and complete Jobs/index migration. This ticket establishes storage-design evidence for downstream implementation; it does not claim those production capabilities or hardware/model validation.


Final validation: **28 tests passed, 0 failures** with `python3 -W error::ResourceWarning -m unittest discover -s docs/meeting_ai_handoff/prototypes/markdown_identity -v`; `git diff --check` passed. Fixtures use newly isolated disposable workspace/support roots and synthetic SQLite/media metadata. Additional regressions bind migration plans to source/destination snapshots: edits or newly created destination files between planning and preparation fail before writes; changed archive dependencies block commit/recovery. The old/new versions and planned replacements remain recoverable. Review/extraction inputs still require coordinated snapshots in the production implementation, as stated in the contract.

Independent code-review outcomes: **Standards: 0 findings. Spec: 0 outstanding findings** after correcting the stale-plan data-loss finding. Re-review executed the complete 28-test suite. All acceptance and evidence criteria above are complete for the declared prototype scope. No UI ticket or production feature was advanced. Ticket 08/16/34 callers must apply the recorded contract and limitations in their own implementations. Review: [ticket 04 PR](https://github.com/ntopolnytskyi/stillmatter/pull/5).
