# Ticket 32 — confirmed reprocessing and protected work

Implemented only [ticket 32](../../.scratch/meeting-ai/issues/32-confirm-reprocessing-and-preserve-approved-user-authored-work.md). All declared blockers (10, 23, 25, 26 and 27) were resolved before implementation. The user approved the public service/workspace and native-control test seams and review/coverage baseline `b67475b58fa726f4c7601bd3002dd427398206a6`.

## Behavior

Reprocess requires confirmation and offers Auto, English and Ukrainian. The warning names the generated Transcript, Summary, Decisions, Open Items and pending proposals that will rebuild; it explicitly states that replaced generated edits have no inspectable revision history in Release 1.0. It identifies the protected notes prose/task content, note-authored work, approved identity/content/completion, user tags and confident rejection matches, and discloses the permitted additive-tag exception.

Cancellation submits no mutation and does not retain a changed language choice. Confirmation is bound to the selected Meeting and originating workspace. A second submission cannot race the first. Archived Meetings are rejected by the service and disabled in the UI; queued/running work retains the existing atomic JobStore exclusion. Successful enqueue keeps the control disabled until refreshed; disabled controls explain their reason. Retry continues to resume the original failed stage/settings rather than regenerate with a new configuration. Reprocess failures are visible even on Transcript, where the older status area is hidden.

Regeneration preserves canonical approved/rejected/note-authored work. Matching uses normalized task content, ownership grouping and evidence; saved tags and due/completion tokens do not turn a completed task into a new proposal. Exact confident matches are suppressed, while uncertain matches retain the original and produce a pending `#possible-duplicate` proposal. Duplicate new proposals with identical normalized content, owner grouping and evidence are collapsed. Pending proposals continue to cause Attention. Existing canonical publication retains user tags, approved state and the same Todo identity, replaces generated Decisions/Open Items, and applies ordinary additive note tags without rewriting note content.

Operational snapshots retain prior working bytes before enqueue and survive failed/restarted processing. They are removed only after validated artifact/proposal publication succeeds. They are recovery data, never an inspectable revision-history feature and never automatically replayed over newer user files. Existing durable artifact plans resume individual file writes. New executor checkpoints verify recovery between file publication, each proposal write and final reconciliation. Transcription now captures destination versions before inference, rejecting a result if newer authoritative files appeared while inference ran.

## Verification

Final Release package run: **537 tests, five documented skips, zero failures** (532 passed). The skips are the existing real-echo fixture, real echo-bundle replay, opt-in operational fixture seeder, configured recording replay and separate live synthetic ChatGPT quality lane. Final focused Summary suite: **28 tests, one existing live-quality skip, zero failures**. Final app-hosted confirmation/control scenario: **one test passed**. Final native keyboard/cancellation/error/relaunch scenario: **one test passed**.

Final collector directories:

- `/private/tmp/ticket32-package-final/`
- `/private/tmp/ticket32-hosted-final2/`
- `/private/tmp/ticket32-native-final2/`

Each contains fresh profiles, normalized coverage, execution status and test logs; the native directories retain their `.xcresult` bundles. The focused core run before the final completed-task extension passed 138 tests with two existing skips. The final full run includes all these tests and the completed-task extension.

Tests use temporary workspace, support and media roots with synthetic content, controlled provider responses and generated audio. No real user library or credential namespace is a fixture. Tests cover:

- Archived rejection, atomic competing-run prevention, selected language and unchanged prior working files at enqueue.
- Changed generated IDs, approved/completed/rejected tasks, retained due dates/tags and note-authored task identity; generated Decision replacement and pending duplicate review.
- All seven canonical publication checkpoints and all four combined file/proposal publication boundaries, including recreated services/executors/operational connections, withheld success on interruption and no duplicate Todo.
- Retained operational recovery bytes after failed analysis and cleanup only after successful validated publication.
- Obsolete transcription results and the existing Summary source-change, cancellation, timeout, workspace and late-callback regression suites.
- Hosted confirmation/cancellation, selected language dispatch, repeated submission, originating-workspace expiry and archived/queued disabled controls.
- Native Return/Escape use, warning/language controls, visible failure feedback, unchanged saved notes/Summary and persisted speaker correction after relaunch.

