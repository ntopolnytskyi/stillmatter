# Stillmatter

Stillmatter is a local-first native macOS work log. It records meetings, transcribes English and Ukrainian locally, generates editable summaries, and turns approved action items into Markdown todos.

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

Stillmatter installs an isolated faster-whisper 1.2.1 environment and model under `~/Library/Application Support/Stillmatter/Transcription`. A model switch keeps the previous installation active until the replacement validates. Choose English or Ukrainian before recording; regenerate later to change language.

Developer overrides: `STILLMATTER_PYTHON` selects Python; setting both `STILLMATTER_WHISPER_CLI` and `STILLMATTER_WHISPER_MODEL` selects an existing whisper.cpp installation instead.

## Data and processing

Meetings use Markdown folders with linked audio, transcripts, and summaries. Microphone and system audio are captured separately with recovery files; originals remain evidence. Teams capture policy is configurable as Ask, Automatic, or Manual. Processing Jobs run independently of the current recording. AI workflows use read-only workspace tools and return artifacts and proposals; your action items require approval before becoming canonical todos in `Todos/todo.md`.

The canonical queue is `Todos/todo.md` under `## Queue`, highest priority first. Checkbox states are `[ ]` open, `[x]` done, `[B]` blocked, and `[C]` canceled. Due dates use `due: YYYY-MM-DD`; comments and subtasks are indented. Completion moves an item under a dated `## Done` subsection. Accepted action items retain source links.

## Development

```sh
swift test
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

The old Meeting UI shell scripts and native probe launchers have been removed. XCUITest covers editing, playback, navigation, keyboard search, window resizing, external-file refresh, and Action Item acceptance. The [UI testing guide](docs/development/ui-testing.md) distinguishes verified UI coverage from internal probe assertions that still need an integration test runner.

The interactive walkthrough shell scripts have also been removed. Their repeated build/test gates and automated checks are covered by the commands above; unique real-device, permission, audio-quality, model-output, and review-UI checks are preserved in the [manual validation checklist](docs/development/manual-validation.md).

## Documentation

- [Domain glossary](CONTEXT.md): product terms.
- [Visual rules](docs/graphite-focus/DESIGN.md) and [Stillmatter screen profile](docs/graphite-focus/STILLMATTER_PROFILE.md).
- [Recording and Meetings behavior](docs/meetings-recording-plan.md), including remaining scope.
- [Architecture decisions](docs/adr/) and [local issue tracker](docs/agents/issue-tracker.md).

## License and distribution

Intended license: [GNU GPL v3](LICENSE). The modified echo-cancellation port still has unresolved upstream attribution; see [third-party notices](THIRD_PARTY_NOTICES.md). Do not distribute yet. Development builds warn, and `REQUIRE_LEGAL_FILES=1 ./scripts/build-app.sh` blocks packaging until attribution is resolved.
