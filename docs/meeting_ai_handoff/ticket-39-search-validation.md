# Ticket 39 — Local semantic search

Scope: ticket 39 only. Dependencies 03, 08, 25 and 36 were resolved before implementation. Review baseline: `2b335f71fa03e085b1c8b1bb043408a117ead835`. Existing unrelated untracked work is preserved.

## Delivered behavior

Status Bar search combines keyword matches with locally ranked E5 suggestions over canonical Meeting Transcript, Summary, My Notes and outcomes. Existing area and result-type scopes and Todo destinations remain available. Approved personal note and Action Item checkboxes retain Todo search results; user-authored My Notes checkboxes default to Me/approved. Pending proposals, malformed explicit identity metadata and other owners’ tasks do not become individual Todo results. Archived Todo hits open their read-only owning Meeting. Each result retains its source path and transcript timing. Opening a Meeting result selects its owning Meeting and Summary, My Notes, Action Items, Open Items or Transcript as appropriate; a timed Transcript result refreshes canonical detail and matches both time and text to locate its utterance, including overlapping speakers, and seeks retained audio when available.

Archived is explicitly off by default, resets after relaunch/workspace changes, and includes retained archived text only after opt-in. The Status Bar checkbox and Navigate → Include Archived in Search share the same behavior and menu state. Archived result navigation selects the archived Listing without enabling editing.

Canonical edits, regeneration replacements and removals refresh the index and currently visible search. The canonical JSON/`transcript.txt` pair is read with the existing codec and manifest base hash without rewriting either source. A valid external text edit is searchable while the Meeting browser is closed; results name the actually authoritative representation. Conflicting or malformed pairs, unsupported manifest versions, mismatched Meeting paths and unsafe companions fail closed and surface an error until repair. Pair/manifest updates replace related chunks atomically; either canonical representation suppresses an old VTT copy. A prior search-source error does not reject an unrelated Meeting publication. Markdown preambles are retained. Both successful inference and failed-inference keyword fallback reject removed snapshots. A changed/removed utterance reports that it is no longer available and clears the prior jump. Source navigation is bound to its originating read model and request through owner lookup and detail loading; missing owners report an unavailable source and cannot later select a same-path Meeting in another workspace. Older query/workspace results cannot replace a newer request.

Private Voice Profile directories, noncanonical Meeting files, hidden files, configured exclusions and escaping paths/symlinks are excluded. Logical and resolved paths both honor exclusions; existing canonical Transcript companions are excluded together, so another representation or an inside-workspace symlink cannot bypass a private path rule. Only permitted canonical Meeting text reaches the semantic provider; existing global destinations retain keyword search. No search-content upload or automatic model download occurs. Child-process inputs live in a private temporary directory and are removed on completion/failure. Vectors are not persisted, so no stale vector store or vector migration is introduced.

## Local model and supported limits

[Setup instructions](../local-search.md) describe explicit installation into the app's own support root. Tests use `/private/tmp/ticket39-e5`, not a user library or installed app configuration. The installer downloads public packages and pinned MIT-licensed multilingual E5-small model/tokenizer artifacts and verifies their hashes. Runtime inference uses explicit local files, an isolated Python invocation and a minimal offline environment.

[Actual synthetic model evaluation](ticket-39-e5-evaluation.json) records model/tokenizer hashes, runtime versions, environment, exact queries and rankings. Eight answerable paraphrase, Ukrainian/English and accent queries achieved Recall@1 **75%**, Recall@3 **100%**, MRR **0.8333**; the unrelated query is reported separately. A long-document fixture places the relevant passage beyond the first token window and verifies it ranks above an unrelated passage. All tokens are covered in bounded windows; queries over 512 tokens fail rather than truncate silently.

