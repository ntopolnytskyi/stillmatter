# 07: Use shared controls in Meetings, Search, and shell navigation

**What to build:** Complete the mechanical migration, then remove obsolete duplicate controls only once all consumers use the shared form. UI: always-visible Status Bar with global search; icon-only Sidebar; Listing filters above rows; Detail Workspace to its right. Preserve destinations, compact rows, distinct global search/list filters/in-meeting find, and narrow Back navigation. Use the same shell slots for future pages. Tests cover resize, keyboard search, stable selection, and shared style propagation across pages.

**Blocked by:** [05: Use shared controls in Recording and Settings](05-use-shared-controls-in-recording-and-settings.md)

**Status:** resolved

**Type:** task

**Requirements:** R1, R3, R14.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

## User experience

- Entry: app shell at launch and every Sidebar destination; Settings stays bottom-anchored in the icon-only Sidebar.
- Layout: Status Bar spans the top; below it Sidebar is left, Listing with filters is next, Detail Workspace is right.
- Actions: global search searches its displayed scope; Listing filters constrain rows; Back returns to the retained Listing state.
- States: loading/no selection/no results/error have explicit content rather than stale selected-item details.
- Keyboard: preserve global-search and destination shortcuts, result traversal, selection/open and narrow Back; keep Status Bar visible.

## Acceptance criteria

- [x] Build the shared Status Bar/Sidebar/Listing/Detail Workspace composition from existing shell controls.
- [x] Keep global search always visible above page scrolling; Listing filters and in-meeting find remain separate scopes.
- [x] Migrate Meetings/Search/navigation to common controls, removing obsolete duplicates only after their consumers are migrated.
- [x] Retain selected item/filter/query across supported narrow Listing-to-detail transitions.

## Required tests

**UI test execution:** Run UI tests only when this implementation changes UI code. If UI code is unchanged, do not run UI tests; record “UI tests skipped: no UI code changed” in the completion evidence. This condition applies to all UI/native interaction test requirements in this ticket. Continue running relevant non-UI tests.

- [x] Use real windows at supported wide/narrow sizes and assert Status Bar visibility, usable columns and Back preserving selection.
- [x] Focus global search by shortcut, move through results and open the owning area; verify filters do not mutate the global query.
- [x] Verify shared control changes reach shell/search/Meeting consumers and navigation alone leaves content files unchanged.

- [x] Native interaction tests cover the changed controls, applicable shortcuts/focus, resulting persisted state, and the relevant empty/disabled/error case. Use semantic test identifiers and observable waits; source-text checks or screenshots without assertions do not substitute for behavior.

## Completion evidence

- [x] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [x] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [x] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. Blocker 05 is merged (PR #4); blocker 01 is resolved.

2026-11-02 — Partial implementation on this branch (not resolved). Migrated Meeting listing filters/queue buttons and detail selector/actions, Search state actions, and shell navigation/search/back construction to shared GraphiteFocusControls. Search result cell typography remains unchanged. Native shell still uses an NSToolbar and switches to a popover when Search is removed by toolbar customization; the always-visible Status Bar/global-search contract is **not fully met**. Search activation still opens source files externally instead of navigating to the owning area; generic Listing/Detail slots for future pages, narrow resize/back assertions, and full shared-row migration remain outstanding. Do not mark acceptance criteria complete or treat the existing two-tab Meeting detail as the five-tab ticket 18 workspace.

Focused hosted controls: 2 passed; focused native filter/search: 1 passed after correcting two test assertions that queried inaccessible/filtered elements. Full package: 357 tests / 4 skipped / 0 failures; hosted: 20 / 0 / 0; native: 21 / 0 / 0 on isolated test roots. After the final narrow-toolbar edit, the full three-lane rerun passed: package 357 / 4 skipped, hosted 20 / 0 skipped, native 21 / 0 skipped; zero failures. Compatible incremental coverage is 45/45 (100%) against the pre-ticket HEAD; whole-source is 16,103/20,333 (79.20%), not the final 95% gate. Reports are under `/tmp/stillmatter-07-{package,hosted,native}-last/` and `/tmp/stillmatter-07-gate-last.json`. The native suite does not yet assert global Search's physical visibility at 720 px or narrow Back selection persistence. No migration or hardware/model capability was changed or claimed.

2026-11-02 — Resolved. Search now lives in a fixed Status Bar outside toolbar customization; Meetings filters and global Search remain independent. Search results navigate to Tasks or Meetings and select the matching Meeting after its owner area is active. Meetings/Search row typography now comes from shared row styling, while each table retains its native selection and keyboard behavior. A real-window UI test resizes to 1200×760 and 720×520, asserts Search remains on-screen and the Listing/Detail Workspace remains usable, then verifies Back restores the selected Meeting. Search keyboard/result routing, Todo result type filtering, query retention, and no-results behavior are covered in UI tests.

Final Release evidence against `157b927`: package 357 tests / 4 skipped / 0 failures; hosted 20 / 0 skipped / 0 failures; native 24 / 0 skipped / 0 failures. The minimum-window UI test was rerun focused after adding the wide-size assertions and passed. Combined new/changed executable-line coverage is 105/109 (96.33%), above the 95% gate. Whole-source coverage is 16,162/20,271 (79.73%), still below the final ticket 50 gate. Graphite Focus structural and presentation validators, source inventory, and `git diff --check` passed. UI tests use isolated workspace, Application Support, and media roots. No migration, live model, or hardware behavior was changed or claimed.
