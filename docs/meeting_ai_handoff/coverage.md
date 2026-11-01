# Meeting AI coverage contract

Ticket: [01](../../.scratch/meeting-ai/issues/01-measure-all-shipped-source-and-enforce-incremental-coverage.md). Requirement: R14. This infrastructure measures coverage and fails gates; it does not claim that the existing app meets 95%.

## Shipping source inventory

`scripts/coverage.py inventory` evaluates `swift package describe --type json`, walks the targets reachable from the shipping `Stillmatter` product, and cross-checks their exact Swift files against the matching Xcode synchronized source groups. Unaccounted files under `Sources`, missing targets, shipping-target membership exceptions, and explicit source build-file additions fail for review. Exceptions applying only to the separate hosted-test target do not change shipping membership. New external package dependencies also fail for explicit third-party/generated-source accounting.

The current evaluated inventory contains 113 first-party Swift files across StillmatterCore, StillmatterPresentation, StillmatterTranscriptionRuntime and Stillmatter. Of these, 21 files contain non-shipped validation declarations guarded by `DEBUG` or `STILLMATTER_NATIVE_PROBES`. They are individually listed with reasons and reviewed content hashes in `scripts/coverage-policy.json`; this is an exact list, not a directory glob. An edited excluded file fails inventory until its shipping applicability is reviewed again. The other 92 source files must all appear with executable-line maps in combined coverage. AppKit/SwiftUI and macOS platform adapters are included.

Tests, test-only host/bootstrap code, SwiftPM-generated test runners and SDK sources are outside the shipping product's source inventory. The package currently has no third-party source dependencies. Compiler-synthesized executable lines attributed to a shipping source file remain counted. Release flags exclude debug-only portions within otherwise shipping files without excluding those files.

## Execute coverage lanes

All three lanes use Release compilation conditions and `-Onone` so instrumented code follows the shipping conditional-compilation paths while retaining useful executable-line maps. They use fresh, separate build/profile roots and retain logs, an inventory snapshot, normalized coverage and explicit execution status. Existing output directories are rejected without overwriting their evidence.

```sh
python3 -m unittest discover -s scripts/coverage_tests -v
python3 scripts/run-coverage.py package --output .build/coverage/package
python3 scripts/run-coverage.py hosted --output .build/coverage/hosted
python3 scripts/run-coverage.py native --output .build/coverage/native
```

The package lane runs the complete XCTest suite. The hosted lane uses the separate `StillmatterHostedTests` scheme and `StillmatterHostedTestHost.app`; its test-only entry point avoids the real AppDelegate's services, preferences and permission startup. Tests invoke actual app/platform types with disposable fixtures. The native lane uses the `Stillmatter` scheme and the existing isolated XCUITest app. Every UI test supplies separate workspace, support and recording roots, a separate preference namespace, and synthetic media. The proposal review test seeds the real workspace-scoped operational store before launch rather than enabling debug-only app fixture code.

Native UI tests require an unlocked graphical Mac and Xcode automation permission and use the foreground keyboard/mouse. Package execution, hosted tests and native UI execution are distinct evidence. A successful build, zero executed tests, an entirely skipped run, a failed test run or absent instrumentation cannot produce a passing lane report. `execution.json` records executed/skipped/failed counts; `.xcresult` bundles and test logs remain available for individual assertions. A focused Xcode lane can use repeated `--only-testing` arguments, but must be reported as focused rather than full acceptance.

## Gate each slice and final completion

```sh
python3 scripts/coverage.py report \
  --reports .build/coverage/package/report.json .build/coverage/hosted/report.json .build/coverage/native/report.json \
  --base <slice-start-commit> --output .build/coverage/incremental.json

python3 scripts/coverage.py report \
  --reports .build/coverage/package/report.json .build/coverage/hosted/report.json .build/coverage/native/report.json \
  --base <implementation-base-commit> --whole --output .build/coverage/final.json
```

The incremental command enforces 95% on added/changed executable lines, including committed, staged, unstaged and untracked shipping Swift changes. Removed lines do not inflate the denominator. An unchanged/comment-only Swift slice has no changed executable lines; this passes the incremental gate without claiming whole-app coverage. The final `--whole` option independently enforces 95% over all included first-party executable Swift lines. Reports display each module and the aggregate covered/total counts and unrounded percentage. Exit status 0 means selected gates passed, 1 means a threshold failed, and 2 means coverage evidence is invalid or incomplete.

Reports merge by canonical relative source path and executable line number. Repeated module/file entries and repeated reports contribute each denominator line once; coverage is the logical OR across compatible lanes. Absolute worktree paths are normalized only relative to the collector's explicit source root, never by arbitrary filename suffix matching. Every normalized report carries the entire inventory with source hashes and compilation configuration, the Package.swift hash, shipping Release target/project settings and Swift/Xcode versions. Stale sources, changed exclusions, changed membership, changed shipping flags/toolchains or incompatible configurations fail rather than hiding unmeasured source. Test-only target additions do not alter shipping settings. Sources and build inputs are checked before and after execution/export. Rerun lanes after shipping-source/build changes.

The collector exports LCOV from the package XCTest binary or the instrumented app/host binary (and its debug dylib if present). Core, Presentation and runtime are static libraries linked into the native app/host, so their coverage is merged with package coverage by source location rather than added as new module denominators. Failed native runs retain diagnostics but do not supply a passing coverage report.

For an externally executed compatible lane, the low-level path is `inventory --output before.json`, execute the instrumented tests and export LCOV, then `normalize --inventory before.json --lcov run.lcov --lane package|hosted|native --output report.json` against the same source root. This verifies source hashes, but execution evidence must accompany such a manually imported report; the automated collector is preferred.

