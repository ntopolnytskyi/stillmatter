# 04: Prove Markdown item identity and legacy migration

**What to build:** Produce a runnable fixture/round-trip prototype for generated and My Notes canonical checkboxes, stable references, Todo projections, tags/owners/approval, external edits, and separate Transcript text/JSON. Exercise existing accepted Todos/notes/archive fixtures and failed migration. Record the chosen source/serializer contract before callers depend on it.

**Blocked by:** None (can start immediately)

**Status:** ready-for-agent

**Type:** prototype

**Requirements:** R4, R5, R6, R15.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

Relevant accepted decisions: [file authority and shared identity](../../../docs/adr/0002-file-authority-and-shared-action-item-identity.md), [Person-owned profiles](../../../docs/adr/0003-people-own-independent-voice-profiles.md), and [serial workflows with independent capture](../../../docs/adr/0004-serial-meeting-workflows-with-independent-capture.md). Apply only those affecting this slice.

## User experience

This slice introduces no new interactive page or control. Verify its observable outputs and existing behavior as specified below; avoid adding unrelated UI.

## Acceptance criteria

- [ ] Choose and demonstrate stable checkbox/item identity, owner/status/tag metadata and references that survive ordinary user text edits.
- [ ] Demonstrate a single canonical note-authored item with Todo/Meeting projections, not independently mutable copies.
- [ ] Define Transcript text/JSON round trips and migration from existing doorway notes, accepted Todos/review states and archive metadata.
- [ ] Produce a disposable runnable prototype plus an explicit chosen serializer/migration contract; keep experiments out of production paths.

## Required tests

- [ ] Round-trip representative old/new fixtures, Unicode names, checkbox edits/removal and duplicate-looking tasks without identity collision.
- [ ] Interrupt migration between file replacements, reopen and prove recoverable content and preserved approved-state/source references.
- [ ] Change files externally during an unsaved app edit and prove the contract preserves the external version and local draft rather than guessing.

## Completion evidence

- [ ] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [ ] Save a reproducible finding/contract artifact for dependent tickets, distinguishing verified capability, failed experiments, and unresolved constraints. Do not weaken a product requirement silently.
- [ ] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [ ] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.

### 2026-11-01 — prototype evidence ready for review

Implemented a disposable stdlib Python prototype and 21 behavioral tests under `docs/meeting_ai_handoff/prototypes/markdown_identity/`. The chosen serializer/migration contract and exact evidence are in [markdown-identity-contract.md](../../../docs/meeting_ai_handoff/markdown-identity-contract.md). This does not enable a production migration.

Executed `python3 -W error::ResourceWarning -m unittest discover -s docs/meeting_ai_handoff/prototypes/markdown_identity -v`: **21 tests passed, 0 failures**, Python 3.15.2, macOS 15.8.1, using freshly isolated temporary workspace/support roots. Tests exercise canonical Meeting/Todo projection mutations, checkbox removal/reassignment/completion, Unicode duplicate text, stable IDs after line/path changes, actual-format SQLite review states/scopes, preserved accepted edits/status/comments/source refs, persisted unsaved-draft/external conflicts, interruption after every migration replacement and reopen, byte-exact rollback, Transcript text/JSON reconciliation and recovered pair publication.

Discovered constraints: legacy copied accepted Todos have no proposal ID, so automatic exact identity reconstruction would be a guess. Preserve the same approved canonical item and review/source evidence; flag unresolved mappings for explicit confirmation rather than creating duplicates. Legacy archive markers have no archive timestamp: preserve archive and prohibit inferred evidence purge. The prototype refuses nested linked-task migration before any write; production must support the hierarchy or retain the old readable format. It does not claim OS-coordinated multi-process saves or all Jobs/index migration. See the contract for required production follow-through in tickets 08/16/34.

No shipped Swift source changed. Prototype tests provide storage-design evidence; they do not satisfy production/native UI coverage or hardware/model quality gates. All original ticket acceptance criteria remain available for the coordinator's review before advancing dependent tickets.
