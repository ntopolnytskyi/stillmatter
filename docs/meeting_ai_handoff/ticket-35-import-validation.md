# Ticket 35: audio/video import validation

Validated 2026-11-16 on macOS 15.8.3, x86_64. Scope is ticket 35, after resolved prerequisites 08, 09 and 19. Review baseline: `4a67557567802ddda54668f42c3d4e46c16d7421`.

## Result

Meetings has an Import action using the native supported-file picker. Preparation shows shared native progress and meaningful status, supports cancellation, and reports invalid/unreadable media. It preserves the original and prepares an app-owned audio derivative before publishing the ordinary Meeting doorway and durable staged workflow. A successful import appears in the existing Listing and five-tab Detail Workspace.

Preparation uses unique IDs and workspace-specific media namespaces. A persisted intent allows restart after preparation, doorway publication or enqueue; the stable capture-processing Job ID prevents duplicate workflows. Interrupted unfinished copies are cleaned safely. Recovery skips active preparations and reports damaged journals without preventing independent imports from recovering. Successful enqueue wakes the captured workspace's scheduler. Occurrence time comes from file creation metadata when consistent with modification time, otherwise modification time; the doorway records that provenance instead of guessing from a filename.

Imported speech uses an explicit imported-audio Transcript track with a neutral “Meeting audio” speaker label. It does not assert that the recording belongs to Me. The existing audio reader accepts the imported bundle, and source navigation uses its original timing. No separate imported task, approval or workspace model was added.

## Feature and UI evidence

- Eight package import tests exercise actual generated WAV and H264-video/audio MOV preparation, original and app-owned copy bytes, independent import identities, corrupt/unsupported input, cancellation, deterministic dates, concurrent preparations, and recovery while another preparation is active.
- Faults after a copy write, after export begins, after durable preparation, after doorway publication and after enqueue are followed by new vault/JobStore connections and repeated recovery. Assertions distinguish cleaned unfinished operations from exactly one prepared Meeting/workflow.
- A damaged prepared import cannot prevent another from recovering. Controlled Transcript generation verifies neutral source identity and seekable evidence; removal of the ordinary Meeting leaves the original unchanged.
- Hosted AppKit controls verify unavailable configuration, visible preparation/disabled controls, duplicate-start rejection, failure recovery, cancellation, success and preservation of unrelated editing focus.
- Main-app native interaction verifies picker Escape cancellation and keyboard file navigation, invalid-file feedback, successful preparation, unchanged source bytes, selection of the actual imported Listing row, all five tabs, Transcript selection and ordinary unavailable-content state without configured models, Option-Command-Left navigation to My Notes, damaged-journal startup warning, Return dismissal and exactly one persisted row after relaunch.

All fixtures use disposable workspace, media, operational-store, preferences and support locations. No real user library or credentials are fixtures. SwiftPM and Xcode builds perform typechecking.

## Executed verification

| Lane | Result | Evidence |
| --- | --- | --- |
| Full Release package | 555 tests, 5 existing opt-in skips, zero failures | `/private/tmp/ticket35-package1/{execution.json,tests.log,report.json}` |
| Focused Release hosted | 1 test, zero skips/failures | `/private/tmp/ticket35-hosted3/{execution.json,tests.log,results.xcresult,report.json}` |
| Focused Release main-app native | 1 test, zero skips/failures | `/private/tmp/ticket35-native5/{execution.json,tests.log,results.xcresult,report.json}` |

The five package skips are the existing real echo fixture, external Recording Bundle replay, operational fixture seeder, configured-workspace playback replay and live ChatGPT quality lane. No ticket 35 test is skipped. The focused import suite separately passed 8/8 before the full suite.

The standard complete-source-map report exits **0** at **318/330 = 96.36% changed executable-line coverage**, exceeding the 95% gate. Every shipped source has a source map; compatible lanes merge by source location without double counting. No threshold, exclusion, shipping flag or inventory policy changed.