Red-before-green evidence includes the initial archived rejection, changed-ID protection, stale-transcription overwrite, duplicate-new-proposal and completed-task matching failures. Native runs exposed hidden Transcript error feedback; the final control makes that feedback visible. An archive-filter test setup error and a native speaker-label assertion were corrected; failed runs are not passing evidence.

SwiftPM/Xcode builds supply typechecking. `git diff --check` and Graphite structural validation pass. Graphite presentation validation retains the unchanged baseline finding at `TranscriptReaderView.swift:438`, also recorded by ticket 30. The Debug-only fixture language expectation changed to include Auto; its existing coverage-policy hash was updated after verifying its declarations remain under `#if DEBUG`. No source exclusion, threshold or shipping compilation policy was added or weakened.

## Coverage

The final source-compatible package, hosted and native reports pass the normal gate at **122 / 124 = 98.39% changed executable-line coverage**, exit status **0**. Every shipped source is accounted for; compatible coverage merges by source location without double counting.

| Changed module | Covered / executable | Coverage |
| --- | ---: | ---: |
| Core | 84 / 86 | 97.67% |
| App/UI | 38 / 38 | 100% |
| Combined | **122 / 124** | **98.39%** |

Measured whole-source coverage from these lanes is **18,318 / 25,840 = 70.89%**: Core 94.16%, Presentation 83.63%, runtime 94.24%, app/UI/platform 47.60%. These focused native/hosted scenarios do not execute every earlier UI feature. Ticket 50 retains the separate 95% whole-source requirement; this is an incremental ticket-completion claim.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py package \
  /private/tmp/ticket32-package-final /private/tmp/ticket27-package-cache

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py hosted \
  /private/tmp/ticket32-hosted-final2 /private/tmp/ticket27-hosted-cache \
  StillmatterHostedTests/MeetingReprocessingHostedTests

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py native \
  /private/tmp/ticket32-native-final2 /private/tmp/ticket27-native-cache \
  StillmatterUITests/StillmatterFlowsUITests/testReprocessWarningLanguageKeyboardCancellationAndFailurePreserveMeeting

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 scripts/coverage.py report \
  --reports /private/tmp/ticket32-package-final/report.json \
            /private/tmp/ticket32-hosted-final2/report.json \
            /private/tmp/ticket32-native-final2/report.json \
  --base b67475b58fa726f4c7601bd3002dd427398206a6 \
  --output /private/tmp/ticket32-final-gate.json
```

## Standards

Fresh-context review of `git diff b67475b...HEAD` initially identified divergent reprocessing-availability logic. It was consolidated; successful enqueue stays disabled until refresh. Final Standards review: **0 hard violations, 0 baseline smell findings**.

## Spec

The independent Spec reviewer initially identified new-candidate deduplication, active-control availability and file/proposal recovery-test gaps. Each was addressed and re-reviewed. Final Spec review: **0 remaining actionable findings, no scope creep**. Reviews assess implementation and test adequacy; test execution and coverage are separate evidence.

Review totals: Standards **0**, Spec **0**; neither axis has a remaining worst issue.

## Capability limits

No new hardware/model capability is claimed. Fully local grounded analysis remains unsupported under ticket 25; the previously approved ChatGPT/Pi RPC path still requires transfer approval and retains its documented resource limits. Controlled responses establish mutation/recovery behavior, not real model quality. Duplicate matching is conservative text/ownership/evidence matching, not a new semantic model or proof of arbitrary paraphrase equivalence. Existing source-isolation, mixed-language and speaker-quality limits remain with their originating tickets. Inspectable revision history remains Release 2.0 ticket 31. This slice does not claim release-wide lifecycle or whole-source completion.
