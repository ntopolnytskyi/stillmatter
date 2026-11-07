# 12: Start capture immediately while previous work finalizes or processes

**What to build:** Separate capture availability from expensive previous-session finalization. UI: Record becomes usable once the preceding source session has safely stopped; the next capture starts without waiting for echo/analysis. Tests hold finalization/processing callbacks, start B, and prove A/B audio/notes/identity remain isolated across failures/restarts.

**Blocked by:** [02: Verify Teams-only scope and explicit manual system-audio scope](02-verify-teams-zoom-and-google-meet-source-isolation.md); [09: Run one durable staged Meeting workflow through reusable Jobs](09-run-one-durable-staged-meeting-workflow-through-reusable-jobs.md)

**Status:** claimed

**Type:** task

**Requirements:** R2, R7, R14.

## Context and scope

Use the [approved spec](../spec.md), [domain glossary](../../../CONTEXT.md), and [shared layout vocabulary](../../../docs/meeting_ai_handoff/layout.md). The approved graph defines this slice; preserve behavior outside it. Resolve prerequisite research from the linked blockers before claiming capability.

## User experience

- Entry: Recording after Stop and while older Meetings are Processing.
- Actions: Record starts the next capture once the preceding source session safely stopped, without waiting for analysis/echo.
- States: show new capture state and retained prior-session processing independently; do not report the old failure as B's failure.
- Layout: keep capture controls/source/elapsed time in Recording; older Meeting stages remain in their status surfaces.
- Persistence: notes and retained audio always belong to their original session after navigation/relaunch.

## Acceptance criteria

- [ ] Release the previous capture session safely before its expensive finalization/echo/processing finishes so the next capture can begin.
- [ ] Carry explicit session/generation ownership through finalization and durable handoff; stale A callbacks cannot mutate B.
- [ ] Retain all original evidence and independently saved notes if bundle/sidecar/enqueue work fails.
- [ ] Keep background A processing running while B captures rather than pausing the queue.

## Required tests

**UI test execution:** Run UI tests only when this implementation changes UI code. If UI code is unchanged, do not run UI tests; record “UI tests skipped: no UI code changed” in the completion evidence. This condition applies to all UI/native interaction test requirements in this ticket. Continue running relevant non-UI tests.

- [ ] Hold A finalization and B start with controlled adapters; assert B captures before A enrichment completes.
- [ ] Deliver A callbacks after B starts/stops, including failure and repeated completion; assert isolated files/session state.
- [ ] Restart at capture-to-finalization/Job boundaries and prove recoverable evidence and exactly one processing intent per session.

- [ ] Native interaction tests cover the changed controls, applicable shortcuts/focus, resulting persisted state, and the relevant empty/disabled/error case. Use semantic test identifiers and observable waits; source-text checks or screenshots without assertions do not substitute for behavior.

## Completion evidence

- [ ] Record executed tests, results, and any separate hardware/model evaluation evidence; never claim a fake provider proves real model quality or source isolation.
- [ ] Test all feature behavior introduced here in this slice. Production changes use the 95% new/changed executable-line gate established by ticket 01; report existing debt separately. Final ticket 50 requires at least 95% across all shipped first-party Swift source, including app/UI/platform code.
- [ ] Verify migration/restart and workspace/media/support isolation where affected; do not use a real user library or secret namespace as a fixture.

## Comments

Published from the user-approved 50-ticket breakdown. The ready-for-agent label means specified; execution still waits for every declared blocker to complete. Implementation has not begun.

Implementation work is in the renewed worktree on branch `codex/meeting-ai-12`, commits `0756433`, `76b0e0d`, and `9f8e352`, based on ticket 11 commit `f890bcb`. Current evidence:

