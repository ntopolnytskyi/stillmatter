# Ticket 28 — Today Meeting review reminders

Ticket: `.scratch/meeting-ai/issues/28-show-one-today-review-reminder-per-meeting.md`.
Review and coverage baseline, confirmed by the user: `5e4c687306bac9ade33d5b36c32a63de7ded9229`.
Only ticket 28 is resolved. Dependencies 06, 17 and 26 were resolved and their evidence read before implementation.

## What changed

Today shows one compact review row for each Meeting with pending Action Items. The row shows the Meeting title and current pending count, including mine, other-person and unknown-owner items. It opens that Meeting's Action Items directly. Individual proposals are no longer rendered in Today's old review panel; approved personal work keeps its existing canonical Queue identity.

Counts refresh after approval, batches, rejection, external edits, artifact rename, deletion and workspace changes. They include explicitly pending canonical My Notes items because those also appear in Meeting review. Zero pending removes the reminder. Archived Meetings are excluded. Metadata-free external checkboxes in already migrated artifacts do not masquerade as reviewable items; the existing explicit adoption/save contract remains in effect.

The projection reads canonical files without migrating, adopting, recovering or repairing them. Shared artifact resolution and cross-file identity validation keep it consistent with Meeting reads. Coordinated reads check Meeting and workspace-tag publication journals; unfinished publication produces an explicit recovery message instead of a partial count. Opening the Meeting explicitly can recover its saved publication.

Activation rechecks the current workspace and Meeting target. The asynchronous route handles identical browser snapshots, missing targets and failed browser/detail reads. An unavailable target returns to Today with inline feedback. Switching workspace cancels the pending route. Cancelling an unsaved-edit prompt preserves the original draft and cancels the route; failed Save keeps the existing recovery flow. Leaving and returning to Meetings rebuilds its cleared controls.

## Verification

Final runs use compatible source inventories and fresh profiles:

| Lane | Tests | Skipped | Failures | Evidence directory |
| --- | ---: | ---: | ---: | --- |
| Full Release package | 525 | 5 existing fixture/capability skips | 0 | `/private/tmp/ticket28-package3` |
| App-hosted controls/navigation | 11 | 0 | 0 | `/private/tmp/ticket28-hosted5` |
| Main-app native UI | 1 comprehensive flow | 0 | 0 | `/private/tmp/ticket28-native8` |

Each directory contains execution metadata, tests.log, inventory and normalized coverage. Hosted/native directories also retain results.xcresult. The focused package run in `/private/tmp/ticket28-core-final.log` passed 19 tests.

Canonical tests verify two-Meeting counts, no individual proposals or pending/other-person Queue promotion, individual/batch/rejection refresh, zero removal, external edits and renamed artifacts, workspace isolation, deletion, archive exclusion, malformed/duplicate identities, read-only legacy discovery, interrupted publication and recovery. Existing read-loader tests verify stale workspace completion and disposal suppression.

Hosted navigation tests control browser reads through the public read-source boundary. They delete the target or switch workspace while reading, verify missing/failed targets end the request, exercise repeated activation with an unchanged snapshot, and verify dirty-draft Cancel followed by a successful retry. Hosted control tests verify Space/Return activation, focus after count changes and removal, empty/error feedback and shared controls at a small window size.

The main-app native test seeds two Meetings with personal, other-person and unknown-owner pending work. At 880×680 it verifies grouped rows/counts, correct Action Items selection, batch approval, return navigation, count reduction, individual rejection, zero removal, personal Queue visibility, live external deletion refresh and relaunch persistence. Viewing Today preserves canonical files; explicit Meeting open uses the existing migration behavior. Fixtures isolate workspace, support, media and preferences from user data.

SwiftPM/Xcode compilation provides typechecking. Graphite structural validation and rejection self-tests pass. The presentation validator reports the existing visual literal in unchanged `Sources/Stillmatter/Features/Meetings/TranscriptReaderView.swift:426`, also recorded by ticket 27; this ticket does not resolve that baseline finding.

## Coverage gate

The unchanged repository collector was run using `/private/tmp/run-ticket27-coverage.py`, the existing cache-reuse wrapper. It reuses compilation caches, deletes prior profiles, writes fresh result directories and selects the executed architecture. Release instrumentation, source inventory, coverage policy and exclusions remain unchanged.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py package \
  /private/tmp/ticket28-package3 /private/tmp/ticket27-package-cache

python3 /private/tmp/run-ticket27-coverage.py hosted \
  /private/tmp/ticket28-hosted5 /private/tmp/ticket27-hosted-cache \
  StillmatterHostedTests/TodayMeetingNavigationHostedTests \
  StillmatterHostedTests/TodayTasksControlsHostedTests

python3 /private/tmp/run-ticket27-coverage.py native \
  /private/tmp/ticket28-native8 /private/tmp/ticket27-native-cache \
  StillmatterUITests/StillmatterFlowsUITests/testTodayGroupsMeetingReviewsAndOpensActionItemsWithLiveCounts

python3 scripts/coverage.py report \
  --reports /private/tmp/ticket28-package3/report.json \
            /private/tmp/ticket28-hosted5/report.json \
            /private/tmp/ticket28-native8/report.json \
  --base 5e4c687 --output /private/tmp/ticket28-final-gate.json
```

The normal complete-source gate exits **0**. Compatible reports merge by source location without double counting; every shipped source file is represented.

| Changed module | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| Core | 92 / 92 | 100% |
| Presentation | 4 / 4 | 100% |
| App/UI | 79 / 88 | 89.77% |
| Combined | **175 / 184** | **95.11% — passes the required aggregate gate** |

Whole-source measurement from these lanes is **18,760 / 25,292 = 74.17%**: Core 94.17%, Presentation 86.09%, runtime 94.24%, app/UI/platform 53.84%. This is existing completion debt; ticket 50's whole-source 95% gate is not satisfied by this ticket.

Earlier failed runs remain in `/private/tmp/ticket28-*`. They reproduced asynchronous tab resets, cleared controls on return, unchanged-snapshot routing and absent external-file invalidation. Earlier full package suites passed, but their collectors correctly rejected inventories changed by subsequent fixes. Only the final compatible reports above establish this coverage result. Initial sandbox-only attempts failed on Swift's cache/nested sandbox and coordinated writes; executed lanes used authorized Xcode/Swift test access to disposable fixtures.

## Standards

A fresh-context Standards agent reviewed `git diff 5e4c687...HEAD`, with repository/domain/ADR guidance, Graphite contracts, canonical identity and coverage contracts, UI-testing guidance and the code-review skill's smell baseline. The initial transaction-visibility violation and duplicated artifact resolution were fixed and re-reviewed. Final result: **zero documented-standard violations or actionable baseline smells**.

## Spec

A separate fresh-context Spec agent reviewed ticket 28 and R1/R3/R5/R14. Findings about unreviewable external checkbox counts, premature navigation completion, missing targets, unchanged browser snapshots and dirty-selection cancellation were fixed and re-reviewed. Final result: **zero remaining spec findings or scope creep**.

Final review totals: Standards **0**, Spec **0**.

## Capability limits

This ticket introduces no model, recording-source or hardware capability. Controlled sources verify read ordering and UI behavior, not real model quality. Ticket 25's unsupported fully local grounded analysis, bounded-context limit and approved Pi/ChatGPT transfer policy remain in force. Earlier source-isolation, mixed-language and speaker-quality limitations retain their original evidence; none are silently weakened here.

Whole-source coverage and the complete lifecycle release gate remain ticket 50 work.
