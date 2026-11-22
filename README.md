# Stillmatter

Stillmatter is a native macOS work log with local recording and transcription. It generates editable summaries through optional, explicitly enabled ChatGPT text analysis and exposes approved personal action items as Markdown todos.

Today brings together your Inbox, queue, and upcoming meetings. Recording handles the current capture; Meetings provides history, playback, notes, transcripts, and processing controls. Tasks and Settings complete the app.

## Build and run

Requires macOS 13 or newer.

```sh
./scripts/build-app.sh
open .build/Stillmatter.app
```

Closing the window leaves Stillmatter running in the menu bar; use Quit to exit.

Upgrades from the previous app name do not migrate settings, Application Support data, or workspace metadata automatically. Back up existing data before replacing an older installation.

## Transcription setup

In **Settings → Permissions & Components**, choose **Install** beside **Local transcription**. Setup requires Python 3.9–3.13 and about 4 GB free for the recommended Large v3 Turbo model, or 7 GB for Large v3. Python 3.14 is currently unsupported by this setup.

Stillmatter installs an isolated faster-whisper 1.2.1 environment and model under `~/Library/Application Support/Stillmatter/Transcription`. A model switch keeps the previous installation active until the replacement validates. Auto is the default language mode; confirmed reprocessing supports English/Ukrainian overrides.

Developer overrides: `STILLMATTER_PYTHON` selects Python; setting both `STILLMATTER_WHISPER_CLI` and `STILLMATTER_WHISPER_MODEL` selects an existing whisper.cpp installation instead.

## Data and processing

Meetings use Markdown folders with linked audio, transcripts, and summaries. Microphone and system audio are captured separately with recovery files; originals remain evidence. Teams capture policy is configurable as Ask, Automatic, or Manual. Processing Jobs run independently of the current recording. Analysis sends the Transcript and My Notes through Pi only when **Allow ChatGPT analysis of Meeting text** is enabled in Settings; it defaults off. Local grounded analysis is unsupported.

The personal Queue is `Todos/todo.md` under `## Queue`, highest priority first. Approved Meeting tasks appear as references to the same canonical item; note-authored tasks remain in My Notes. Checkbox states are `[ ]` open, `[x]` done, `[B]` blocked, and `[C]` canceled. Due dates use `due: YYYY-MM-DD`; comments and subtasks are indented. Completion moves a Queue entry under a dated `## Done` subsection. See [current Meeting behavior](docs/product/MEETING_FEATURE.md) for task authority and approval rules.

## Development

```sh
make test-fast       # cached focused package tests, no instrumentation
make test-package    # complete SwiftPM suite
make test-hosted     # AppKit integration
make test-e2e        # real Stillmatter.app journeys; unlocked Mac required
make test-full BASE=<implementation-base-SHA>  # fresh coverage and 95% gates
python3 scripts/validate-graphite-focus-contract.py --self-test
python3 scripts/validate-graphite-focus-presentation.py --self-test
```

SwiftPM tests require XCTest from Xcode; Command Line Tools alone may fail to find `xctest`.

For native UI tests, open `Stillmatter.xcodeproj`, select the **Stillmatter** scheme, and use **Product → Test**. Or run:

```sh
xcodebuild test \
  -project Stillmatter.xcodeproj \
  -scheme Stillmatter \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode-ui \
  -resultBundlePath .build/ui-results.xcresult
```

Use a new result bundle path for each run. Tests control a separate app with disposable data; keep the Mac unlocked and avoid using the keyboard or mouse during a run. See the [UI testing guide](docs/development/ui-testing.md) for coverage, isolation, and adding tests.

The [testing strategy](docs/development/testing-strategy.md) defines the test pyramid, journey filters, fixture rules and coverage profiles. The [migration matrix](docs/development/test-migration-matrix.md) accounts for all original UI tests; [refactor results](docs/development/test-refactor-results.md) distinguish executed evidence, baseline failures and gaps. Control-host UI automation is a separate component profile (`make test-controls`) and does not count as real-app E2E.

The interactive walkthrough shell scripts have also been removed. Their repeated build/test gates and automated checks are covered by the commands above; unique real-device, permission, audio-quality, model-output, and review-UI checks are preserved in the [manual validation checklist](docs/development/manual-validation.md).

## Documentation

- [Product index](docs/product/INDEX.md): reading paths, current coverage and documentation authority.
- [Domain glossary](CONTEXT.md): business terms.
- [Shared UI principles](docs/UI_PRINCIPALS.md): visual rules, native controls, shell and application composition.
- [Meeting feature](docs/product/MEETING_FEATURE.md): implemented behavior and feature-specific UI.
- [Planned work](docs/planned/INDEX.md): future ToDo specification and unresolved integration decisions.
- [Architecture decisions](docs/adr/) and [local issue tracker](docs/agents/issue-tracker.md).

## License and distribution

Intended license: [GNU GPL v3](LICENSE). The modified echo-cancellation port still has unresolved upstream attribution; see [third-party notices](THIRD_PARTY_NOTICES.md). Do not distribute yet. Development builds warn, and `REQUIRE_LEGAL_FILES=1 ./scripts/build-app.sh` blocks packaging until attribution is resolved.