| Changed module | Covered / executable | Coverage |
| --- | ---: | ---: |
| Core | 192 / 198 | 96.97% |
| App/UI/platform | 126 / 132 | 95.45% |
| Combined | **318 / 330** | **96.36%** |

Existing whole-source debt in this focused-lane union is **18,332/26,433 = 69.35%**: Core 94.49%, Presentation 80.82%, runtime 94.24%, app/UI/platform 44.49%. This does not pass or claim ticket 50's separate whole-source 95% requirement. This single-ticket run does not claim a full native regression run.

Commands used the existing temporary cache wrapper around the repository collector; it preserves fresh profiles and inventory validation:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py package /private/tmp/ticket35-package1 /private/tmp/ticket27-package-cache
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py hosted /private/tmp/ticket35-hosted3 /private/tmp/ticket27-hosted-cache StillmatterHostedTests/MeetingImportHostedTests
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py native /private/tmp/ticket35-native5 /private/tmp/ticket27-native-cache StillmatterUITests/StillmatterFlowsUITests/testImportPickerCancelInvalidAudioAndPersistedOrdinaryMeeting
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 scripts/coverage.py report --reports /private/tmp/ticket35-package1/report.json /private/tmp/ticket35-hosted3/report.json /private/tmp/ticket35-native5/report.json --base 4a67557567802ddda54668f42c3d4e46c16d7421 --output /private/tmp/ticket35-gate1.json
```

Without the cache wrapper, use `scripts/run-coverage.py package|hosted|native --output <fresh-directory>` and the same Xcode `--only-testing` filters. These real media/native lanes need access to macOS media and test services. Restricted-sandbox audio export failed explicitly; the authorized service-enabled lanes above provide the final evidence.

Structural Graphite Focus validation and `git diff --check` pass. Presentation validation reports the unchanged baseline `TranscriptReaderView.swift:438` visual-literal violation already recorded by tickets 30–34; ticket 35 does not edit that file.

Earlier diagnostic runs are superseded. They exposed stale URL resource-date caching, active-folder path normalization, late cancellation and focus behavior; these were corrected and covered behaviorally. Native test corrections use the observed open-panel Window and tabs RadioGroup, scope selection to the actual Listing row, and assert the ordinary empty Transcript while models are unavailable. One initially passing hosted test was correctly rejected by the collector because source changed during its execution; only the compatible final lanes above contribute to the gate.

## Standards

Independent fresh-context review initially found focus stealing on background failure. Completion now restores focus only if the disappearing Cancel control owned it; a hosted native assertion preserves unrelated editor focus. Subsequent review found no remaining actionable documented-standard breaches or baseline smells.

## Spec

Independent fresh-context review initially found a late-cancellation publication gap and insufficient concurrent/reopened-store interruption tests. Cancellation is now checked immediately before the durable intent commits; copy/export faults occur during actual work; recovery uses new store connections; concurrent imports have distinct audio fixtures and controlled overlap. Subsequent review found no remaining confirmed implementation findings or scope creep. Execution and coverage results are reported separately above.

Review totals: Standards 0; Spec 0. Neither axis has a remaining worst issue.

## Capability boundaries

The picker supports WAV, AIFF/AIF, CAF, MP3, AAC, M4A, MP4 and MOV containers with a readable audio track supported by the local AVFoundation decoder. A supported extension alone cannot make a corrupt, protected, missing-audio or unsupported-codec file usable; failures are explicit and preserve other work. Actual local WAV and video/audio MOV preparation was tested. Controlled Transcript output establishes workflow and navigation behavior, not real ASR/diarization quality or grounded analysis quality.

Prior ticket 19/20 model-quality constraints and ticket 25's unsupported local grounded-analysis capability remain unchanged. Imports use Auto by default and the existing ordinary reprocessing/lifecycle mechanisms. Later archive, retention and complete app-owned-media deletion behavior remains in tickets 36–38. The original import is outside the owned media folder and is preserved by Meeting removal. No remote import preparation, broader capture scope or quality claim was introduced.
