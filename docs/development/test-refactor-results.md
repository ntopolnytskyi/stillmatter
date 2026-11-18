# Test refactor execution results

Collection is complete. The refactor is implemented; the existing hosted regression and coverage outcomes below prevent a clean full acceptance.

Baseline HEAD: `355668f38d2dbc5b5fb0b957d13a7e65975353d0` in `ntopolnytskyi/stillmatter`. Baseline runs began November 16; validation resumed November 18, 2026. Hardware: x86_64 Mac, Darwin 24.6.0; resumed OS reports macOS 15.8.3 (24H241). Toolchain remained Apple Swift 6.2.4, Xcode 26.3 (17C529). The original checkout is preserved at `/tmp/stillmatter-refactor-baseline/head`. Both full profiles use identical orchestration with their respective original/refactored test sources. Shipping source, Package.swift, shipping project settings, coverage thresholds and source exclusions are unchanged.

The baseline inventory contains 724 XCTest declarations: 528 core/runtime, 48 presentation, 83 hosted, 48 real-app UI and 17 control-host UI. The refactored inventory contains 680: 529 core/runtime, 48 presentation, 93 hosted, nine real-app UI and one control-host UI. All 65 original UI methods have matrix rows. Ten hosted checks and one unit regression strengthen the lower layers. Nine real-app declarations include eight runnable journeys and one explicit recording gap. Static declarations are separate from executed counts.

## Developer-loop and original-suite measurements

| Scope | Total | Passed | Failed | Skipped | Wall seconds |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline Debug package | 576 | 569 | 1 | 6 | 448.47 |
| Baseline Release hosted (already built) | 83 | 82 | 1 | 0 | 166.07 |
| Baseline real-app UI (already built) | 48 | 43 | 5 | 0 | 2324.69 |
| Baseline control-host UI (already built) | 17 | 17 | 0 | 0 | 217.14 |
| Baseline cached fast | 82 | 82 | 0 | 0 | 14.421 |
| Refactored Debug package | 577 | 571 | 0 | 6 | 183.282 |
| Refactored cached fast | 82 | 82 | 0 | 0 | 13.676 |
| Interim refactored hosted (91 tests, before review additions) | 91 | 90 | 1 | 0 | 288.059 |
| Refactored real-app UI (corrected fixtures) | 9 | 8 | 0 | 1 | 208.69 |

The cached fast profile uses the same explicit 82-test selection before and after (14.421s versus 13.676s). This difference is small and is not a performance claim. Original and refactored UI scopes differ intentionally: the 2,324.69s original UI run exercised 48 methods, while the 208.69s refactored run exercised eight complete journeys plus one disclosed skip. The expanded lower layers protect migrated assertions; these UI timings are not an equivalent-scope full-suite speedup. Baseline Debug package execution overlapped initial builds and failed a timing assertion; the threshold was not relaxed. Cold builds, already-built runs and instrumented coverage runs are labeled separately.

## Fresh full coverage profiles

Both full profiles run complete package, hosted, native and controls lanes against fresh evidence roots using Release compilation conditions, coverage instrumentation and `-Onone`. Coverage-native phases use a shared temporary lock and serial XCUITest to avoid competing foreground input across checkouts. Any lock wait and build contention are included in observed wall time; no controlled-benchmark speedup is claimed.

| Profile / lane | Total | Passed | Failed | Skipped | Wall seconds | Status |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| Baseline fresh full coverage profile / package | 576 | 570 | 0 | 6 | 212.094 | passed |
| Baseline fresh full coverage profile / hosted | 83 | 82 | 1 | 0 | 266.917 | failed |
| Baseline fresh full coverage profile / native | 48 | 45 | 3 | 0 | 1887.323 | failed |
| Baseline fresh full coverage profile / controls | 17 | 17 | 0 | 0 | 285.769 | passed |
| **Baseline fresh full coverage profile total** | — | — | — | — | **2652.501** | **failed** |
| Refactored fresh full coverage profile / package | 577 | 571 | 0 | 6 | 223.612 | passed |
| Refactored fresh full coverage profile / hosted | 93 | 92 | 1 | 0 | 255.284 | failed |
| Refactored fresh full coverage profile / native | 9 | 8 | 0 | 1 | 260.188 | passed |
| Refactored fresh full coverage profile / controls | 1 | 1 | 0 | 0 | 86.657 | passed |
| **Refactored fresh full coverage profile total** | — | — | — | — | **826.156** | **failed** |

Machine-readable counts, durations, exact commands and paths are preserved in [test-refactor-evidence.json](test-refactor-evidence.json). Full `.xcresult` bundles, raw LCOV, source inventories, logs and per-lane status remain under the temporary roots in that file. The runner also records test-source hashes so uncommitted test changes are identifiable.

## Coverage contract and remaining failures

The 95% added/changed executable-line gate and final whole-source gate remain intact. `--incremental-only` passed against the fresh refactored package report with **0 covered / 0 changed shipping executable lines**; this is not a claim of 100% whole-app coverage. Failed lanes never supply a passing coverage report. `test-full` remains failed if any mandatory lane fails, regardless of coverage collected elsewhere. A separate whole-source diagnostic using only fresh passing package/native/controls reports measured **20,994 / 26,790 executable lines (78.36506159014557%)** and exited **1**, correctly failing the unchanged 95% threshold. All required shipping source maps were present; the failed hosted lane was excluded. This is a measured passing-lane union, not full-suite acceptance or an assertion that the failed hosted run supplied coverage. The original full baseline cannot provide a valid whole-source comparison because its native lane failed; historical percentages are not reused.