These are synthetic retrieval measurements, not calibrated human-quality or relevance guarantees. There is no calibrated abstention threshold. The UI labels semantic results as suggestions and asks users to verify sources. Missing/damaged models, malformed output, failed inference and a bounded 120-second timeout retain keyword results with an explicit capability/setup notice. One inference process runs per provider; rapid overlapping queries cannot multiply model memory, and superseded requests waiting for capacity are discarded. Vectors are recomputed per query, so large libraries may be slow. Local search remains unsupported until its optional component is installed; it never falls back to remote inference.

Retention cleanup and comprehensive permanent deletion remain Release 2.0 tickets 37/38. This slice tests actual canonical file removal, index cleanup and truthful missing-source behavior; it does not claim those later jobs or controls exist.

## Behavioral verification

Package tests use real disposable canonical files and SQLite indexes for keyword/semantic combination, accents, archive defaults and opt-in, edits/replacements/removal/restart, workspace isolation, path/symlink/privacy exclusions, Markdown preambles, corrected Transcript precedence and both successful/failed delayed inference. Controlled local child processes verify output validation, setup failure and bounded timeout; they do not prove model quality. The actual E5 test is a distinct opt-in lane, enabled in the final full package run.

App-hosted tests cover filesystem events and publication after external edits/removal, canonical text conflict/error publication and repair without opening the Meeting, outside-workspace symlink replacement, model-provider preservation across index recovery, delayed old-query rejection, workspace invalidation, loading/error states, repeated source routes across all five tabs, unchanged browser snapshots, overlapping utterance selection, missing-source cancellation, same-relative-path workspace switching and archive menu state. Native UI tests cover the real checkbox/menu, archive default/relaunch/read-only notes, visible-result external refresh/removal, late Transcript navigation, Command-F, arrow/Return/Escape, retained query, owning Meeting and Todo destinations, type filtering and the minimum-width Status Bar/Back behavior. Tests isolate workspace, support, media, preferences and operational state; no private user content is used.

Final executed lane counts and coverage gate are recorded below. The native run contains the explicit Summary deletion and repair scenario: deleting a required canonical artifact correctly requires repair before the Meeting can be opened; Search does not recreate it. The test restores the original Summary before testing the independent Transcript edit route.

## Executed verification

| Lane | Result | Artifacts |
| --- | --- | --- |
| Final full Release package, actual E5 enabled | **576 tests, 5 existing opt-in skips, 0 failures** | `/private/tmp/ticket39-package8/{execution.json,tests.log,report.json}` |
| Final Release app-hosted search and controls | **8 tests, 0 skips or failures** | `/private/tmp/ticket39-hosted11/{execution.json,tests.log,results.xcresult,report.json}` |
| Release native search scenarios | **7 tests, 0 skips or failures** | `/private/tmp/ticket39-native8/{execution.json,tests.log,results.xcresult,report.json}` |

The native run tested source `72007d6`. The sole subsequent production change, `354e274`, affects Core exclusion handling. All **92 shipped app/UI and Presentation source files** in the passing native inventory still match their final source hashes. UI tests skipped: no UI code changed (for that final Core-only follow-up). This does not mean the ticket's native tests were skipped: all seven required interaction scenarios executed and passed.

The five package skips are the pre-existing opt-in real echo fixture, recording-bundle echo replay, operational-fixture seeder, configured-workspace playback replay and live signed-in ChatGPT quality lane. The actual E5 lane executed. The final ranking output matches the retained evaluation report exactly. No stub proves model quality.

The final shared **95% changed-line gate passes: 387/399 = 96.99%**. Core is **184/184 (100%)**, transcription runtime **51/51 (100%)**, and app/UI **152/164 (92.68%)**. The policy gates the aggregate and reports modules separately. Every changed executable source location is accounted for; no changed production source exclusion was introduced.

The gate deliberately merges only the compatible final-source package and hosted reports. The passing native coverage is **not** merged because the later Core-only change makes its full source inventory incompatible. Native execution remains valid interaction evidence for the unchanged UI files. [Coverage and execution summary](ticket-39-coverage.json); raw gate `/private/tmp/ticket39-final-gate.json` (exit 0). This is an incremental ticket gate, not the ticket 50 whole-source 95% release gate, which is not claimed.

