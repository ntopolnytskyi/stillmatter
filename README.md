# Stillmatter

Stillmatter is a local-first native macOS work log/worktable. This repository currently contains the bootstrap native shell.

## License

Stillmatter includes a modified echo-cancellation port and is intended for distribution under the GNU General Public License version 3. **The repository currently lacks `LICENSE` and `THIRD_PARTY_NOTICES.md`.** Local development builds warn and omit them; do not distribute an app bundle until the correct license text and third-party attributions have been restored and reviewed. `REQUIRE_LEGAL_FILES=1 ./scripts/build-app.sh` enforces this before packaging.

## Build a launchable app bundle

```sh
./scripts/build-app.sh
open .build/Stillmatter.app
```

**Existing-installation note:** This brand change also changes the bundle identifier, settings keys, Application Support location, workspace metadata keys, and environment-variable prefix. Existing settings and workspace files are not migrated automatically. Back up your workspace and application data before replacing a prior installation; a data migration is needed to retain its configured state and recognize previously generated metadata.

The shell includes:

- native AppKit main window
- Today worktable with recording/job status, categorized Inbox, Daily Brief entry, top canonical Queue items, upcoming-meeting context, and active activities
- focus-triggered Daily Brief generation from configurable Calendar sources with stable planning sections and no Todo Item mutations
- scheduled editable Weekly Report drafts with working-day deferral, meeting-safe Accept / Remind prompts, and transactional acceptance that moves done/canceled todos into the report
- native source-list navigation grouped into Work, Tools, and System for Today, Meetings, Tasks, Activities, Reports, Ask AI, and Settings
- Meetings capture UI with explicit lifecycle state, elapsed time, manual start/stop, live notes/action checkboxes, immediate doorway-note creation, and placeholder processing Jobs
- native Teams detection with Accessibility hang-up evidence, optional microphone corroboration, and debounced end detection; configurable Ask / Automatic / Manual capture policy, with manual override and visible decision diagnostics
- fail-closed Capture Preflight for microphone permission/device readiness, microphone-only system-audio degradation, and writable recording-media capacity, with actionable Settings guidance
- real microphone capture with retained crash-safe CAF recovery/preview audio, compact AAC/M4A finalization, JSON technical metadata, and startup recovery/reporting for interrupted tracks
- separate ScreenCaptureKit system-audio capture on supported Macs, with retained recovery/final artifacts, technical metadata, startup recovery, and explicit microphone-only degradation when unavailable
- canonical validated recording bundles for normal stops and startup recovery, including per-track paths, existence checks, SHA-256 hashes, technical metadata, diagnostics, meeting references, and typed Job handoff
- transcription-only echo-cancelled microphone sidecars using delay estimation, adaptive NLMS filtering, double-talk protection, residual suppression, 6 dB ERLE gate, immutable originals, and fail-open selection
- serial, pauseable local faster-whisper transcription over selected microphone sidecars/originals plus system audio, constrained English/Ukrainian selection and regeneration, Markdown/JSON/WebVTT outputs with provenance/diagnostics, and timestamped search indexing
- automatic app-owned pi/Codex meeting summarization with an editable stable-section Markdown summary, cited structured Decisions/Action Items/Open Questions extraction, and Review Inbox proposals for My Action Items only
- file-backed Activity Item creation and management, including Project ownership, lifecycle status, outputs, and timestamped logs
- SQLite-backed typed Jobs with persisted stages/logs, serial heavy work, throttled lightweight work, retries, failure actions, and generated-artifact validation
- app-owned pi/Codex worker contracts with whole-vault read visibility, read-only tools, explicit sources/outputs/forbidden mutations, Markdown plus JSON proposal outputs, and a Settings integration test
- native unified Window Toolbar with area-scoped workspace search, type filters, recording/Job status, sidebar control
- a dedicated Ask AI tab with selectable workspace context, explicit broader-vault opt-in, visible sources, validated citations, and a tool-free pi/Codex runner that cannot mutate vault files
- macOS menu bar status item
- Settings window placeholder
- lifecycle behavior where closing the window keeps the app running until explicit Quit

## Local transcription setup

Open **Settings → Permissions & Components** and click **Install** beside **Local transcription**. Stillmatter creates an isolated Python environment, pins `faster-whisper` 1.2.1, and downloads the recommended multilingual Large v3 Turbo model. Settings also offers the larger Large v3 model for maximum quality. Setup needs about 4 GB free for Recommended and 7 GB for Full. Stillmatter validates the runtime and model before atomically activating them under `~/Library/Application Support/Stillmatter/Transcription`; the previous valid installation remains active during a switch. Interrupted, cancelled, or invalid installs remain in temporary staging and are removed. Python 3.9 through 3.13 must be installed; Python 3.14 is not currently supported because ONNX Runtime does not publish a compatible macOS wheel. `STILLMATTER_PYTHON` can select a nonstandard compatible Python executable.

The faster-whisper engine supports both English and Ukrainian on Intel and Apple-silicon Macs through CTranslate2's CPU runtime. Choose the language on the Meetings screen before capture. After a finalized meeting, changing that selector and choosing **Regenerate Transcript** queues a fresh run from the immutable recording bundle.