The unchanged `LiveNotesMeetingVisibilityHostedTests.testRecordingAndProcessingHideMeetingContentThenLaterNotesReadSameFile` fails its processing-status accessibility assertion at line 46 in the baseline and refactored hosted runs. It remains enabled. Product behavior and its assertion were not weakened to conceal the regression. The initial Debug baseline also failed `MeetingManagementTests.testListingMeetingsWithJobHistoryFitsRefreshInterval` (2.420s versus 1.5s during concurrent builds); the later complete refactored Debug suite passed it.

The original 48-method native baseline failed five existing methods: legacy proposal acceptance, external notes rename editor availability, five-tab content presentation, global tag management, and repeated speaker correction. Detailed method names and assertions are retained in `/tmp/stillmatter-refactor-baseline/native-authorized.log` and its `.xcresult`. The fresh full-profile native baseline failed three methods (legacy proposal acceptance, five-tab presentation and repeated speaker correction), so outcomes differed between original UI runs. Their lower-layer destinations remain in the matrix; refactoring does not constitute a product fix for every original UI failure.

The first new E2E run had three fixture/assertion failures: generated task labels include a tag, search honors the current area, and archive requires the human Transcript readiness artifact. The corrections use the stable Todo accessibility identifier, the supported Meeting search scope, and an eligible pre-seeded Meeting. The corrected complete suite passed. The panel migration checks were also iterated to use actual view readiness, canonical invalidation, and the SwiftUI-to-AppKit action boundary. The latest focused checks passed: seven panel/language/source-loss cases, one shell keyboard/search case, and two filesystem recovery/refresh cases. All 35 coverage-tool tests pass; Python compilation and `git diff --check` pass.

Initial sandboxed Xcode builds completed but execution was blocked by `com.apple.testmanagerd.control` restrictions: 419.49s native, 430.31s hosted, 406.22s controls, zero executed tests. Authorized retries produced the evidence above. The first sandboxed SwiftPM attempt failed before execution due to module-cache access (1.97s). A duplicate full-profile invocation launched from the wrong checkout was stopped and explicitly marked invalid at `/tmp/stillmatter-refactor-baseline/full/execution.json`; it is excluded from baseline comparisons. No old coverage reports were substituted.

## Explicit automation gaps

E2E-01 is skipped because the real app has no isolated synthetic capture path; automated runs must not request microphone/system permissions or touch hardware. Synthetic capture, durable notes, source loss and recovery remain independently protected in unit/hosted tests. The six existing package skips concern an installed E5 evaluation, a real AEC fixture, a real recording-bundle replay, an opt-in operational seeder, a configured workspace playback replay, and signed-in/network ChatGPT quality. No live model, hardware, permission, Calendar or Teams quality claim is made. See the manual recording procedure in [testing-strategy.md](testing-strategy.md).

## Review

Standards review identified summary-schema failure handling, unused fixture permutations and a retry assertion that could pass without a new publication. All three were corrected. The coverage lock and serial native configuration were also reviewed; no material remaining standards findings. The lock coordinates coverage collectors; developer profiles still require the documented prohibition on concurrent GUI runs.

Spec review identified missing malformed-Todo recovery assertions and an inaccurate external-Tasks-refresh mapping. Both were replaced with real filesystem/loader/view checks and the matrix was corrected. A follow-up review checked rename/conflict, replaced transcript evidence, overlapping capture ownership and approval recovery mappings and found no additional critical assertion loss. Standards: three findings resolved, zero remaining; Spec: two findings resolved, zero remaining in the reviewed mappings. Execution and acceptance limitations are reported above.

## Reproduce

```sh
make test-fast
make test-package
make test-hosted
make test-e2e
make test-e2e FILTER=StillmatterFlowsUITests/testE2E02MeetingNotesSurviveRestart
make test-controls
make test-full BASE=355668f38d2dbc5b5fb0b957d13a7e65975353d0
python3 -m unittest discover -s scripts/coverage_tests -v
```

For exact output locations, use `python3 scripts/test.py <profile> --output <new-directory>`. Baseline full collection used the original HEAD checkout plus copies of the current orchestration scripts only:

```sh
git clone --shared --no-hardlinks . /tmp/stillmatter-baseline-reproduction
git -C /tmp/stillmatter-baseline-reproduction checkout 355668f38d2dbc5b5fb0b957d13a7e65975353d0
cp scripts/test.py scripts/run-coverage.py /tmp/stillmatter-baseline-reproduction/scripts/
(cd /tmp/stillmatter-baseline-reproduction && python3 scripts/test.py full --base 355668f38d2dbc5b5fb0b957d13a7e65975353d0 --output /tmp/stillmatter-baseline-full-reproduction)
```

GUI profiles require an unlocked Mac and Xcode automation permission. [Testing strategy](testing-strategy.md) defines ownership and fixture rules; [migration matrix](test-migration-matrix.md) accounts for every original UI test.
