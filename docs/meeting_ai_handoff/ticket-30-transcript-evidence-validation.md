# Ticket 30 — Transcript evidence and linked items

Scope is ticket 30 only. Dependencies 21, 22, 26 and 29 were resolved before implementation. User-confirmed review and changed-line coverage baseline: `e3f205942c688f7d294026ac491eda4ea07dfe82`.

## Changes

Transcript phrases offer Copy text, Copy with timestamp, Copy speaker, Add Action Item, Add Decision, Add note and Jump to moment. The same native menu is available through a keyboard-focusable Actions control. Source identity and timing are checked both when showing a menu and when executing it, including stale menu callbacks. Transcript text remains read-only and its time buttons have no play triangle.

Each addition opens an editable sheet and requires Save. New Action Items have stable canonical IDs and citations, manual provenance, unknown ownership and pending review; the sheet explains that owner selection and approval happen in Action Items. They use the existing editor, approval and same-item Todo projection. New Decisions use the canonical Decision serializer and remain editable in Summary. Notes are explicit user writes through the existing versioned My Notes service, preserving the user's language and prose with a stored source citation. No inference or automatic note insertion is involved.

Command-Return saves; Escape cancels. The sheet disables editing during Save. Failed writes leave the draft visible and explain recovery; a conflicting external edit is not overwritten. Cancel and reopen uses the latest file and source. The sheet returns focus to Transcript search after saving or cancelling.

A source citation opens Transcript, reveals and selects its utterance beyond the initial page/window and seeks validated retained audio. Seeking preserves paused or playing intent. Missing Transcript evidence disables the source control with “Source no longer retained”; retained text with missing audio remains readable and explicitly reports audio unavailability.

The waveform draws speech, Decision, Action and Question markers in distinct semantic colors, with a visible letter-and-name legend so color is not the only identifier. A native Timeline markers menu gives keyboard access to the validated markers and reveals the selected utterance. Its targets carry the owning Meeting and original citation rather than a mutable list index. Open Items also appear in the Transcript timeline/filter projection.

## Verification

| Final lane | Reported tests | Skipped | Failures | Evidence |
| --- | ---: | ---: | ---: | --- |
| Full Release package | 530 | 5 existing skips | 0 | `/private/tmp/ticket30-package2` |
| App-hosted Transcript/playback | 18 | 0 | 0 | `/private/tmp/ticket30-hosted3` |
| Main-app XCUITest | 2 | 0 | 0 | `/private/tmp/ticket30-native4` |

All three collectors completed successfully with fresh profiles and matching source inventories. Test logs, execution summaries, normalized coverage and native result bundles remain in these directories.

Focused package tests exercised Action identity/citations across edit, approval and service restart; unknown ownership and pending review; duplicate-save prevention; editable Decisions; explicit multiline note writes; stale Summary/notes conflicts; invalid content; and source removal. Projection tests cover Question sources alongside speech, Decisions and Actions without inventing speakers or audio.

The app-hosted Transcript and playback suites verify copy values, identical contextual/keyboard menu contents, creation dispatch, unavailable and disabled actions, no per-row play icon, source highlighting, existing search/filter/paging behavior, and all four waveform marker categories. The late-citation scenario uses generated retained audio and more than 200 preceding phrases: a real Decision source button must select the owning Meeting/Transcript tab and late utterance, seek its saved time and preserve both paused and playing intent. Existing playback tests also cover discontinuous tracks, purged media, speed and delayed starts.

The main-app tests use semantic accessibility identifiers and observable waits. They drive every copy/create action near the end of a four-hour synthetic Transcript, edit and save records, preserve a local note draft when an external file changes, cancel/reopen/save, navigate a saved Decision citation and verify relaunch persistence. Removing Transcript representations makes the saved source unavailable. The retained-audio scenario activates marker and Jump actions by keyboard and verifies seek position and playback intent. Both use isolated workspace, support/preferences and media roots. The native scenarios run in the real app; hosted controls include the existing bounded-size layout checks.

SwiftPM/Xcode compilation provides typechecking. `git diff --check` and Graphite structural validation pass. The Graphite presentation validator retains the unchanged pre-existing literal finding formerly at `TranscriptReaderView.swift:426` (now shifted by additions); ticket 29 recorded the same debt.

## Coverage

The existing repository collector and cache-reuse wrapper use fresh profiles and compatible source inventories. No coverage threshold, source exclusion, shipping setting or policy changed. The gate combines executable lines by source location and requires complete shipped-source representation. Earlier runs with changed source inventories were rejected and are not accepted coverage evidence. A package build that caught a test-file edit during compilation was rerun; failed builds/runs are not passing evidence.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py package \
  /private/tmp/ticket30-package2 /private/tmp/ticket27-package-cache

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py hosted \
  /private/tmp/ticket30-hosted3 /private/tmp/ticket27-hosted-cache \
  StillmatterHostedTests/TranscriptReaderHostedTests \
  StillmatterHostedTests/MeetingPlaybackHostedTests

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py native \
  /private/tmp/ticket30-native4 /private/tmp/ticket27-native-cache \
  StillmatterUITests/StillmatterFlowsUITests/testTranscriptLinkedItemsTailCitationUserNoteConflictAndRelaunch \
  StillmatterUITests/StillmatterFlowsUITests/testPlayableRecordingHasFullWidthSeekControl

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 scripts/coverage.py report \
  --reports /private/tmp/ticket30-package2/report.json \
            /private/tmp/ticket30-hosted3/report.json \
            /private/tmp/ticket30-native4/report.json \
  --base e3f205942c688f7d294026ac491eda4ea07dfe82 \
  --output /private/tmp/ticket30-final-gate.json
```

Gate exit status: **0**. The 95% changed-line gate passes at **100% (158 / 158 executable lines)**.

| Changed module | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| Core | 30 / 30 | 100% |
| Presentation | 12 / 12 | 100% |
| App/UI | 116 / 116 | 100% |
| Combined | **158 / 158** | **100%** |

Measured whole-source coverage from these compatible lanes is **18,945 / 25,735 = 73.62%**: Core 94.14%, Presentation 83.38%, runtime 94.24%, app/UI/platform 53.33%. These focused native/hosted lanes do not execute every earlier UI feature. This is an incremental completion claim, not a whole-app 95% claim; ticket 50 remains open.

## Standards

The code-review skill's fresh-context Standards reviewer checked the baseline diff, repository/domain/ADR guidance, Graphite contracts, testing/coverage guidance and the smell baseline. A duplicated source-validation predicate was consolidated; an expanded fixture's stale expected marker was corrected. Final review: **0 remaining Standards findings**.

## Spec

The separate fresh-context Spec reviewer checked ticket 30 and the approved spec. The initially missing retained-audio late-citation scenario was added and reviewed. Final review: **0 remaining Spec findings or scope creep**.

Review totals: Standards **0**, Spec **0**; neither axis has a remaining worst issue. Test execution and coverage evidence are distinct from these reviews.

## Capability limits

This slice adds evidence navigation and explicit user editing; synthetic audio does not establish real capture isolation, hardware behavior or model quality. Ticket 25's fully local grounded-analysis limitation remains: the approved bounded ChatGPT/Pi RPC path is implemented, while fully local grounded analysis is unsupported. Earlier ASR, source-isolation and speaker-quality limits remain recorded under their own tickets. Revision history/reprocessing protections remain tickets 31/32; release-wide lifecycle validation and at least 95% whole-source coverage remain ticket 50. This incremental slice does not claim release completion.
