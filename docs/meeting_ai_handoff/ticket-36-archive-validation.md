# Ticket 36 — Resolved-only Meeting archive

Scope: ticket 36 only, after resolved dependencies 17, 26 and 29. Review baseline: `6a2c52151bb587ec90d339586e40a0658e69f2f0`. Environment: macOS 15.8.3, x86_64; native Xcode Release and package Release with coverage enabled.

## Delivered behavior

Archive is an explicit one-way app command. A Meeting must be Ready, stopped, without queued/running owned Jobs, and without pending, open or postponed Action Items of any owner. Completed items and rejected/dismissed proposals do not block it. Completing the last task never archives a Meeting automatically. The same eligibility explanation controls the button, tooltip and visible detail status. The service re-reads authoritative state when a command arrives and rejects ineligible or already archived Meetings.

Active and Archived remain separate from processing states. Default Listing and keyword search exclude archives. Explicit Archived Listing queries include them. Search reads the current lifecycle marker, so an external archive-flag edit affects indexed-result visibility without rebuilding the index. Archive records an ISO-8601 archive date; old boolean-only markers remain readable without inventing a date.

Archived Meetings retain the five tabs, evidence navigation and existing retained playback. Editors, new-item controls, rename/calendar/reprocess and failed-Job Retry are unavailable. Restore has been removed from the command model, executor and service. More preserves calculated menu eligibility rather than letting AppKit re-enable disabled actions, and retains the existing Remove action independently of reprocessing eligibility. External valid file edits remain authoritative; no filesystem lock or archive-editing workflow was added.

## Behavioral evidence

- Real disposable workspace fixtures cover Me, another person and unknown owner with pending/open/postponed/completed/rejected/dismissed states, including a completed checkbox that still needs approval.
- Service tests reject incomplete, recording and queued Meetings, preserve artifacts and external links, retain archive metadata across a new service instance, reject duplicate archive commands, accept external archived-note/flag edits and preserve retained playback.
- A real keyword index verifies immediate default exclusion, explicit archive inclusion and archive-aware Listing queries. A real failed Job verifies that an external archive edit blocks Retry without dispatch; clearing that flag externally restores the ordinary retry behavior.
- Native interaction completes the last note task through Action Items, verifies that no archive marker appears until explicit Archive, observes the row leave Active, relaunches, selects Archived, visits all five tabs and uses Option-Command-Left. It asserts unavailable editors, no Restore, disabled archive/rename/regeneration and enabled Remove. A legacy boolean-only archive fixture separately verifies retained content and disabled editors.
- App-hosted controls verify archive failure text and retry availability without moving the Meeting, disabled Retry for a real externally archived failed Job, and related outcome/read-only/shared-control behavior.
- Workspace, media, operational support, preferences and secret namespaces use the existing disposable-fixture isolation. No user library or live model/provider is used as archive evidence.

## Executed verification

Final-source execution evidence:

| Lane | Result | Artifacts |
| --- | --- | --- |
| Full Release package | 559 tests, 5 opt-in skips, no failures | `/private/tmp/ticket36-package2/{execution.json,tests.log,report.json}` |
| Release app-hosted controls | 6 tests, no skips or failures | `/private/tmp/ticket36-hosted2/{execution.json,tests.log,results.xcresult,report.json}` |
| Release main-app native | 2 tests, no skips or failures | `/private/tmp/ticket36-native5/{execution.json,tests.log,results.xcresult,report.json}` |

Earlier source-incompatible or failed diagnostic runs are excluded from the coverage union.

The five package skips are the existing real-Meeting echo fixture, real recording-bundle echo replay, explicit operational-fixture seeder, configured-workspace playback replay and live signed-in ChatGPT quality lane. All new archive tests executed. Focused final service regression also passed 61 tests with only the same opt-in playback replay skipped.

The final changed-line gate passes: **74/77 executable lines = 96.10%**. Core is 52/55 (94.55%); app/UI is 22/22 (100%). The aggregate is the shared incremental gate. Presentation changes remove Restore declarations/actions and introduce no new changed executable denominator. Package, hosted and native coverage are merged by source location, without double counting or omitted shipped-source maps. Gate artifact: `/private/tmp/ticket36-gate1.json` (exit 0).

The focused-lane whole-source union is 19,011/26,453 (71.87%): Core 94.54%, Presentation 85.55%, transcription runtime 94.24%, app/UI/platform 48.96%. This does not pass or claim ticket 50's whole-source 95% requirement, nor a full native regression run.

Executed commands used the existing cache wrapper, which resets profiles and keeps fresh output/evidence directories:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py package /private/tmp/ticket36-package2 /private/tmp/ticket27-package-cache
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py hosted /private/tmp/ticket36-hosted2 /private/tmp/ticket27-hosted-cache StillmatterHostedTests/MeetingReprocessingHostedTests StillmatterHostedTests/MeetingOutcomeEditingHostedTests StillmatterHostedTests/MeetingsSearchShellControlsHostedTests
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py native /private/tmp/ticket36-native5 /private/tmp/ticket27-native-cache StillmatterUITests/StillmatterFlowsUITests/testManualArchiveRequiresResolvedItemsAndPersistsReadOnlyTabs StillmatterUITests/StillmatterFlowsUITests/testArchivedMeetingDisplaysContentWithBothEditorsDisabled
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 scripts/coverage.py report --reports /private/tmp/ticket36-package2/report.json /private/tmp/ticket36-hosted2/report.json /private/tmp/ticket36-native5/report.json --base 6a2c52151bb587ec90d339586e40a0658e69f2f0 --output /private/tmp/ticket36-gate1.json
```

For a clean-cache reproduction, use `scripts/run-coverage.py package|hosted|native --output <fresh-directory>` and the same `--only-testing` filters, then merge the new reports with the gate command. These lanes require the macOS temporary-file coordination/media/test services used by the isolated fixtures; restricted-sandbox failures are diagnostic, not passing evidence. The excluded DEBUG-only provider fixture changed to remove its obsolete Restore expectation; its reviewed exclusion hash was updated, with no production-source exclusion added.


## Standards

Independent fresh-context review initially identified duplicated lifecycle parsing and the misleading one-way handler name. Shared `MeetingArchiveState` decoding/path construction and `archiveMeeting` address both. Final review reports no remaining documented-standard violations or actionable baseline smells.

## Spec

Independent fresh-context review found that Remove depended on reprocessing eligibility and Retry lacked an archive guard. Removal now has its own eligibility; both Retry UI and service enforce the archive flag. Native tests additionally caught AppKit automatically re-enabling unavailable menu items; explicit menu eligibility is preserved. Final review reports no remaining ticket 36 implementation findings or scope creep.

Review totals: Standards 0; Spec 0. Neither axis has a remaining worst issue. Test results are independent evidence.

## Boundaries

Export remains Release 2.0 ticket 40. Configurable retention/purge and comprehensive owned-media/task deletion remain tickets 37 and 38; this slice preserves the existing folder-to-Trash removal surface and its truthful warning. It does not claim those later capabilities. Existing model-quality and local-analysis constraints are unchanged; no hardware/model capability is inferred from these archive tests.

The user explicitly requested coverage gates for this implementation despite the ticket-local exemption; the shared 95% changed-line gate is therefore enforced. Ticket 50's 95% whole-source gate remains a separate release requirement.

Graphite Focus structural validation and `git diff --check` pass. Presentation validation still reports the pre-existing `TranscriptReaderView.swift:438` visual-literal violation documented by tickets 30–35; this ticket does not change that file.