- Package coverage lane: 386 tests, 4 skipped, 0 failed. Added legacy recorder compatibility-default tests.
- Hosted coverage lane: 24 tests, 0 skipped, 0 failed. Added no-device mic/system recorder release and export error-path coverage.
- Native shared-controls UI suite: 7 tests, 0 skipped, 0 failed. The new overlap interaction starts B while A's bundle finalizer is held, checks the independent status, and verifies A/B notes remain in their own Meetings.
- Full native app UI lane had an unrelated failure in `testMalformedNotesShowAffectedFileAndKeepDraftUntilExplicitReloadAfterRepair` (timeout waiting for repaired notes); its search-navigation failure passed when rerun alone.
- Fresh incremental report from package + refreshed hosted + focused native reports: 507/530 changed executable lines (95.66%), passing the required 95% gate; StillmatterCore 456/467 (97.64%), app/platform 51/63 (80.95%). Whole-source coverage is 15,988/20,906 (76.48%), existing debt outside this ticket's incremental gate.
- Source release, encode failure, restart recovery, system-track failure handoff, stale A failure isolation, exactly-once processing-job behavior, and legacy compatibility defaults have targeted coverage. The prior-finalization failure row is asserted in the hosted AppKit control test; a dedicated native UI failure-row interaction remains unverified. A later isolated instrumented rerun of the overlap UI test timed out at app activation while the host was backgrounded; the earlier full 7-test Controls UI suite remains green.
- Ticket 02's investigation still does not establish actual-call Teams/Zoom/Meet source isolation. No isolated-source capability is claimed or substituted.

### 2026-11-04 — Late prior-finalization failure UI fix and verification

Fixed a ticket-scope UI defect found while verifying the prior-finalization failure row: after A's background finalizer failed, the view said “Capture complete” and described the previous Meeting as successfully finalized. It now says the next capture is ready, identifies the retained failure as belonging to A, and does not show A's late failure as B's capture error. The prior failure row has a semantic accessibility identifier and wraps its title.

Validation:

- Package lane: **386 tests, 4 skipped, 0 failed**.
- Hosted lane: **24 tests, 0 skipped, 0 failed**.
- Native shared Controls UI suite: **8 tests, 0 skipped, 0 failed**, run with Xcode parallel testing disabled. Includes holding A's finalizer, starting B, then failing A and asserting B remains live while A's failure is visible and separately attributed.
- Focused native coverage lane: **1 test, 0 skipped, 0 failed**.
- Incremental coverage: **524/551 changed executable lines (95.10%)**, passing the 95% gate. StillmatterCore 456/467 (97.64%); app/platform 68/84 (80.95%). Whole-source coverage is 16,007/20,925 (76.50%), existing debt outside the incremental gate.
- `git diff --check` passed.

The earlier native-app full-suite timeout in malformed-notes recovery was not reproduced or changed by this ticket-scope work; the dedicated Controls UI suite is green. Ticket 02 is marked resolved as an investigation, but its actual-call Teams/Zoom/Meet sample, leakage, reconnect/continuity, and inference-load measurements remain unrun. Production still captures app-wide audio except Stillmatter, and Meet-tab-only capture remains unsupported by the current backend. No source-isolated capability is claimed. Evidence is under `/private/tmp/stillmatter-meeting-ai-12-*`.

Follow-up verification after review found one more stale-callback race: A's finalizer could arrive while B had independently failed its source release, and the UI callback previously used only the service's current `.failed` state. The callback now captures A's Meeting path and ignores the result if a different Meeting is current. A native UI regression holds A's finalizer, causes B's source release to fail, then releases A and verifies B's error remains unchanged.

Final-source evidence:

- Native shared Controls UI suite: **9/9 passed**, 0 skipped. The three ticket-specific capture overlap/error cases passed in the full suite.
- Package: **386 tests, 4 skipped, 0 failed**. Hosted: **24 tests, 0 skipped, 0 failed**.
- Native coverage map: isolated `testSearchKeyboardNavigationAndEscapePreserveQuery`, **1/1 passed**. A separate focused `testPlayableRecordingHasFullWidthSeekControl` attempt failed its seek-position assertion in this refresh (it passed in an earlier run); this unrelated playback assertion was not used for the final coverage aggregation.
- Final incremental report: **526/553 changed executable lines (95.12%)**, passing the 95% gate. StillmatterCore 456/467 (97.64%); app/platform 70/86 (81.40%). Whole-source coverage for this selected lane set is 15,393/20,927 (73.56%), existing debt outside the ticket gate.
- `git diff --check` passed.

