# Ticket 26 — Meeting Action Item approval

Ticket: `.scratch/meeting-ai/issues/26-approve-meeting-action-items-into-the-same-personal-todo-view.md`.
Review and coverage baseline: `6ec9f9f5cb92f8c41473be3d92c584b4aa543c22`.
Dependencies 16 and 25 were resolved before implementation. Scope is ticket 26 only.

## User-visible changes

The Action Items tab groups canonical checkboxes by owner: Me, named other owners, then unknown owners. It includes note-authored tasks. Pending items stay within their Meeting until approval. Users can edit task text, explicitly assign an owner, set or clear a confirmed due date, and save. Uncertain due wording and source citations remain intact. Approval removes `#need-approve` and retains `#ai-gen`.

Accept approves one pending item. Accept all mine and Accept all others select pending, known-owner items only within the displayed Meeting, in displayed owner/item order. Unknown-owner approval is disabled with assignment guidance. Personal approvals expose the same canonical identity in Todo; other-person approvals remain Meeting-only. Reject retains the rejection decision. Repeated activation and retries cannot create another Todo.

Approved work supports Open, Postponed, and Completed. Postponed can return to Open; Completed has no Reopen and its status selector is disabled. Note edits/completion write back to My Notes, including changes through Todo. Generated-item Todo edits write back to their canonical Action Items artifact, including after that artifact is renamed. Reassignment to another owner removes the personal projection; reassignment to Me restores the same identity.

Save errors keep drafts. A concurrent source edit causes a conflict instead of being overwritten; Reload saved item explicitly discards the draft. Editable fields have names and labels, essential status wraps, native Tab/Space/Return behavior is retained, and context menus expose item/batch actions. Saves retain logical focus; review removal advances to a pending item or the feedback target and announces the result. Source links navigate to the matching Transcript evidence, including when audio is unavailable. Archived and in-progress Meeting mutation guards remain enforced.

## Persistence and compatibility

The existing v1 canonical checkbox metadata and durable Meeting artifact transaction are reused; no replacement task database or new schema is introduced. Files remain authoritative. Item edits, review decisions, Todo references, and legacy review intents publish through the existing version-checked recoverable plan. A database review failure is reported; persisted review intent retries after recovery. The new editor keeps its original checkbox snapshot across refresh so an old draft cannot overwrite a newer canonical edit.

Legacy Meeting fixtures migrate through the existing artifact loader. Native relaunch assertions verify owner, due, completion and Todo identity persistence. Independent Transcript speaker correction is exercised through the real Meeting service and does not rewrite an individually edited owner. ADR-0001 no-alias behavior is preserved.

## Executed tests

- Full Release package suite: **507 tests, five existing skips, zero failures**. Evidence: `/private/tmp/ticket26-package-complete/{tests.log,execution.json,report.json}`.
- Focused canonical review suite: **11 tests, zero failures**. Evidence: `/private/tmp/ticket26-focused-final.log`. Covers batch order, duplicate activation, unknown-owner refusal, other-person visibility, rejection, text/date validation, note status round trips, Todo write-back, reassignment, independent speaker correction, archive guards, source rename, every file-transaction checkpoint, and injected SQLite review-commit failure/recovery.
- App-hosted controls: **one comprehensive test, zero failures**. Evidence: `/private/tmp/ticket26-hosted-final/{results.xcresult,tests.log,execution.json,report.json}`. Uses real temporary workspace files and the Meeting service; exercises individual keyboard acceptance, both batches, rejection, invalid due dates, retained drafts/focus, external conflicts, explicit reload, menu activation, status transitions, read-only controls, and empty/disabled states.
- Native UI: **two tests, zero failures**, followed by **one additional narrow-window/source-navigation run, zero failures**. Evidence: `/private/tmp/ticket26-native-final/` and `/private/tmp/ticket26-native-source-final/`, each with `results.xcresult`, logs, execution evidence and normalized coverage. Assertions cover the five-tab entry/navigation contract, unknown-owner controls, edits, save failure/retry, both batches, status changes, no Reopen, relaunch persistence, one canonical Todo reference, exclusion of others, an 880 × 680 window, and source navigation to Transcript.

