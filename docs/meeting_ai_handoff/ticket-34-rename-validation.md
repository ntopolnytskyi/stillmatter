# Ticket 34 — Canonical rename and draft recovery

Scope: `.scratch/meeting-ai/issues/34-extend-canonical-rename-to-all-new-references.md`, spec R4/R10/R14 and ADR 0001. Blockers 08, 16 and 33 were resolved before work. Review and coverage baseline: `b59676ae37a7ad4043e24e24763387fdb1d05b52`.

## Delivered behavior

The existing Rename entry and its explicit confirm/cancel warning remain. Failed rename attempts now retain the entered title for the same selected Meeting and workspace. Cancel discards that draft; success clears it. Failure feedback appears immediately. A collision or changed doorway explains that the user should review the current Meeting, choose an unused title and retry. If external changes refresh the Meeting while the warning is open, confirmation preserves the draft, reports the conflict and leaves the externally edited files intact. A different workspace or Meeting cannot receive an expired confirmation. Successful rename results can follow selection to the exact new canonical reference even when read-model invalidation precedes the mutation callback; this does not apply stale content. External title edits never stand in for a successful rename result.

The existing canonical transaction already rewrites workspace Markdown and decoded JSON artifacts, Inbox references, durable inactive Job manifests, search, Recording Bundle and track metadata without leaving an alias. This ticket preserves that transaction and extends its behavioral verification to the newer canonical artifacts and note-authored Todo identities. It introduces no second naming workflow or item copies.

## Behavioral verification

- Artifact integration checks note-authored tasks, generated Action Items, canonical artifact paths, unchanged identities and Todo projections after rename and reopening the public service. Extraction references resolve at the new doorway.
- Existing management tests cover escaped JSON/transcript/extraction references, inactive Jobs/Inbox migration, active-work rejection, collision/stale doorway rejection, search refresh, one canonical doorway, repeated reprocessing and exact Recording Bundle authorization.
- A new injected-filesystem test fails each directory-operation boundary in turn, including snapshot preparation, writes' parent-directory preparation, canonical move and external-reference preparation. Every failure leaves original file bytes and the old canonical doorway readable after reopening.
- A new late index failure checks restoration of Recording Bundle bytes, canonical notes, Todo IDs and playback. Existing tests cover operational Job/Inbox rollback with both shared and separate SQLite databases.
- A new stale Recording Bundle test rejects rename without changing bundle/doorway bytes. Existing alias tests prove an old symlink cannot authorize playback.
- Hosted native controls check collision feedback, retained input, cancel, retry success and rejection after workspace replacement.
- Main-app native interaction checks the warning, Return confirmation, invalid-title failure, retained input, Escape cancellation, external edits during the open alert, visible conflict feedback, retained conflicting title, unchanged external file, external adoption of the draft title without false success or draft loss, retry success, visible success feedback, Listing refresh, no old doorway and relaunch persistence.

All added tests use disposable roots. The late-failure test keeps support snapshots outside its workspace so they cannot be mistaken for a second canonical checkbox. Hosted fixtures wire real read-model invalidation and explicitly select the Meeting being renamed.

## Executed verification

All final lanes pass against the same shipping source through `b0212ba`. Early failed or superseded runs do not contribute to the final gate.

| Lane | Result | Evidence |
| --- | --- | --- |
| Full Release package | 547 tests; five existing opt-in skips; zero failures | `/private/tmp/ticket34-package4/{execution.json,tests.log,report.json}` |
| Focused Release hosted | Four tests; zero skips/failures | `/private/tmp/ticket34-hosted6/{execution.json,tests.log,results.xcresult,report.json}` |
| Focused Release main-app native | One test; zero skips/failures | `/private/tmp/ticket34-native5/{execution.json,tests.log,results.xcresult,report.json}` |

The five skips are the existing real echo fixture, external Recording Bundle replay, operational fixture seeder, configured-workspace playback replay and live ChatGPT quality lane. No ticket 34 test is skipped.

The standard complete-source report command exits **0**: **45 / 45 = 100% changed executable-line coverage**, exceeding the required 95%. Every shipped source has an executable-line map. Compatible lanes merge by source location without double counting. No threshold, policy exclusion, shipping flags or source inventory changed.