Ticket 12's implemented UI and behavior are verified, but the ticket remains incomplete because prerequisite 02 has not established actual-call Teams/Zoom/Meet source isolation or audio continuity under inference. The failed focused playback seek assertion noted above is outside this ticket's capture controls. Evidence bundles/reports are under `/private/tmp/stillmatter-meeting-ai-12-*`.

The final UI correction and regression coverage are committed on `codex/meeting-ai-12` as `73f15d9` (`Keep prior capture failures separate from next capture`). That implementation snapshot was clean at `73f15d9`. Subsequent uncommitted follow-up in this same worktree adds explicit Teams-only versus manual all-system Zoom/Meet selection and labels, protects both macOS recorders against stale A samples/errors entering B, and refuses another capture if source stop cannot be confirmed. On the current uncommitted follow-up: `swift build` and focused core/source/runtime tests passed; all **10 Controls UI tests passed**, including manual scope disclosure and existing A/B cases. Full debug `swift test` ran 389 tests but failed the unrelated timing-sensitive `MeetingSummaryTests.testProductionSummaryExecutorTimeoutKillsWorkerBeforeRetryAndQueueAdvances` under suite load (its focused rerun passed after cleaning up an earlier leftover test app process). Fresh Release coverage collectors passed package, hosted and focused native lanes, but the incremental gate over the complete ticket-12 diff against `f890bcb` is now **540/615 = 87.80%**, below 95%; new platform capture paths are not exercised by no-device tests. Full source gate output: `.build/coverage/agent-ticket12-incremental.json`; new-slice gate against `73f15d9`: 83/133 = 62.41%. No actual-call scope, sample continuity or inference-load evidence has been added. Keep ticket 12 open until these gates pass; do not carry forward the former 95.12% report as if it covers the new source changes.

### Completion blockers (current checkout)

The read-only native preflight on macOS 15.8.1 found Teams installed and Screen Recording/Microphone authorization granted, but **did not start capture**. A real-call synthetic-tone run still requires a human to arrange a Teams call and permission/scope verification; preflight is not call evidence. The pending Teams/Zoom/Meet source-selection changes introduce platform executable paths for which device-free coverage cannot establish behavior; the 95% incremental gate remains red (87.80%). Ticket 02's original API research was complete, but its revised actual-call criteria are now marked `ready-for-human`, not `resolved`. Do not resolve ticket 12 or ship a Teams isolation claim on the basis of the simulated A/B lifecycle tests.

2026-11-07: A user-authorized synthetic Teams call was captured via the separately signed local probe. The user reports Teams audio audible and no unrelated local tone audible; two private 20.073-second tracks and non-audio diagnostic JSON are listed under ticket 02. This narrows the actual-call scope uncertainty but does **not** test A/B overlap during real inference, start/stop continuity, reconnect, or the current 95% incremental coverage gate. Ticket 12 remains claimed/open. No recording bytes were copied into the repo.

### 2026-11-07 — Follow-up verification (ticket still open)