Executed cached collectors reset profiles and keep fresh output/evidence directories. Equivalent clean-cache reproduction uses the repository collector:

```sh
STILLMATTER_E5_TEST_COMPONENT=/private/tmp/ticket39-e5 python3 scripts/run-coverage.py package --output /private/tmp/reproduce-ticket39-package
python3 scripts/run-coverage.py hosted --output /private/tmp/reproduce-ticket39-hosted --only-testing StillmatterHostedTests/MeetingSearchHostedTests --only-testing StillmatterHostedTests/MeetingsSearchShellControlsHostedTests --only-testing StillmatterHostedTests/AppCompositionHostedTests
python3 scripts/run-coverage.py native --output /private/tmp/reproduce-ticket39-native --only-testing StillmatterUITests/StillmatterFlowsUITests/testSearchArchiveOptInOpensRetainedNotesAndResetsAfterRelaunch --only-testing StillmatterUITests/StillmatterFlowsUITests/testSearchExternalEditAndRemovalRefreshVisibleResultsWithoutChangingQuery --only-testing StillmatterUITests/StillmatterFlowsUITests/testSearchTranscriptResultLocatesLateSourceAndKeepsGlobalQuery --only-testing StillmatterUITests/StillmatterFlowsUITests/testSearchKeyboardNavigationAndEscapePreserveQuery --only-testing StillmatterUITests/StillmatterFlowsUITests/testMinimumWindowShowsGlobalSearchAndBackRestoresMeetingSelection --only-testing StillmatterUITests/StillmatterFlowsUITests/testSearchResultNavigatesToOwningMeetingAreaAndSelectsMeeting --only-testing StillmatterUITests/StillmatterFlowsUITests/testTodoSearchResultOpensTasksAndResultTypeKeepsQuery
python3 scripts/coverage.py report --reports /private/tmp/reproduce-ticket39-package/report.json /private/tmp/reproduce-ticket39-hosted/report.json --base 2b335f7 --incremental-only --output /private/tmp/reproduce-ticket39-gate.json
```

Install the isolated evaluation component first using `scripts/install-local-search.py` if reproducing on a fresh machine. Native testing requires an unlocked, available foreground session. One diagnostic run failed before assertions because macOS would not activate its app; after the user confirmed availability, the real native tests ran successfully. Failed, interrupted and source-incompatible diagnostic reports are excluded from final coverage.

Graphite Focus structural validation, Python installer syntax and `git diff --check` pass. The presentation validator still reports the pre-existing `TranscriptReaderView.swift:438` visual-literal violation, unchanged by this ticket. No whole-app visual or hardware/model quality claim is inferred from source validators.

The user explicitly requested coverage gates despite the ticket-local exemption; the shared changed-line gate was therefore enforced. Retention/deletion jobs remain deferred under the ticket's Release 2.0 amendment.

## Standards

Final independent review through `354e274` reports no documented-standard violations. The initial semantic-status color concern is fixed. The archive filter also has a menu route; the reviewer clarified that the initial assertion that every Status Bar filter required a separate menu route overstated the documented rule.

One optional **P3 Duplicated Code** judgment remains: approved-personal Todo eligibility repeats the existing canonical `owner == "me" && review == "approved"` predicate. A shared predicate is suggested as future cleanup; it is not a correctness blocker. No other actionable baseline smells remain.

## Spec

Independent review identified and verified fixes for stale failed-inference fallback, stale sibling VTT, repeated/equal-snapshot navigation, missing-owner persistence, both phases of workspace ownership, approved personal Todo regression, canonical text authority and exclusion bypass. The latest source refresh also waits for canonical detail, reports changed utterances and preserves unrelated publication despite an existing search error. Final review through `354e274` reports no remaining concrete Spec findings or scope creep.

Review totals: **Standards 1 optional P3; Spec 0**. Worst within Standards: optional predicate duplication; within Spec: none. Test execution and coverage are separate evidence.
