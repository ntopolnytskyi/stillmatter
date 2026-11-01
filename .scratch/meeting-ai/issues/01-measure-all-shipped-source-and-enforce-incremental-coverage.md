# 01: Measure all shipped source and enforce incremental coverage

**What to build:** Deliver a reproducible package/app coverage route, production-source completeness checks, per-module reports, and a 95% new/changed-line gate. Document baseline debt without claiming it already meets the final gate. Test omitted-file and duplicate-report detection; keep GUI automation distinct from package execution.

**Blocked by:** None (can start immediately)

**Status:** resolved

**Type:** task

**Requirements:** R14.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

## User experience

This slice introduces no new interactive page or control. Verify its observable outputs and existing behavior as specified below; avoid adding unrelated UI.

## Acceptance criteria

- [x] Inventory every shipped first-party Swift source file using the shipping configuration; account explicitly for generated, third-party, and non-shipped validation code.
- [x] Combine package, hosted-app, and native-UI instrumentation by executable source location without double-counting shared modules.
- [x] Fail the report if shipped production source is absent; display covered/total lines per module and aggregate.
- [x] Enforce 95% on new/changed executable lines and provide the final whole-source 95% gate without falsely claiming current baseline debt is resolved.

## Required tests

- [x] Feed reports containing duplicate module/file entries and verify the merged denominator is counted once.
- [x] Omit an app/platform source file and prove completeness validation fails even if remaining coverage exceeds 95%.
- [x] Reproduce the package baseline and a coverage-enabled app route on isolated roots; distinguish skipped/unexecuted native tests from passing ones.

## Completion evidence

- [x] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [x] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [x] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.


2026-11-01 — Implemented and verified ticket 01. See [coverage contract and complete evidence](../../../docs/meeting_ai_handoff/coverage.md).

- Shipping inventory evaluates SwiftPM product reachability and reconciles Xcode membership: 113 Swift files, 21 individually justified/hash-frozen non-shipped validation exclusions, 92 required source files. Exact source hashes, Package.swift, shipping Release settings, Swift/Xcode versions and configuration prevent incompatible report merges. Duplicate module/file/line records merge by source location without double counting; absent/empty app/platform coverage fails.
- Tests: 34 Python tool behavior tests passed; fresh historical Debug package baseline reproduced 303 tests / 4 skipped / 0 failures; shipping-condition Release package route also passed 303 / 4 skipped / 0 failures. Separate native full run passed 13 / 0 skipped / 0 failures after replacing a Debug-only proposal seed with a real isolated workspace-scoped TasksInbox fixture. Separate hosted app route passed 2 / 0 skipped / 0 failures. All workspace/media/support/preferences roots were disposable; no real library or model was used.
- Native/hosted coverage used Release -Onone and x86_64. Successful results are retained under `/private/tmp/stillmatter-meeting-ai-01-native-fixed/results.xcresult` and `/private/tmp/stillmatter-meeting-ai-01-hosted-results/hosted-results-release.xcresult`. The failed initial hosted fixture result is retained beside it. Corrected re-exports verified unchanged original source hashes and shipping flags; normalized evidence is `/private/tmp/stillmatter-meeting-ai-01-exported/{package,hosted,native}/`.
- The complete union measures every required file: Core 6704/7453 (89.95%), Presentation 1113/1273 (87.43%), runtime 93/183 (50.82%), app/UI/platform 6445/10146 (63.52%); aggregate **14355/19055 (75.33%)**. This is measured existing debt, not final completion.
- Actual incremental gate exited 0 with **0 changed shipped executable Swift lines (not applicable, 0/0)**. Tool fixtures prove exact 95% pass/fail behavior; actual final whole-source gate exited 1 at 75.33%. Package-only coverage correctly exited 2 for 43 absent app/platform files. Ticket 01 establishes the gates; tickets 43–46/50 must close existing debt before spec completion.
- No product UI behavior, migration schema, hardware capability or model-quality requirement changed. Existing native persistence/relaunch/conflict assertions passed. Ticket 01's blockers may now consume this evidence; unrelated capture/model blockers remain in force.
- 2026-11-01 review fixes: incremental diff parsing decodes Git C-quoted paths and removes unified-diff tab-delimited timestamps without altering legal filenames. Both diff and LCOV records use LF-only framing, preserving U+2028/U+2029 in filenames. File headers are recognized only outside hunks, so added multiline-string content cannot change the current source path. Git-generated regressions cover spaces, quotes, backslashes, tabs, newlines, Unicode, both Unicode separators, and hunk-content lookalikes; uncovered changed lines are included and fail the 95% threshold. All 34 coverage-tool tests pass. The recomputed baseline union remains 14,355/19,055 (75.33%), and the actual incremental gate remains 0/0 because this slice changes no shipped Swift executable lines.