- Current uncommitted source was not changed in this pass. `swift test` passed **390 tests, 4 skipped, 0 failed**. The timing-sensitive summary worker test passed a focused build/run and five additional Debug repetitions; three focused Release-instrumented repetitions passed too. This does **not** make the Release package lane green: two fresh complete instrumented runs each executed 390 tests, 4 skipped, and failed three assertions in that same summary test. Job B failed rather than succeeded; the fake worker count was 2 rather than 3; the summary artifact was absent. Logs: `.build/coverage/ticket12-session-package/tests.log` and `.build/coverage/ticket12-session-package-retry/tests.log`. The collector correctly emitted no passing report. Do not relax the worker-kill/queue-advance assertions to hide this failure. Investigate under suite load before claiming a clean Release lane.
- `scripts/coverage.py report --base f890bcb` rejected the older package/hosted/native reports with exit 2 (**incompatible source hashes/build inputs**). The earlier 540/615 (87.80%) figure is historical, not a current passing gate. A fresh coverage union cannot pass while the complete package collector is red; the additional platform changes still need executable-path coverage. A changed-line audit of the earlier report maps found 44 unexecuted changed executable lines in `MacSystemAudioTrackRecorder.swift` and 11 in `MacMicTrackRecorder.swift`; no-device entry-point coverage cannot demonstrate actual stream callbacks. Do not exclude these lines or narrow the base to force 95%.
- Next consented hardware experiment, **not yet run**: use a human-approved, locally signed app with disposable, synthetic-only Teams call audio. Start A, record a timestamped distinct A signal and note, stop A, hold A's actual finalize/processing work under a controlled real inference load, then start B immediately with a distinct B signal and note. Record stream start/stop callbacks, monotonic frame counts/audio-clock spans, per-session IDs and durable file/Job paths; after both finish and after relaunch, assert A/B own distinct audio/notes and exactly one processing intent each, with no missing B frames or A frames/callbacks crossing into B. Compare expected signal windows to retained frames and log observed start/stop gaps and processing overlap. Repeat with a controlled permission/Teams disappearance/reconnect case in ticket 02. No probe may capture without fresh explicit human consent; keep raw audio private and ephemeral. This design is not continuity evidence.

### 2026-11-07 — Summary-worker test hardening and fresh gate

The summary test's 150 ms execution limit was too sensitive for process startup in a full instrumented suite: two initial fresh Release collectors failed with B marked failed and only two worker launches, while repeated focused runs passed. The test now gives a hung worker a one-second stage limit and twelve seconds for the two deliberate timeout/kill cycles plus B, **without removing any original status, attempt-count, process-count or artifact assertions**. It additionally checks A's persisted failure reason is a timeout and reports B's persisted failure reason on failure. This is a test-budget change only; no production scheduler timeout was changed. The exact cause of the earlier B failure remains unconfirmed because the earlier failure reason was not recorded; do not claim a production race was fixed.

Fresh results after the change: full Debug `swift test` **390 tests, 4 skipped, 0 failed**; three fresh full Release package collectors **390 tests, 4 skipped, 0 failed** each; Release hosted **24/24 passed**; focused native map **1/1 passed**; Debug Controls UI suite **10/10 passed**; coverage-tool tests **35 passed**; `git diff --check` passed. Logs/reports: `.build/coverage/ticket12-summary-robust-package*/`, `.build/coverage/ticket12-policy-{package,hosted,native-map}/`, `.build/ticket12-controls-results.xcresult`. An attempted Controls test through the main Stillmatter scheme could not run because that target belongs to its own scheme; the subsequent Controls-scheme run passed.

The fully guarded disposable `STILLMATTER_CAPTURE_PROBE` CLI has been added as an exact hashed non-shipping validation-source exclusion in `scripts/coverage-policy.json`; no shipping platform recorder path was excluded. Fresh compatible package + hosted + focused-native coverage report `.build/coverage/ticket12-policy-incremental.json` now runs but **fails the unchanged 95% incremental threshold: 540/615 = 87.80%** against `f890bcb` (whole shipped source 15,466/21,025 = 73.56%, existing debt). The platform stream/sample callback paths and real A→B inference continuity are still unverified. Ticket 12 remains claimed/open; ticket 02 remains ready-for-human.

### 2026-11-07 — Public capture/recovery seam coverage follow-up

Six new package behavior tests exercise stale A title-review delivery during B, an accepted B rename followed by a retained note, a stopped-but-failed A finalizer during runtime reconfiguration, the non-split system recorder's synchronous release, restart recovery preserving its single Job and live note, and invalid Meeting Markdown on stop retaining the original bytes and microphone recovery while B remains startable. The existing unconfirmed-stop test also asserts the user-facing stop warning. These are synthetic/public service and coordinator tests, **not** real-device source-scope or continuity tests.

