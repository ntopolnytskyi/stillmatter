# Stillmatter Graphite Focus conformance review

Ticket: `.scratch/graphite-focus-ui/issues/15-conformance-and-legacy-contract.md`

## Automated evidence (2026-09-27)

- `./scripts/validate-graphite-focus-contract.py --self-test` — passed.
- `./scripts/validate-graphite-focus-presentation.py --self-test` — passed; scans all active feature `*View.swift` files, shell, and Weekly Report prompt. Legacy `SettingsViewController` and empty formatted-text shell fallback removed. Zero-gap divider-led collections use `Space.flush`; migrated Settings uses semantic typography and spacing.
- `./scripts/test-native-shell-layout.sh` — passed; fixtures cover 720×520, 1200×760, 1440×760 and state preservation across collapse. A whole-window Area Search regression uses a real two-result fixture at narrow and reference widths: focus stays on results after the compact popover closes, after Up/Down navigation and a pause, and across a background shell refresh. It also checks ordinary compact-popover dismissal restores focus to the invoking results control. A recurring Teams Detection Signal triggers that refresh about every three seconds.
- `./scripts/test-graphite-focus-presentation.sh`, `./scripts/test-contextual-ask-layout.sh`, `./scripts/test-weekly-report-window-layout.sh` — passed.
- `swift test` — 165 tests, 2 skipped, 0 failures.
- `./scripts/test-build-app-signing.sh` — passed; stable valid designated signature.

Automated checks do **not** establish VoiceOver reading order, Full Keyboard Access navigation, contrast ratios on every surface, or Long-Session Comfort. The only profile exception remains `SM-EX-002` (dark-only).

## Human Experience Review

Run `./scripts/build-app.sh`, then open `.build/Stillmatter.app`. Use a disposable workspace for mutation checks. At 1200×760 and 720×520, and at 1440×760 where extra width matters, record pass/fail and a brief observation for each:

| Surface | Inspect and exercise | Result / observation |
|---|---|---|
| Today | Required/Review/Attention, Daily Brief, Queue, Meetings, Activities; empty/unavailable states | Reported pass (owner; no individual observation) |
| Meetings | Idle/preflight degraded and blocked, live Capture Session, Stop and processing evidence; Teams observation never implies capture | Reported pass (owner; no individual observation) |
| Tasks | Queue order, filters, status, due/source, keyboard row selection | Reported pass (owner; no individual observation) |
| Projects / Activities | Browser/detail, creation sheet, drafts and back navigation during resize | Reported pass (owner; no individual observation) |
| Area Search | Toolbar and menu access, kind filter, selection/open, no results; narrow popover. **Retest:** with several results at narrow width, press Down from search, then Up/Down repeatedly; focus must stay in results until explicitly moved. | Reported pass (owner; no individual observation) |
| Ask AI | Privacy and scope, broader-vault selection, citations, long answer measure | Reported pass (owner; no individual observation) |
| Settings | Form width, permission/component diagnostics, validation near fields | Reported pass (owner; no individual observation) |
| Action Item review | Selected count, Accept/Merge/Reference Only/Dismiss, distinction from Todo Item | Reported pass (owner; no individual observation) |
| Weekly Report | Editable prompt, Accept/Remind, focus return | Reported pass (owner; no individual observation) |

Across representative surfaces: enable **Increase contrast**, **Reduce transparency**, and **Reduce motion** in macOS Accessibility settings; compare active/inactive windows, text and structural stroke contrast, static status meaning, and motion. Enable **Full Keyboard Access** and traverse toolbar → sidebar → list → detail → transient surface; use arrow/Return and confirm focus restoration on dismiss. Use **VoiceOver** to inspect icon-only labels, status values, and reading order. Check long localized-looking labels, source paths and explanations at minimum width for clipping. Check restrained accent, limited Semantic Panels, native control/focus character, comfortable prose measure, structured data using available width, destructive-action separation, and sustained-use comfort. Note any failures and justified exceptions here before signing off.

**Owner verdict:** Passed per owner report on 2026-09-28: “I accomplished the tests everything is ok,” followed by an explicit request to mark all checks passed and close the ticket. This is an owner attestation, not nine independently recorded observations; macOS version was not supplied. Ordinary compact-search dismissal has automated focus coverage; other transient dismissals (including Weekly Report review) rely on owner sign-off and existing production restoration behavior, not exhaustive whole-window automation. **Residual exception:** `SM-EX-002` (dark-only). Revisit any area if a later observation contradicts this report.