Developers can still bypass the app-managed engine by setting both `STILLMATTER_WHISPER_CLI` and `STILLMATTER_WHISPER_MODEL` to an existing whisper.cpp CLI/model pair. The CLI override is explicit and takes precedence; ordinary users should use the Settings button.

## Developer checks

Stillmatter requires macOS 13 or newer. Local faster-whisper setup additionally requires Python 3.9 through 3.13.

With full Xcode installed:

```sh
swift test
./scripts/test-ui-flows.sh
./scripts/test-weekly-report-window-layout.sh
./scripts/test-contextual-ask-layout.sh
./scripts/test-graphite-focus-presentation.sh
./scripts/test-native-shell-layout.sh
```

To validate Action Item proposal review with an isolated mock workspace, six seeded proposals, guided UI checks, failure/retry coverage, and programmatic outcome verification:

```sh
./scripts/validate-action-item-review.sh
```

Validate the canonical [Graphite Focus contract](docs/graphite-focus/DESIGN.md) and [Stillmatter Application Profile](docs/graphite-focus/STILLMATTER_PROFILE.md), including rejection fixtures for broken references, mappings, literals, and exceptions:

```sh
./scripts/validate-graphite-focus-contract.py --self-test
./scripts/validate-graphite-focus-presentation.py --self-test
```

The presentation harness exercises normal, Increased Contrast, Reduce Transparency, Reduce Motion, and inactive-window fixtures. The presentation validator rejects visual literals in all active feature `*View.swift` files, the shell, and the Weekly Report prompt unless a documented `graphite-focus-native-exception` is present. The native shell harness exercises 720×520, 1200×760, and 1440×760 whole-window fixtures, collapse order, navigation continuity, toolbar/menu parity, and representative feature states.

`scripts/test-ui-flows.sh` builds a separate `.build/ui-tests/StillmatterUITests.app` with its own bundle identifier, then runs the XCTest UI project in `Tests/StillmatterUITests/Runner.xcodeproj`. Each test launches with a fresh temporary workspace and Application Support directory; tests cover the empty Tasks queue, Ask AI broader-vault opt-in, and Settings navigation. It does not exercise real recording, AI requests, or permission changes. XCTest requires an interactive macOS desktop with UI automation permission; the script prints its `.xcresult` path.

The layout checks validate that the AppKit Weekly Report editor and dedicated Ask AI view receive visible, non-zero frames. On systems with Command Line Tools only, SwiftPM may fail while looking for `xctest`; `scripts/build-app.sh` and the layout checks use `swiftc` directly and do not require XCTest.

To walk through Capture Preflight manually with a pause at every significant step:

```sh
./scripts/validate-audio-capture-preflight.sh
```

To validate microphone recording, artifact metadata, playback, and forced-crash recovery in an interactive walkthrough:

```sh
./scripts/validate-mic-track-recording.sh
```

The microphone walkthrough intentionally force-quits one active test capture. Use a disposable test meeting and follow its confirmation gate.

To validate separate system-audio capture, playback, degraded permission behavior, and interrupted-track recovery:

```sh
./scripts/validate-system-audio-recording.sh
```

The system-audio walkthrough changes Screen Recording permission and intentionally force-quits one disposable capture. Follow each confirmation gate.

To validate canonical dual-track finalization, recording metadata, meeting references, processing Job handoff, playback, and startup recovery:

```sh
./scripts/validate-recording-bundle.sh
```

The script performs build, test, file-existence, hash, meeting-reference, and Job-manifest checks. It pauses separately for your UI, playback, diagnostic-meaning, and recovery observations, and intentionally force-quits one disposable capture only after confirmation.

To validate echo-cancelled transcription audio generation, quality-based fallback, source preservation, diagnostics, and playback with a pause at every significant step:

```sh
./scripts/validate-echo-cancellation-sidecar.sh
```

The script owns file, schema, SHA-256, linkage, quality-field, and media-readability checks. You own the on-screen capture observations and the listening judgment for voice intelligibility and audible bleed reduction.

To validate native Teams process/hang-up-control/microphone signals, start/end debounce diagnostics, Accessibility isolation, and the no-auto-recording boundary:

```sh
./scripts/validate-teams-detection-signals.sh
```

The script owns build/test, live-process presence, meeting-file baseline, and no-artifact checks. You own the on-screen signal/permission observations and the live Teams-call judgment.

To validate English/Ukrainian transcription, generated formats, provenance, timestamp indexing, and regeneration interactively:

```sh
./scripts/validate-transcription-pipeline.sh
```

The script owns build/test and artifact/schema checks. You own recording speech, judging transcript accuracy and speaker attribution, observing the app, and confirming search/regeneration behavior.

To validate meeting summarization, cited extraction, editable output, and the My-versus-Other Action Item review boundary with a pause at every significant step:

```sh
./scripts/validate-meeting-summary.sh
```

The script owns build/test, schema, exact citation-range, Inbox routing, and accepted-Todo linkage checks. You own recording the validation meeting, judging summary quality and evidence meaning, making a visible edit, and operating the Review Inbox.

To validate context-scoped Ask AI, broader-vault opt-in, visible citations/sources, and the no-mutation boundary:

```sh
./scripts/validate-contextual-ask.sh
```

The script owns build/test, fixture creation, source-file hashes, and post-Ask mutation checks. You own observing the dedicated tab and context selector, judging answer relevance, and confirming that citations and visible sources match the on-screen answer.
