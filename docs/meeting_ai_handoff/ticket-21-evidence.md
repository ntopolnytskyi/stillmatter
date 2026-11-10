# Ticket 21 — Transcript reading, search, and speaker filters

Scope: `.scratch/meeting-ai/issues/21-read-search-and-filter-the-transcript-in-three-views.md`. Dependencies 18 and 20 were resolved before implementation. Review and changed-line coverage baseline: `4e341c565409538973e3778dab2ddad32d0b0a44`.

The Transcript now offers **With timestamps** (default), **Clear text**, and **By speakers**. The selected view survives app restart through the existing isolated SettingsStore. Speaker multi-selection, full-recording find, individual occurrence highlighting/traversal, and 100-phrase pages retain saved phrase IDs and original times. Clear text hides metadata while retaining source identity and contextual copy-with-timestamp. All speakers clears the filter. No editing controls or per-row play triangles are offered. Missing Transcript, no matches, and unavailable audio have explicit states.

Keyboard: Command-F finds within the visible Transcript; Command-G and Shift-Command-G move between matches; Shift-Command-1/2/3 choose the three views. Native menus and buttons retain their standard keyboard behavior.

Reader/search/source state survives ordinary detail refreshes. Playback changes active typography and accessibility status without rebuilding the phrase text views. The selected source has its own border, and the current match is underlined with its character range exposed in accessibility help. Switching Meetings clears query/filter/source state. The canonical Transcript files are not rewritten.

## Verification

- Test seams were confirmed by the user: public Transcript-reader state and native app interaction/persistence. Red/green tests covered search, filters/view state, and legacy preference persistence.
- Full Release package suite: **462 tests, four skipped, zero failures**. Evidence: `/private/tmp/stillmatter-21-package-gated/{execution.json,tests.log,report.json}`.
- Full Release hosted suite: **41 passed, zero skipped or failed**, including pagination, speaker deselection, source seek, citation navigation, and time-format checks. Evidence: `/private/tmp/stillmatter-21-hosted-gated/`.
- Focused Release native UI suite: **four passed, zero skipped or failed**. Checks cover empty Transcript, five-tab workspace regression, four-hour search/pagination, keyboard traversal/view switching, multi-speaker filters, contextual copy with original timestamp, unchanged Transcript files, and view persistence after relaunch. Evidence: `/private/tmp/stillmatter-21-native-gated/`. This is a focused UI run, not the final whole-app acceptance run.

The four package skips are existing opt-in external-recording/operational-fixture checks; no ticket 21 feature test is skipped.

Tests exercise synthetic four-hour content with matches at 03:59:00, all occurrences (including repeated/Unicode phrases), page boundaries, filter combinations, no-results/empty/unavailable states, source identity, unchanged files, native controls, keyboard operation, persisted preferences, contextual copy, and updates that retain the same text view instances. Workspace, support, media and preferences are isolated; no real library or model download is used.

Two independent fresh-context reviewers evaluated Standards and Spec against the baseline. Standards initially found playback/selection ambiguity, color-only match state, and duplicated paging arithmetic. Those were fixed; final reviews through `dabc0e6` report **Standards: 0 findings; Spec: 0 findings**.

The initial native exploratory run passed its three tests but was rejected by the coverage collector because production review fixes changed sources during execution. Its profiles are not used in the final gate. An initial hosted attempt also failed to compile while implementation was changing; it is not passing evidence. Fresh compatible lanes are used instead.

A native contextual-copy assertion then exposed that NSTextField's normal right-click behavior did not present the phrase menu. Added a small shared native text control that explicitly presents its assigned menu while retaining selectable, read-only text. The failing scenario and all four native scenarios passed after that fix.

The first combined gate rejected two new data-only types because compiler-synthesized behavior supplied no executable-line maps. Moved the existing preference-restoration expression into `TranscriptReadingView.init(persistedValue:)` and explicitly defined the existing `TranscriptSearchMatch` memberwise initializer. Both now have fully covered executable maps. No shipped-source exclusion or threshold change was made; all three lanes were recollected on the final source.

No new speech-model quality or source-isolation capability is claimed. Ticket 20's real speaker/quiet-reply quality limits remain recorded there. Playback waveform, speaker correction, and item-creation context actions belong to later tickets 22, 23, and 30. Whole-source coverage debt remains subject to tickets 43–46 and 50; it does not lower this ticket's 95% changed-line threshold.

## Final coverage gate

The combined gate exited **0** against `4e341c565409538973e3778dab2ddad32d0b0a44`: **365/370 changed executable lines (98.6486486486%)**, passing the unchanged 95% requirement. All shipped source files have executable maps. Report: `/private/tmp/stillmatter-21-incremental-gate.json`.

| Module | Changed lines covered / executable | Coverage |
| --- | ---: | ---: |
| Core | 7 / 7 | 100% |
| Presentation | 87 / 87 | 100% |
| App/UI | 271 / 276 | 98.19% |
| Combined | **365 / 370** | **98.65%** |

The compatible union measures **18,286/22,882 whole-source executable lines (79.91%)**: Core 93.92%, Presentation 85.69%, runtime 94.24%, app/UI 66.08%. These fresh lanes use focused native interaction coverage, so this figure is measured existing debt, not a full native acceptance baseline or a claim of regression. The final 95% whole-source gate remains unmet and belongs to ticket 50; only this slice's changed-line gate is claimed passed. `git diff --check` also passed.

Reproduce the gate with:

```sh
python3 scripts/coverage.py report \
  --reports /private/tmp/stillmatter-21-package-gated/report.json \
            /private/tmp/stillmatter-21-hosted-gated/report.json \
            /private/tmp/stillmatter-21-native-gated/report.json \
  --base 4e341c565409538973e3778dab2ddad32d0b0a44 \
  --output /private/tmp/stillmatter-21-incremental-gate.json
```
