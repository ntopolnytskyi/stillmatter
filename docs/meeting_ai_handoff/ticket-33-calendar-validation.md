# Ticket 33 — Native calendar association and title precedence

Scope: [ticket 33](../../.scratch/meeting-ai/issues/33-associate-native-calendar-events-and-preserve-title-precedence.md), approved spec R2/R10/R14. Dependencies 08 and 13 were resolved before implementation. Review/coverage baseline: `4658adc04d2dcf46c102161cb8582d3eac735034`.

## Delivered behavior

Recording automatically selects one overlapping permitted Calendar occurrence without a picker or permission request. Matching uses half-open scheduled intervals, prefers an explicitly supplied matching meeting link when available, then the closest scheduled start, and breaks ties by stable calendar/event/occurrence identity. Events are reusable: separate recordings retain separate Meeting identities, folders and actual start times while referencing the same occurrence.

Calendar titles are retained verbatim, including Unicode, whitespace and characters unsuitable for folder names. Folder slugs remain separate. Persisted context records the selected event/calendar IDs, scheduled start/end, available event URL, fallback title and title provenance. Actual capture timestamps remain independent. Calendar context is a versioned doorway-file edit; it does not introduce a competing database authority.

Completed Meetings show calendar context beside their recorded time. **More → Calendar…** opens a focused sheet with event selection, Link, Unlink, Reset title and Cancel. It queries the selected Meeting's recording day, including after reopening an older Meeting. Missing permissions/sources and an empty event list are explained; impossible Link/Unlink actions are disabled. Escape cancels, Return activates an enabled Link action, and closing the sheet restores the previous responder. A separate confirmation warns about external links before a title/folder change. A stale Meeting/workspace cannot apply an earlier sheet's decision.

Manual titles survive association, relinking, unlinking and confirmed reprocessing. Explicit Reset title adopts the event title or original fallback. Metadata-only changes preserve the folder when the title stays the same. Title changes reuse the existing canonical no-alias folder/reference transaction, expected-version conflict checks and active-work restrictions. Archived association changes are rejected.

## Migration and isolation

Existing files have no reliable title-authorship provenance. Their titles are conservatively preserved until explicit Reset title; guessing from an `Untitled` prefix could overwrite a user's title. New captures persist the distinction. Canonical Markdown/legacy artifact migration and restart remain covered by the service tests. Valid external title edits become protected manual titles. Malformed context fails explicitly rather than being silently repaired during mutation.

Tests use disposable workspace, support, media and preference roots. Synthetic EventKit objects are never saved. The provider fixture overrides calendar/event enumeration and predicates; it never reads the user's Calendar data. Native tests retain the existing `.none` calendar-source isolation policy and seed a synthetic historical association in their own workspace.

## Executed verification

All final lanes pass against the same committed shipping source:

| Lane | Result | Evidence |
| --- | --- | --- |
| Full Release package | 543 tests; five expected opt-in fixture/live-quality skips; zero failures | `/private/tmp/ticket33-package4/{execution.json,tests.log,report.json}` |
| Focused Release hosted | Three tests; zero skips/failures | `/private/tmp/ticket33-hosted6/{execution.json,tests.log,results.xcresult,report.json}` |
| Focused Release main-app native | One test; zero skips/failures | `/private/tmp/ticket33-native5/{execution.json,tests.log,results.xcresult,report.json}` |

The five package skips are the existing real echo fixture, external Recording Bundle replay, opt-in operational fixture seeder, configured-workspace playback replay and live ChatGPT quality lane. None is a ticket 33 calendar test. Focused hosted/native execution is not a full application regression run.

Red-before-green failures established the missing matcher and calendar persistence/capture APIs. Early sandboxed tests could not perform Foundation atomic fixture replacement; the successful tests ran with the required test-service access. Other retained failed runs exposed an unnecessary folder rename on metadata-only changes, missing hosted read-model invalidation in the fixture, a test availability annotation, a recursive native test helper and an incorrect focus assertion. These were corrected. Package runs made while review changed shipping source correctly rejected their coverage as stale, even though their tests passed. No failed or superseded report contributes to the final gate.

Behavioral scenarios:

- Deterministic overlapping/tied selection, reordered input, nearest-start/link preference, interval boundaries, incomplete/missing events and repeated references.
- Exact non-Latin titles, folder-safe naming, separate actual/scheduled times and stable identities after restart.
- Relink/unlink/reset, conservative legacy title migration, authoritative external title edits, stale doorway conflicts and archived metadata protection.
- Valid capture with denied/unavailable calendar context; a later recording can reuse the earlier event without merging Meetings.
- Manual rename, relink, unlink and real-bundle confirmed reprocessing preserve the manual title, occurrence and actual start time.
- Hosted native controls cover duplicate event labels, historical-day querying, title-reset/folder-warning cancellation, sheet cancellation/focus, unavailable sources, repeated presentation and expired workspace decisions through the actual mutation executor/read-model path.
- Native main-app interaction covers More-menu entry, visible scheduled metadata, disabled Link without sources, Escape cancellation, persisted Unlink, unchanged manual title and relaunch, plus disabled Unlink after removal.

Typechecking is supplied by SwiftPM and Xcode builds. `git diff --check` and Graphite structural validation pass. Graphite presentation validation retains the pre-existing `TranscriptReaderView.swift:438` visual-literal finding, also documented by tickets 30 and 32; this ticket does not edit that file.

## Coverage

The normal complete-source report command exits **0**, with **258 / 266 = 96.99% changed executable-line coverage**. Every required shipped source has an executable-line map. Compatible lanes merge by source location without double counting.

| Changed module | Covered / executable | Coverage |
| --- | ---: | ---: |
| Core | 102 / 103 | 99.03% |
| Presentation | 8 / 8 | 100% |
| App/UI/platform | 148 / 155 | 95.48% |
| Combined | **258 / 266** | **96.99%** |

The same focused-lane union measures existing whole-source debt at **18,094 / 26,078 = 69.38%**: Core 94.23%, Presentation 81.99%, runtime 94.24%, app/UI/platform 44.72%. This does not pass or claim ticket 50's independent whole-source 95% requirement. Earlier slices used different focused UI scenarios, so their whole-source figures are not equivalent regression comparisons.

No coverage threshold, shipping flags, inventory exclusion or coverage policy changed.

Executed commands used the existing `/private/tmp/run-ticket27-coverage.py` wrapper around the repository collector to reuse compilation caches with fresh profiles and output directories:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py package \
  /private/tmp/ticket33-package4 /private/tmp/ticket27-package-cache

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py hosted \
  /private/tmp/ticket33-hosted6 /private/tmp/ticket27-hosted-cache \
  StillmatterHostedTests/MeetingCalendarHostedTests

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py native \
  /private/tmp/ticket33-native5 /private/tmp/ticket27-native-cache \
  StillmatterUITests/StillmatterFlowsUITests/testCalendarFallbackKeyboardCancelUnlinkAndRelaunchPersistence

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 scripts/coverage.py report \
  --reports /private/tmp/ticket33-package4/report.json \
            /private/tmp/ticket33-hosted6/report.json \
            /private/tmp/ticket33-native5/report.json \
  --base 4658adc04d2dcf46c102161cb8582d3eac735034 \
  --output /private/tmp/ticket33-final-gate.json
```

Reproduce without the temporary cache wrapper using `scripts/run-coverage.py package|hosted|native --output <fresh-directory>`, adding the same hosted/native `--only-testing` filters. The repository collector creates new build roots and profiles itself.

## Standards

Independent fresh-context Standards review initially found the separate management button, editing alert and repeated optional-context policy. Calendar now uses the existing More menu, a dedicated sheet and resolved title policy before canonical rename. A subsequent legacy rename-warning finding led to one shared preview/commit policy and a regression test. Final review of commits through `731a3c3`: **0 documented violations, 0 baseline smell findings**.

## Spec

Independent Spec review found historical relinking and legacy folder-warning gaps. Both were fixed and re-reviewed. The final conservative legacy-title migration was also reviewed. Final review through `731a3c3`: **0 remaining findings, no scope creep**.

Review totals: Standards **0**, Spec **0**; neither axis has a remaining worst issue.

## Capability limits

The current Teams detection/capture adapter does not expose a reliable call meeting URL or richer meeting title. Production automatic association therefore uses permitted EventKit timing; link preference is tested at the matcher seam and only applies when a caller supplies supported evidence. There is no claim of Teams-link extraction or guessed source metadata. Without a matching event, the existing useful recording-time fallback remains.

Synthetic EventKit integration verifies mapping, source selection and denied/unavailable states, not live calendar-account synchronization, user-granted macOS permission behavior or external-provider event-ID changes. These tests do not authorize or use real user calendar content. Calendar association never broadens audio scope, changes source-isolation claims or establishes model quality. Earlier ASR, diarization, capture and local-analysis capability limits remain with their originating tickets. This ticket makes no release-wide lifecycle or whole-source completion claim.