All fixtures use disposable workspace/support roots; native fixtures also isolate media and preferences. No real Meeting library, credentials or model output is used as a fixture. The five package skips require separately opted-in real audio/replay/operational fixtures or signed-in ChatGPT quality evaluation. These skips do not represent ticket 26 approval behavior passing through a fake model.

Early native attempts caught a fixture being modified after canonical migration and an existing tab test expecting a Play control in a fixture with no audio. The fixture now seeds its other-person item before launch; the tab test asserts the audio section. No playable-audio capability is claimed for a text-only fixture. Failed attempts remain in `/private/tmp/ticket26-native1/`. Earlier successful test runs whose source changed during review were rejected by the collector as stale and are not used by the final gate.

Final coverage executions reused compilation caches through `/private/tmp/run-ticket26-coverage.py`, which invokes the repository collector, clears prior `Build/ProfileData` or package `release/codecov`, and creates fresh execution/result/report directories. Source compatibility is checked by the unchanged repository collector. No shipping compilation flag or coverage policy/exclusion changed.

## Coverage gates

The normal report route verifies every shipped source file, merges compatible lanes by source location, and enforces the **95% changed executable-line threshold**. It is not the reduced `--incremental-only` route.

```sh
python3 scripts/coverage.py report \
  --reports /private/tmp/ticket26-package-complete/report.json \
            /private/tmp/ticket26-hosted-final/report.json \
            /private/tmp/ticket26-native-final/report.json \
            /private/tmp/ticket26-native-source-final/report.json \
  --base 6ec9f9f \
  --output /private/tmp/ticket26-final-gate.json
```

| Changed module | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| Core | 145 / 145 | 100% |
| Presentation | 15 / 15 | 100% |
| App/UI | 233 / 234 | 99.57% |
| Combined | **393 / 394** | **99.75% — passes** |

The corresponding whole-source measurement is approximately **72.47%**, reported separately as existing debt for tickets 43–46/50. It is not a whole-app 95% claim. No source exclusions were added to reach the ticket gate.

## Standards

The code-review skill ran independent fresh-context Standards and Spec agents against this ticket's diff. Standards reviewed AGENTS.md, domain/ADR guidance, the Graphite Focus contract/profile and coverage contract, plus the skill's smell baseline. No CONTRIBUTING.md or CODING_STANDARDS.md exists.

Three documented issues were fixed: completion focus/announcements, editing-control labels, and wrapping essential status. The reviewer confirmed all three resolved. One possible Data Clumps heuristic remains nonblocking: text/owner/due/status parameters pass through the existing mutation layers. The reviewer confirmed those signatures follow the existing mutation convention and require no ticket 26 interface refactor.

## Spec

One defect was found and fixed: Todo text write-back depended on canonical artifact filenames. Lookup now recognizes notes/actions artifact markers; the rename regression verifies preserved identity and canonical write-back. The reviewer confirmed resolution and found no remaining material ticket 26 gaps or scope creep. Draft-base retention across refresh was independently checked and found sound.

Final review: **Standards — zero hard findings, one nonblocking heuristic (edit parameter grouping); Spec — zero findings.**

## Capability limits

No new hardware, speech, speaker-recognition, or grounded-model quality capability is claimed by this ticket. Ticket 25's unsupported local grounded inference and bounded remote-context limit, ticket 16's Person-directory/semantic-duplicate limits, and the separately recorded audio/model evaluation limits remain in force. Approval works on saved canonical artifacts and does not silently broaden capture scope, infer an unknown owner, or upload Meeting content. Whole-source 95% completion remains ticket 50 work.
