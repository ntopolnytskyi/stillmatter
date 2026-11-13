# Ticket 27 — Shared tags and additive AI tagging

Ticket: `.scratch/meeting-ai/issues/27-share-tags-across-markdown-items-and-allow-ai-additive-tagging.md`.
Review and coverage baseline: `91eac2e8a409cf8efae4286c543cf5396dfc6bd3`.
Dependency 26 was resolved and its evidence was read before implementation. Scope is ticket 27 only. The user confirmed canonical item/store and native control test boundaries, and this review baseline.

## User-visible changes

Action Items and Todo display the same item's inline tags as native capsules, separately from the owner and task text. Their shared tag editor selects and removes multiple tags, creates reusable global tags, and renames/deletes tags across canonical checkboxes. Names accept Unicode letters, numbers, underscores and hyphens; the field explicitly asks for a name without `#`. Unused created tags survive restart in `Tags/tags.json`; existing inline tags are discovered from authoritative Markdown.

Native Tab/Space/Return controls remain available; Command-Return creates a tag. Errors preserve input and catalog selection. Save-in-progress and read-only states disable mutation controls. Closing the sheet restores the logical source button even when its item view has refreshed. The selected item's tags remain shared when navigating from Meeting to Todo and reopening the app.

AI analysis can return optional `tag_additions` entries containing only `item_id` and ordinary `tags`. The existing validated Pi RPC path applies them automatically without another acceptance prompt. Each patch resolves an existing canonical UUID in the current Meeting. Unknown patch mutation keys, reserved tags, missing targets and invalid names reject publication. AI never receives a task-text/owner/status/review mutation operation through this interface.

Both initial analysis of saved live-note tasks and later analysis of migrated artifacts support these patches. Initial publication recovers any interrupted plan before reading source versions, then commits generated outputs and note tag additions together.

Patches merge into the latest saved checkbox, preserving concurrent user text, owner, due, status, approval and identity metadata. Generated pending proposals retain `#ai-gen #need-approve`; approval removes only `#need-approve`. Editing, completion and regeneration retain provenance and ordinary tags. Already-approved note items receive only ordinary additions and keep their user-authored provenance.

## Persistence and isolation

The existing canonical checkbox metadata and recoverable, version-checked artifact transactions remain the authority. Todo references are not mutable copies. Global tag edits publish all affected files and the tag catalog through one durable plan; reopen recovers after each file boundary. No task schema migration or duplicate item store was introduced.

Global scanning excludes app-support snapshots, including when macOS temporary-path aliases refer to the same directory. Fenced examples, inline code, links and unrelated note prose remain intact. Standalone Todos retain their existing positional identities; exact line verification ensures selecting the second of two identical rows changes that row only. Canonical Meeting/note UUIDs remain stable across views.

All fixtures use disposable workspaces and support roots. Native fixtures additionally isolate media and preferences. No real library, credentials, recording or provider response is used as a fixture.

## Tests and coverage

Final, source-compatible executions:

| Lane | Executed | Skipped | Failures | Evidence directory |
| --- | ---: | ---: | ---: | --- |
| Full Release package suite | 520 | 5 existing capability/fixture skips | 0 | `/private/tmp/ticket27-package-final3` |
| Focused app-hosted controls | 8 | 0 | 0 | `/private/tmp/ticket27-hosted-final2` |
| Focused main-app native UI | 2 | 0 | 0 | `/private/tmp/ticket27-native-final3` |

Each directory retains `execution.json`, `tests.log`, inventory, normalized coverage and (for native/hosted) `results.xcresult`. The native tests verify the shared tag editor and existing Action Item approval flow, including an 880 × 680 window, keyboard creation/return focus, invalid-input retry, empty selection, global rename/delete, same canonical Todo identity, relaunch persistence and source navigation. Hosted tests additionally verify busy/read-only controls, reserved-tag protection, failed-rename selection and existing Todo failure behavior.

The existing five package skips require separately opted-in operational/audio fixtures or a real signed-in provider quality evaluation. They are not passing claims for untested model/hardware behavior.

