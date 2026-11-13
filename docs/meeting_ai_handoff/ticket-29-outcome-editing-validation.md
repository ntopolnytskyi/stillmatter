# Ticket 29 — Decisions and Open Items editing

Only ticket 29 is resolved. Dependencies 18 and 25 were resolved before implementation. Review and coverage baseline, confirmed by the user: `c98746e4db5aeb8ef5fe8783836d357e43fa238d`.

## Changes

Decisions have their full list, Add, Edit, confirmed Delete and source controls inside Summary. There is no Decisions tab or navigation target. Open Items stays in its own tab and supports Question/Issue type, explicit owner or unknown owner, source selection, text editing, resolve and confirmed deletion. Resolved items cannot be reopened through the app; valid external file edits remain authoritative. Archived content is read-only.

Both editors use the shared Graphite controls. Command-Return saves, Escape cancels, and item buttons support the shared keyboard activation behavior. Empty lists offer Add. A failed save retains the draft and explains recovery. “Save my draft over latest item” explicitly refreshes and replaces that one item while retaining other current external content. Cancel discards the draft and refreshes saved content. Editing is disabled during an in-flight save, and model updates cannot replace its submitted draft. External refresh preserves the focused field and caret selection in the actual Meeting workspace. Cancelling a draft also re-enables the other artifact's Add controls.

Canonical Markdown keeps its surrounding prose, stable UUID metadata, origin, legacy outcome reference and source citations through normal edits. Optional `kind` and `resolved` metadata are backward compatible: existing Decisions default to Decision, existing Open Items to unresolved Question. Owners are explicitly entered, never inferred. Existing citation metadata can be retained even when evidence is unavailable; new citations must match an available Transcript segment. Available source links open the existing Transcript navigation; missing evidence keeps its unavailable state. Regeneration retains canonical identities for matching generated outcome references. Working generated content can still be replaced under the existing regeneration contract; history and confirmation integration remain tickets 31/32.

## Verification

| Final lane | Tests | Skipped | Failures | Evidence |
| --- | ---: | ---: | ---: | --- |
| Full Release package | 528 | 5 existing skips | 0 | `/private/tmp/ticket29-package3` |
| App-hosted native controls | 1 comprehensive flow | 0 | 0 | `/private/tmp/ticket29-hosted4` |
| Main-app XCUITest | 1 comprehensive flow | 0 | 0 | `/private/tmp/ticket29-native3` |

The focused `MeetingOutcomeEditingTests` run also passed all 3 tests. SwiftPM and Xcode compilation provide typechecking. `git diff --check` and Graphite structural validation pass. The presentation validator retains the existing visual-literal finding at unchanged `TranscriptReaderView.swift:426`; this ticket does not fix that baseline finding.

Package tests exercise Decision/Open Item identity, owner/type/status round trips, service restart, canonical deletion, text validation, missing source rejection, external conflict preservation and explicit retry, old citation metadata, surrounding prose, malformed metadata, duplicate identities and generated identity retention. Existing full-suite tests cover canonical migration, transactions and regeneration.

The app-hosted flow uses the real Meeting read model and serialized mutation executor over a disposable workspace. It verifies empty/Add, owner/type/source controls, Save, Cancel, explicit conflict retry, disabled editing during Save, protection against late model updates, dirty-draft navigation Save, resolve, cancelled/confirmed deletion, archived controls, and keyboard Escape. It also verifies that an external Summary refresh retains a Decision draft, first responder and selected range through the actual parent rendering path. It runs at 720×680 and a 620×680 editor host.

The XCUITest drives the main app through accessibility identifiers. It verifies Decision creation in Summary, empty-text failure and retained editor, source selection, Command-Return Save, Transcript source navigation, external editing conflict with preserved local text, Escape Cancel, switching to Open Items after cancelling, Issue creation with explicit owner, resolve, app relaunch with persisted status/owner, disabled reopening, and confirmed deletion persisted to both canonical files. No Decisions radio tab exists. Fixtures use isolated workspace, support, media and preferences; no real user library, credentials or Meeting is used.

Earlier runs remain in `/private/tmp/ticket29-*`. The first native run exposed stale disabled sibling controls after cancelling a Decision draft; this was fixed and the final native run passed. Review found missing conflict rebase, in-flight edit protection, deletion confirmation and parent-path focus preservation; each was fixed and verified. Runs whose source inventory changed during execution were correctly rejected by the collector and are not used in the final gate.

## Coverage gate

The existing repository collector ran through the prior cache-reuse wrapper, with fresh profiles and compatible source inventories. No coverage policy or production exclusion changed. Complete shipped-source representation is checked, and reports merge by source location without double counting.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 /private/tmp/run-ticket27-coverage.py package \
  /private/tmp/ticket29-package3 /private/tmp/ticket27-package-cache

python3 /private/tmp/run-ticket27-coverage.py hosted \
  /private/tmp/ticket29-hosted4 /private/tmp/ticket27-hosted-cache \
  StillmatterHostedTests/MeetingOutcomeEditingHostedTests

python3 /private/tmp/run-ticket27-coverage.py native \
  /private/tmp/ticket29-native3 /private/tmp/ticket27-native-cache \
  StillmatterUITests/StillmatterFlowsUITests/testDecisionsAndOpenItemsEditingConflictSourcesAndRelaunch

CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache \
python3 scripts/coverage.py report \
  --reports /private/tmp/ticket29-package3/report.json \
            /private/tmp/ticket29-hosted4/report.json \
            /private/tmp/ticket29-native3/report.json \
  --base c98746e4db5aeb8ef5fe8783836d357e43fa238d \
  --output /private/tmp/ticket29-final-gate.json
```

Gate exit status: **0**.

| Changed module | Covered / executable lines | Coverage |
| --- | ---: | ---: |
| Core | 70 / 70 | 100% |
| Presentation | 40 / 41 | 97.56% |
| App/UI | 198 / 199 | 99.50% |
| Combined | **308 / 310** | **99.35%** |

Whole-source measurement from these lanes is **18,038 / 25,583 = 70.51%**: Core 94.09%, Presentation 84.82%, runtime 94.24%, app/UI/platform 46.68%. These scoped native/hosted lanes do not execute every earlier UI feature; this is not a whole-app 95% claim. Ticket 50's final whole-source gate remains open.

## Standards

The code-review skill's fresh-context Standards reviewer inspected the baseline diff, repository/domain/ADR guidance, Graphite contracts, UI testing and coverage guidance, and the full smell baseline. Missing destructive confirmation and parent-path focus loss were fixed and re-reviewed. Final result: **0 actionable documented-standard violations or baseline smells**.

## Spec

A separate fresh-context reviewer inspected ticket 29 and R3/R4/R8/R14. Conflict retry and typing during Save were corrected and re-reviewed. Final result: **0 remaining actionable spec findings or scope creep**.

Review totals: Standards **0**, Spec **0**; neither axis has a remaining worst issue.

## Capability limits

This slice adds editing and navigation, not a new inference, recording or hardware capability. No synthetic fixture is used to claim model quality or source isolation. Ticket 25's unsupported fully local grounded analysis and bounded final-context envelope remain in force, alongside the earlier recorded ASR/source/speaker-quality limits. Revision history and confirmed regeneration integration remain explicitly assigned to tickets 31/32. Whole-source coverage and release lifecycle completion remain ticket 50 work.