Fresh complete Release package collector `.build/coverage/ticket12-seam1-expanded-package/` passed **396 tests, 4 skipped, 0 failed**. With the unchanged compatible hosted (24 passed) and focused-native (1 passed) reports, `.build/coverage/ticket12-seam1-expanded-incremental.json` is **546/615 = 88.78%** against `f890bcb`, still below 95%. Core improved from 429/441 to 435/441; the app/platform remains 111/174. `git diff --check` passed. The six remaining uncovered Core changed lines are enqueue-exception branches in MeetingCapture (3) and RecordingRecoveryService (3); a routine idempotent restart takes the existing-Job branch before these exceptions. Avoid contrived faults solely to hit them. Real platform callbacks (55 uncovered changed lines across both recorders at that snapshot) and actual-call inference continuity still block completion.

### 2026-11-07 — Synthetic recorder and Release Controls UI coverage

The native Controls UI scheme now has its own **Release instrumented** collector route (`scripts/run-coverage.py native --controls`), without changing the normal main-app native route. The existing ten Controls tests pass under this lane and exercise all seven previously uncovered changed `CaptureRecordingView` executable lines (source popup action, current-stop error branch, prior-failure recording detail). The separate main-app native map remains necessary for `App/main.swift`.

The microphone recorder accepts an external AVAudioEngine/input node at its existing recorder interface. A hosted test runs an offline-rendered `AVAudioSourceNode` through the **real** AVAudioEngine tap and recovery-file writer, then checks distinct A/B PCM samples. No physical microphone is opened. The system recorder now has an internal ScreenCaptureKit stream-creating seam: its shipping adapter still does real Teams-application vs explicit all-system filtering, while hosted synthetic streams exercise the recorder's real recovery writer, session generation isolation, late A frames/errors during B, start/stop failure, stop-unconfirmed refusal of B, and mic-independent scope propagation. An OS stop failure now retains stream ownership instead of discarding it and incorrectly offering B. Fake streams do **not** validate ScreenCaptureKit's actual filters, OS permissions, reconnection, or real inference-load continuity.

Fresh lanes for this revision: Release package **396 tests, 4 skipped, 0 failures**; hosted **29/29 passed**; Release Controls UI **10/10 passed**; focused main-app native map **1/1 passed**; Debug package **396 tests, 4 skipped, 0 failures**; coverage-tool tests **35 passed**; `git diff --check` passed. Compatible changed-line report `.build/coverage/ticket12-system-errors-incremental.json` against `f890bcb` is **628/704 = 89.20%, gate FAIL** (StillmatterCore 435/441, app/platform 193/263). The new shipping ScreenCaptureKit adapter increases the denominator from 615 to 704; do not compare absolute numerators as if the source were unchanged. **76 changed executable lines remain uncovered:** 65 ScreenCaptureKit adapter/callback paths, four macOS microphone start/error paths, six rare enqueue exception branches in Core, and one AppDelegate line. A no-device fake cannot prove the 65 OS adapter paths, and new actual capture requires explicit fresh human consent. Ticket 12 remains claimed/open and ticket 02 remains ready-for-human.

### 2026-11-07 — Failed-start ownership review (ticket still open)

A focused synthetic stream regression reproduced a safety gap: a failed ScreenCaptureKit start callback caused the backend to drop its stream even if the OS had not confirmed a stop, allowing B to start. The backend now attempts to stop after a failed start and only releases stream ownership when that stop succeeds; an unconfirmed stop blocks further system-audio capture on this backend until it can be retried or the process is restarted. The test covers both confirmed cleanup/retry and failed cleanup/refusal of B. Focused hosted recorder/control class **11/11 passed**, complete Debug hosted **30/30 passed**, and `git diff --check` passed. No audio devices or calls were accessed. Earlier coverage reports are stale after this shipping-source change; the 95% gate has **not** been rerun or passed. Real ScreenCaptureKit permission/filter behavior and actual A→B inference continuity remain unverified; fresh human consent is still required for any capture.

### Human verification — real-call A→B continuity

The user reports having verified real-call A→B continuity and that it works as expected. Treat this as user-reported acceptance evidence for ticket 12; do not revisit or request another real-call A→B continuity check within this ticket. No raw recording or measurement log was supplied with this report, so it is not executable-line coverage, inference-load measurement, or independent source-isolation evidence. Remaining ticket-12 work should focus on the other open criteria and the coverage gate.

