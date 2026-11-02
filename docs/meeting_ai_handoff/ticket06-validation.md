# Ticket 06 validation

Scope: [Today and Tasks shared controls](../../.scratch/meeting-ai/issues/06-use-shared-controls-in-today-and-tasks.md), requirements R1/R5/R14. Baseline commit: `4e48d2df6266fde4b10f99f8eb600cd09052ba12`. Prerequisite 05 is resolved; no other ticket is implemented by this slice.

Today consumes shared action buttons and collection rows. Tasks consumes shared filters, checkboxes, buttons and editable proposal fields, retaining native table selection and existing proposal traversal. Collection-row drawing subviews forward pointer hits to their button. Today still opens the existing canonical task in Tasks. The previously read-only ledger gains the completion checkbox and focused-table Space action explicitly required by this ticket, using the existing Todo mutator and canonical Markdown transaction. There is no new store, creation flow or schema migration.

Completion rechecks workspace ownership and current item text/state before writing. Canonical note-authored tasks keep their UUID, original checkbox and single Queue/Done reference. Legacy line-based task selection resolves unambiguous content after insertion/reordering; UUID selection survives title edits. Refresh and completion preserve nearby selection/focus, including Today's empty-queue Open Tasks action. Errors expose refresh/retry controls; completed/canceled items cannot be reopened with the checkbox. Non-Queue legacy checkboxes found elsewhere in the workspace have disabled completion controls: the existing mutator supports canonical personal Queue items, not arbitrary Markdown checkboxes. This slice does not expand that mutation contract.

## Executed evidence

Initial coverage collectors use Release compilation conditions with `-Onone` and separate build/profile roots. Tests use synthetic, disposable workspace/support/media roots and preference namespaces.

| Lane | Result | Evidence |
| --- | --- | --- |
| Complete package suite | 357 tests, 4 skipped, 0 failures | `/private/tmp/stillmatter-06-final-package/{execution.json,tests.log,inventory.json,report.json}` |
| Complete hosted suite | 18 tests, 0 skipped, 0 failures | `/private/tmp/stillmatter-06-final-hosted/results.xcresult`, `execution.json`, `report.json` |
| Complete native UI suite | 19 tests, 0 skipped, 0 failures | `/private/tmp/stillmatter-06-final-native/results.xcresult`, `execution.json`, `report.json` |
| Additional canonical-item keyboard UI test | 1 test, 0 failures | `/private/tmp/stillmatter-06-keyboard.xcresult`, `/private/tmp/stillmatter-06-keyboard.log` |

The additional keyboard test was added after the full native suite's build had captured its test sources, so it was executed separately against the same production source.

A final whitespace check then caught one trailing blank line at EOF in the extracted collection-row source. Removing it changes the exact source hash, so fresh execution and normalized evidence were collected with the same shipping flags and existing build caches: full package **357 / 4 skipped / 0 failures**, full hosted **18 / 0 / 0**, and focused native **4 / 0 / 0** (proposal acceptance plus the three Today/Tasks flows). These final-source results are `/private/tmp/stillmatter-06-verified-{package,hosted,native}/`, each with `inventory.json`, `execution.json`, `tests.log`, `coverage.lcov` and `report.json`; Xcode lanes also retain `results.xcresult`. The reproducible refresh driver and exact commands remain at `/private/tmp/stillmatter-06-refresh-coverage.py`. This focused rerun is not represented as another full native run. The earlier full 19-test result remains valid behavioral evidence before this non-executable whitespace cleanup; incompatible source-hash reports are not merged.

Hosted assertions cover shared style propagation to both real pages; navigation without file changes; source-filter retention; canonical completion and disabled completed checkbox; keyboard completion; nearest-row selection; external stale-row refusal; foreign/missing workspace refusal; empty/failed/unavailable pages and retry/settings actions; detail return/retry buttons; UUID focus after an external rename; legacy selection after insertion/reordering; nearest Today focus after removal and empty-action focus. The Today layout is also exercised in a narrow hosted window.

Native assertions cover Today row pointer activation, Sidebar navigation, filter persistence without canonical writes, spaces typed into the filter without completing tasks, pointer completion of a note-authored item, arrow selection and Space completion, nearest selection after removal, empty queue/Today guidance, persistence after relaunch, malformed-file error/retry on both pages without silently repairing files, and keyboard completion of the same canonical note-authored fixture in a fresh workspace. Existing native proposal review/editing/conflict/refresh and shell navigation tests also pass.

The first native run passed 18/19 tests and exposed the collection-row pointer hit bug; that failure and attachments remain at `/private/tmp/stillmatter-06-native/`. The final full rerun above includes the fix. An earlier hosted launch was blocked by sandbox access to `com.apple.testmanagerd.control`; the successful hosted and native runs used the required test-runner access. An early regression assertion ran before hosted layout, was corrected to settle layout, and passed in the final hosted run. Failed runs do not contribute passing coverage evidence.

## Coverage gates

The compatible final-source package/hosted/focused-native source-location union includes every required shipped file and passes the **95% incremental gate: 242/250 changed executable lines, 96.80%**, exit 0. Report: `/private/tmp/stillmatter-06-verified-incremental.json`. The prior full-suite union independently passed at the same 242/250 before the trailing whitespace cleanup (`/private/tmp/stillmatter-06-incremental.json`).

| Module | Covered / executable lines | Whole-source coverage |
| --- | ---: | ---: |
| StillmatterCore | 7,768 / 8,529 | 91.08% |
| StillmatterPresentation | 1,097 / 1,292 | 84.91% |
| StillmatterTranscriptionRuntime | 93 / 183 | 50.82% |
| Stillmatter app/UI/platform | 5,819 / 10,317 | 56.40% |
| Combined | 14,777 / 20,321 | 72.72% |

The final-source `--whole` gate fails at **72.72%** (exit 1): `/private/tmp/stillmatter-06-verified-whole.json`. The broader full-suite union before whitespace cleanup measured **16,040/20,321 (78.93%)** and also failed its whole gate (`/private/tmp/stillmatter-06-whole.json`). The difference reflects focused versus full native execution, not a product regression. Neither result meets final specification completion; whole-source coverage debt remains later-ticket work. No exclusions or thresholds were weakened.

## Other checks and limits

Code-review Standards: zero findings. Spec: two refresh focus/selection findings were fixed and re-reviewed with zero remaining findings. `git diff --check`, Graphite Focus structural validation and compiled native-probe isolation pass.

The pre-existing presentation validator fails at unchanged `Sources/Stillmatter/DesignSystem/GraphiteFocusControlStyle.swift:5`, which uses the native system font default. That file is identical to the baseline; this ticket does not change its styling policy or suppress the validator. No claim of a passing presentation validator is made.

No capture/source-isolation, hardware, model quality, remote transfer, or inference capability is introduced or claimed. Existing Markdown identity/storage is preserved; the native completion/relaunch assertions and real temporary-file tests verify compatibility rather than introducing a new migration.
