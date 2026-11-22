# Testing Stillmatter

Behavior belongs at the lowest layer that can expose the regression. The [migration matrix](test-migration-matrix.md) maps all 65 original UI methods; [the inventory](test-inventory.json) records baseline test declarations and assertion lines. Executed counts and limitations are in [the results](test-refactor-results.md).

## Developer profiles

Run from the repository root with Xcode selected:

| Command | Scope and evidence |
| --- | --- |
| `make test-fast` | Cached Debug SwiftPM; all presentation tests plus canonical artifact edge cases, action review, note/Todo bridge and Todo parsing/persistence. No coverage or XCUITest. |
| `make test-fast FILTER=MeetingArtifactTests` | Explicit SwiftPM regex; replaces the default selection. There is no inferred changed-file dependency selection. |
| `make test-package` | Complete SwiftPM XCTest suite, including service/filesystem/SQLite integration. |
| `make test-hosted` | Complete Release hosted AppKit tests, no GUI automation or coverage. |
| `make test-e2e` | Real `Stillmatter.app` journeys only. Requires an unlocked macOS GUI and Xcode automation permission; uses foreground input. |
| `make test-e2e FILTER=StillmatterFlowsUITests/testE2E02MeetingNotesSurviveRestart` | One journey. Focused evidence cannot stand in for full E2E acceptance. |
| `make test-controls` | Indispensable native keyboard/focus component check against the test-only host. Never real-app E2E evidence. |
| `make test-full BASE=<implementation-base-SHA>` | Complete package, hosted, real-app E2E and hosted-control coverage lanes, followed by changed-line and whole-source 95% gates. |

The equivalent script is `python3 scripts/test.py fast|package|hosted|e2e|controls|full`. `--filter` selects a SwiftPM regex or Xcode class/method; `--output <new-directory>` places logs, durations, commands, toolchain and execution status somewhere explicit. Existing evidence directories are rejected. Xcode also retains `.xcresult` screenshots and diagnostics. A build, empty run, entirely skipped run or failed run is never passing evidence. A missing GUI or denied automation is a prerequisite failure, not an accepted skip.

Fast/package builds reuse SwiftPM's `.build` cache. Ordinary hosted/native runs share `.build/test-derived`, use only the host architecture, disable coverage and run sequentially. Do not run two Xcode profiles concurrently against that cache or compete for foreground input. The previous fresh per-lane roots repeatedly compiled the same modules and both architectures in Release; caches are appropriate for developer feedback, but fresh coverage roots remain intentional evidence isolation. Cold and warm timings must be labeled separately.

`test-full` keeps `scripts/run-coverage.py`, `scripts/coverage.py` and `scripts/coverage-policy.json` authoritative. Every collection uses a fresh root, Release conditions, instrumentation and `-Onone`. Coverage collectors serialize native GUI phases across independent evidence roots with a per-user temporary file lock, and disable parallel native testing. All lanes are attempted even if one fails; missing/failed lanes prevent the final union gate. No old report is substituted. The existing `--incremental-only` mode remains available directly through `coverage.py` for eligible non-UI slices; it does not claim whole-source coverage. See [coverage policy and commands](../archive/2026-11-21/meeting_ai_handoff/coverage.md). Existing whole-source coverage debt does not authorize lowering 95% or excluding shipping code.

## Test pyramid and ownership

Package XCTest owns validation, parsing, state transitions, canonical transformations, search ranking, stable IDs, duplicate prevention, transaction checkpoints, recovery and external-edit conflicts. Tests against disposable files and SQLite are integration tests even when SwiftPM executes them. The project does not need another process simply to call these services.

Hosted XCTest owns actual AppKit views, editor focus/key equivalents, popup callbacks, source warnings, loading/retry/error presentation, async composition and filesystem observation. Interact with actual controls and the real mutation services. Prefer bounded expectations and explicit completion signals. Keep data-loss and idempotency tests independent; a happy path journey cannot replace checkpoint/failure tests.

Real-app XCUITest owns the small set of native wiring and durable user outcomes below. Each test has one objective. Add a journey only when a distinct critical integration boundary cannot be established at a lower layer. UI text/layout checks belong in hosted tests where possible; cosmetic review and physical hardware acceptance remain manual.

| ID | Outcome and final observations |
| --- | --- |
| E2E-01 | Recording → Meeting: explicitly unavailable in the real app without physical permissions/hardware. A named skipped test discloses this gap. `ControlBehaviorRegressionTests.testRecordingControlsStartStopAndPersistLiveNoteWithoutDevices` protects synthetic capture and canonical live-note writes below E2E. |
| E2E-02 | Save Meeting notes, relaunch, reopen; visible notes equal canonical `my-notes.md`; doorway remains separate. |
| E2E-03 | Open a synthetic playable Transcript, change view and click timestamp; correct paused position, source files unchanged. |
| E2E-04 | Approve one proposed personal Action Item; exactly one Todo reference shares its stable ID; relaunch retains source association and no duplicate. |
| E2E-05 | Open canonical Todo from Today, complete it in Tasks; canonical source checkbox changes and Today removes it. |
| E2E-06 | Command-F focuses search, query finds a Meeting, keyboard opens its owning screen, Escape dismisses results while retaining query and navigation. |
| E2E-07 | External Markdown write while Meeting is open refreshes both row and detail; app does not rewrite external bytes. |
| E2E-08 | Archive eligible Meeting, relaunch, explicitly browse archives; content remains readable and editing disabled. Archive has no restore workflow. |
| E2E-09 | Import synthetic audio through the native file picker and reopen the durable ordinary Meeting. Justified extra journey: OS file picker → asynchronous import → canonical workspace boundary. Invalid/cancel/recovery permutations remain below UI. |

## Fixtures and failure diagnosis

Each test owns a UUID temporary root, synthetic audio and isolated settings suite. Never read real workspaces, credentials, recordings, installed models or live calendars/Teams. No network, model acquisition, microphone or screen-recording permission requests are allowed. The native fixture uses the existing validation configuration of the actual app; the control host is a separate test product. Do not add production hooks to bypass user workflows.

Arrange fixtures before app launch wherever possible. Relaunch only for a restart objective or when changing launch-time media configuration. Use stable accessibility identifiers and condition-based waits. Do not synchronize with sleeps or fixed UI delays. Native failures attach screenshot, accessibility tree and a bounded fixture snapshot (Markdown/JSON and file manifest); Xcode result bundles contain process logs. Audio remains synthetic and need not be attached in full.

For real recording acceptance on a disposable manual workspace: grant permissions deliberately, start capture, add a note, stop, inspect the canonical note/Meeting, restart and reopen. Exercise microphone-only and system-audio loss separately, checking retained recovery media and visible warning. Physical-device, OS-permission, Teams/Calendar integration and installed-model quality are not automated acceptance claims. Review typography, resizing and VoiceOver on an unlocked Mac with the existing [manual validation guide](manual-validation.md).

When changing tests, update matrix references and the inventory only when auditing a new baseline; do not overwrite the preserved pre-migration inventory with post-migration names. Run focused replacements first, the complete package/hosted/E2E suites before deletion and after migration, then fresh full coverage evidence. A failed or unavailable replacement is an open validation limitation and must be disclosed, never labeled passed.