| Changed module | Covered / executable | Coverage |
| --- | ---: | ---: |
| Presentation | 12 / 12 | 100% |
| App/UI/platform | 33 / 33 | 100% |
| Combined | **45 / 45** | **100%** |

Existing whole-source debt in this focused-lane union is **18,199 / 26,114 = 69.69%**: Core 94.26%, Presentation 82.98%, runtime 94.24%, app/UI/platform 45.24%. This does not pass or claim ticket 50's independent whole-source 95% requirement. Full native regression execution remains outside this single-ticket run.

The initial hosted regression failed because the dialog restored the original title instead of the entered title. A later native regression reproduced the external-refresh conflict before its fix. Other failed runs exposed missing immediate error rendering, a test API/access mistake, missing fixture read-model invalidation, support snapshots incorrectly placed inside a test workspace, and implicit selection of the collision destination. These were corrected. A complete-source gate also correctly rejected 31/33 = 93.94% changed-line coverage: the two uncovered lines exposed a success callback suppressed by canonical-path selection refresh. The final exact-result completion fix addresses that behavior rather than weakening the gate. The partial UI-only coverage attempt also correctly rejected two missing source maps; only the complete final lane union is used below. A superseded package run during concurrent compilation timed out in the existing two-second transcription-to-summary handoff test; no threshold or timeout was changed. Earlier complete package runs passed, and the final complete run below is the resolution evidence.

Commands use the existing temporary cache wrapper around the repository collector; fresh output directories and profiles prevent stale coverage reuse:

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py package /private/tmp/ticket34-package4 /private/tmp/ticket27-package-cache
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py hosted /private/tmp/ticket34-hosted6 /private/tmp/ticket27-hosted-cache StillmatterHostedTests/MeetingCalendarHostedTests
CLANG_MODULE_CACHE_PATH=/private/tmp/stillmatter-clang-module-cache python3 /private/tmp/run-ticket27-coverage.py native /private/tmp/ticket34-native5 /private/tmp/ticket27-native-cache StillmatterUITests/StillmatterFlowsUITests/testRenameFailureRetainsTitleKeyboardCancelSuccessAndRelaunch
python3 scripts/coverage.py report --reports /private/tmp/ticket34-package4/report.json /private/tmp/ticket34-hosted6/report.json /private/tmp/ticket34-native5/report.json --base b59676ae37a7ad4043e24e24763387fdb1d05b52 --output /private/tmp/ticket34-final-gate.json
```

Without the cache wrapper, use `scripts/run-coverage.py package|hosted|native --output <fresh-directory>`, with the same Xcode `--only-testing` filters. Focused tests also ran through `swift test --configuration release --enable-code-coverage -Xswiftc -Onone --filter <test>` for artifact identity and filesystem/media rollback.

SwiftPM and Xcode builds supply typechecking. Graphite structural validation and `git diff --check` pass. Presentation validation reports the unchanged `TranscriptReaderView.swift:438` baseline visual-literal issue already recorded by tickets 30, 32 and 33; this ticket does not edit that file.

## Standards

Independent fresh-context review through `b0212ba`: no actionable documented-standard breaches or baseline smells. The reviewer checked domain/rename ADRs, UI design/profile and testing rules. The final review includes explicit fixture selection, canonical completion following, and the adversarial external-title regression.

## Spec

Independent fresh-context review initially found loss of the entered title after an external refresh during the alert. That finding was fixed and reproduced by a native regression. A subsequent coverage-driven success fix initially inferred completion from matching file state; review caught the false-success possibility when an external edit adopts the draft title. That heuristic was removed. Final review through `b0212ba`: no remaining implementation findings or scope creep; final execution and coverage are accounted for separately here.

Review totals: Standards 0; Spec 0. Neither axis has a remaining worst issue.

## Capability limits

Links copied outside Stillmatter cannot be rewritten; the existing warning explicitly says they may break. No alias is created to conceal this limitation. This ticket does not change capture, model, calendar-provider or real-hardware capabilities, and makes no new quality claims for them. Whole-source release coverage remains the separate ticket 50 gate; focused native execution is not a full native regression run.