The final collector reused compilation caches while removing prior profiles before every lane and creating fresh result/output directories. `/private/tmp/run-ticket27-coverage.py` calls the unchanged repository collector, redirects only its cache roots, and builds the executed architecture with `ONLY_ACTIVE_ARCH=YES`. Release compilation conditions, `-Onone` coverage configuration, source-inventory checks and coverage policy/exclusions are unchanged.

Final gate command (exit status **0**):

```sh
python3 scripts/coverage.py report \
  --reports /private/tmp/ticket27-package-final3/report.json \
            /private/tmp/ticket27-hosted-final2/report.json \
            /private/tmp/ticket27-native-final3/report.json \
  --base 91eac2e --output /private/tmp/ticket27-final-gate.json
```

This is the normal complete-source report route. Every shipped source is represented; compatible reports merge by source location without double counting. No exclusions were added.

| Changed module | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| Core | 244 / 248 | 98.39% |
| Presentation | 7 / 7 | 100% |
| App/UI | 202 / 207 | 97.58% |
| Combined | **453 / 462** | **98.05% — passes the 95% gate** |

Whole-source measurement is separately **18,848 / 25,125 = 75.02%** (Core 94.13%, Presentation 85.92%, runtime 94.24%, app/UI/platform 55.65%). This is existing completion debt for tickets 43–46/50, not a claim that the final whole-source gate passes.

The focused canonical/RPC/regression run passed 12 tests in `/private/tmp/ticket27-review-fixes2.log`. The final related Summary/tag run passed 34 tests with one existing live-model-quality skip in `/private/tmp/ticket27-initial-recovery-green.log`, including initial-analysis tagging and interrupted-publication recovery. The shared editor and existing Action Item hosted run passed three tests in `/private/tmp/ticket27-review-ui-green.log`. Earlier native runs verified Meeting → Todo → relaunch, narrow-window operation, reserved lifecycle behavior and source navigation. Earlier successful reports with changed shipping source are not used for the final gate.

Initial red/green runs reproduced missing interfaces, duplicate additions, lifecycle tag loss and the two review defects before their corrections. The first full package run found a nested-support snapshot discovery regression; the existing live-notes test now passes after path canonicalization. The extra native focus assertion reproduced lost focus before its fix. Failed runs remain in `/private/tmp/ticket27-*` for diagnosis and are not passing coverage evidence.

Graphite Focus structural validation passes. The presentation validator reports an existing visual literal in unchanged `Sources/Stillmatter/Features/Meetings/TranscriptReaderView.swift:426`; this ticket does not change that source or claim to resolve that baseline debt.

## Standards

The code-review skill ran a fresh-context Standards reviewer against `git diff 91eac2e...HEAD`, using AGENTS/domain/ADR guidance, Graphite Focus contracts, canonical identity and coverage contracts, UI-testing guidance and the skill's smell baseline.

The reviewer identified loss of catalog selection after a failed rename. The fix selects the renamed value only after successful persistence; the hosted regression verifies a failed rename of a nonfirst tag preserves both selection and typed input. The reviewer rechecked the complete updated diff and confirmed **zero outstanding documented-standard violations or actionable baseline smells**.

## Spec

A separate fresh-context Spec reviewer checked ticket 27 and R5/R6/R14. The reviewer found that identical standalone Todo lines could cause a tag edit to modify the first row. The fix records and verifies the exact line number. Its regression selects the second identical row and asserts that the first is unchanged. The reviewer rechecked the updated diff, including initial-analysis support and restart recovery, and confirmed **zero remaining spec findings or scope creep**.

Final review totals: Standards **0**, Spec **0**.

## Capability limits

Global rename/delete rejects the entire action when an affected item belongs to an archived Meeting. It does not silently skip that item or edit read-only archived content. The shared editor also respects archived read-only state when reached through Todo.

Tag application and protected persistence are verified through controlled provider output, including the actual validated RPC executor. These tests do not establish real-model suggestion quality. The existing user-approved Pi/ChatGPT analysis path and transfer-approval policy remain in force; ticket 25's unsupported fully local grounded inference and bounded-context limit remain documented there. No new hardware, source-isolation, recognition or local-model quality capability is claimed.

Whole-source 95% completion remains ticket 50; this ticket enforces its own 95% new/changed executable-line gate and reports existing whole-source debt separately.