### 2026-11-07 — Shipping recorder code review, device-free verification

Reviewed the production `ScreenCaptureKitAudioStreamFactory`, delegate/stream wrapper, `MacSystemAudioTrackRecorder`, `MacMicTrackRecorder`, coordinator failure paths, and hosted synthetic tests. Teams scope selects only Teams bundle IDs and throws rather than falling back if absent; manual Zoom/Meet selects all-system audio excluding this process. Sample writes are serialized on the SCStream output queue, scoped to a generation, and flushed before a successful stop releases the stream; failed stop retains ownership. Mic tap callbacks likewise check the generation under a lock. The previous failed-start ownership fix has an exercised success/failure cleanup regression.

`swift build -c release` passed (only unrelated existing ShellViewController unused-value warnings); full Debug hosted suite **30/30 passed**; `git diff --check` passed. No device capture or permission prompts were performed. This confirms compile-time shipping paths and device-free lifecycle behavior, **not** actual ScreenCaptureKit filter/permission behavior or executable coverage of its OS adapter. One operational limitation remains: after both start and cleanup-stop fail, the backend safely refuses B system audio, but the coordinator has already marked the track failed and cannot retry that stop via its public interface; recovery currently requires restarting the capture backend/process. Also, the adapter's synchronous waits on ScreenCaptureKit callbacks have no timeout; OS callback hangs could block the calling thread. Do not treat these as proven field failures; add explicit bounded/failure recovery handling before claiming robust permission/reconnect behavior. The 95% changed-line gate must be collected afresh after the source change. UI tests skipped in this review: no UI code changed here. The user's real-call A→B continuity acceptance is not being reopened.

### 2026-11-07 — Requested four-part evidence run

Executed the existing held-finalizer A/B, late-callback/error, stopped-source refusal, retained-note/recovery and reused-Job tests as part of the complete Release package and hosted suites; the native Controls suite also exercised A/B overlap and separate failure attribution. Results: package **396 total, 4 skipped, 0 failed**; hosted **30/30 passed**; Controls native **10/10 passed**; focused main-app native **1/1 passed**. The main-app native collector was first invoked twice with incorrect test class names and correctly rejected both zero-test runs; the corrected `StillmatterUITests/StillmatterFlowsUITests/testSearchKeyboardNavigationAndEscapePreserveQuery` invocation passed. All successful runs used fresh separate profile roots. Evidence: `.build/coverage/ticket12-request-{package,hosted,controls,main-native-correct}-20261107/{execution.json,report.json,tests.log}`. These are synthetic tests; they do not reopen the user's accepted real-call A→B verification or establish inference-load/source-isolation measurements.

Fresh compatible `--base f890bcb` report: `.build/coverage/ticket12-request-incremental-20261107.json`, **632/708 = 89.27% changed executable lines, gate FAIL** (Core 435/441; app/platform 197/267). Whole source **16,282/21,065 = 77.29%**, existing separate debt. `git diff --check` passed. Do not mark ticket complete: reaching 95% with this denominator requires at least 673 covered changed lines, 41 more than this run. Existing restart tests prove specific post-release and Job-reuse paths, not every crash boundary; no actual crash-at-each-boundary matrix was run. Shipping ScreenCaptureKit adapter lines remain largely unexecuted by device-free lanes. No capture was started.

### Product-owner acceptance exceptions for ticket 12

The owner explicitly waives a kill-and-relaunch crash-boundary evidence matrix for ticket 12 and accepts the current **632/708 (89.27%)** changed-line coverage level despite the unchanged 95% gate reporting **FAIL**. These are ticket-specific acceptance exceptions, recorded separately in [ticket-12-acceptance-exceptions.md](../../../docs/meeting_ai_handoff/ticket-12-acceptance-exceptions.md); do not claim the gate passed or apply this waiver to another ticket. Existing synthetic recovery tests cover only their exercised paths. If a crash-boundary failure emerges later, track and fix it as a bug. The owner's real-call A→B continuity result remains accepted; do not request another run in ticket 12. ScreenCaptureKit/permission claims and ticket 02 remain separate, unresolved questions.