## Baseline and executed evidence

Environment: macOS 15.8.1 (24H32), x86_64 Mac, Xcode 26.3 (17C529), Apple Swift 6.2.4. All generated build/test artifacts below use disposable worktree or `/private/tmp` roots.

The historical Debug baseline was reproduced on 2026-11-01: **303 tests, four skipped, zero failures**. This is package-only coverage, matching the earlier audit:

| Module | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| StillmatterCore | 8,148 / 9,153 | 89.02% |
| StillmatterPresentation | 1,499 / 1,802 | 83.19% |
| StillmatterTranscriptionRuntime | 96 / 215 | 44.65% |
| Combined measured package source | 9,743 / 11,170 | 87.22% |
| Stillmatter app/UI/platform | absent | **incomplete** |

This Debug report is diagnostic baseline evidence and is not merged into Release gate reports. Log: `/private/tmp/stillmatter-meeting-ai-01-package.log`; raw coverage: `/private/tmp/stillmatter-meeting-ai-01/.build/debug/codecov/Stillmatter.json`.

The reproducible Release package collector also passed with **303 tests, four skipped, zero failures**. Its executable-line denominator differs because it uses shipping compilation conditions:

| Module | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| StillmatterCore | 6,611 / 7,453 | 88.70% |
| StillmatterPresentation | 1,054 / 1,273 | 82.80% |
| StillmatterTranscriptionRuntime | 81 / 183 | 44.26% |
| Combined measured package source | 7,746 / 8,909 | 86.95% |
| Stillmatter app/UI/platform | 43 files absent | **incomplete** |

Evidence: `/private/tmp/stillmatter-meeting-ai-01-release-package/{execution.json,inventory.json,report.json,coverage.lcov,tests.log}`. Running the report command with this package report alone correctly failed completeness (exit 2), listing all 43 absent app/UI/platform files. Package-only 95% is never accepted as whole-app coverage.

The first full Release native run executed 13 tests: 12 passed and the proposal-review fixture test failed because its seed hook was compiled only in Debug. Evidence remains in `/private/tmp/stillmatter-meeting-ai-01-native/results.xcresult` and `tests.log`; the collector correctly failed and emitted no passing report. The test was changed to seed its actual isolated TasksInbox. The full rerun passed **all 13 tests, zero skipped, zero failures** in 310.64 seconds, including proposal acceptance, editing/relaunch persistence, conflicts, external refresh, navigation, keyboard search, waveform seeking and Transcript pagination. Result: `/private/tmp/stillmatter-meeting-ai-01-native-fixed/results.xcresult`.

The separate Release hosted route passed **two tests, zero skipped, zero failures** against actual app/platform classes. Result: `/private/tmp/stillmatter-meeting-ai-01-hosted/.build/hosted-results-release.xcresult`; build/profile root: the same worktree's `.build/xcode-hosted`; log: `/private/tmp/stillmatter-hosted-tests-release.log`. The hosted scheme/project is delivered with ticket 01's companion hosted-test integration commit.

During infrastructure development, the native test rerun completed successfully but its then-running collector failed at export because universal Mach-O binaries require an explicit LLVM `-arch` flag. The collector now uses the executed architecture from the XCTest result (x86_64 here). This was an export failure, not a test failure; the original failed collector status is retained. Package/native evidence was re-exported using the corrected helpers and complete compatibility metadata. Before re-export, all original source hashes were checked unchanged, Package.swift and shipping Release settings were checked against the original HEAD, and the recorded Swift/Xcode environment was unchanged. Hosted source hashes, Package.swift and shipping settings were checked against the same inventory. No shipping code or compilation flags changed and no tests were represented as rerun. Re-exported evidence, execution counts and verification notes are under `/private/tmp/stillmatter-meeting-ai-01-exported/{package,hosted,native}/`; the hosted/native reports retain their original successful `.xcresult` evidence.

The complete compatible union includes **all 92 required source files** and measures existing whole-source debt as follows:

| Module | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| StillmatterCore | 6,704 / 7,453 | 89.95% |
| StillmatterPresentation | 1,113 / 1,273 | 87.43% |
| StillmatterTranscriptionRuntime | 93 / 183 | 50.82% |
| Stillmatter app/UI/platform | 6,445 / 10,146 | 63.52% |
| All included shipped source | **14,355 / 19,055** | **75.33%** |

The actual incremental command with all three normalized reports and `--base HEAD` exited **0**: this infrastructure slice changes no shipped executable Swift lines, so incremental coverage is **not applicable (0/0)**, not a claim of 100% whole-source coverage. The same command with `--whole` exited **1** at 75.3345578588%, correctly enforcing the final 95% gate. JSON outputs: `/private/tmp/stillmatter-meeting-ai-01-exported/{combined,incremental-gate,whole-gate}.json`. Closing existing debt remains required by tickets 43–46 and 50.

All **30 coverage-tool tests passed**. They exercise duplicate records/reports, omitted app source despite 100% remaining coverage, absent executable maps, reduced-inventory laundering, cross-worktree paths, stale/during-run source changes, compilation/build-input mismatch, unknown source/dependencies, shipping versus hosted membership exceptions, exact 95% boundaries, incremental debt separation, changed Unicode/space paths, skipped/empty/failed test execution and preservation of existing evidence. Python compilation and `git diff --check` also passed.

No hardware/model quality claim follows from this infrastructure. Real capture isolation, permissions, ASR/diarization/voice quality and grounded-model output remain the separate evaluation lanes specified in tickets 02/03 and R14.
