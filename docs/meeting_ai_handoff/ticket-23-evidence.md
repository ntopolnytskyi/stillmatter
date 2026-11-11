# Ticket 23 — Transcript speaker correction

Ticket: `.scratch/meeting-ai/issues/23-correct-transcript-speaker-identities-repeatedly.md`.
Review and incremental coverage baseline: `534c6c5e7a0a3a598e2e132695bf2cdae875c4b4`.
Scope: ticket 23 only. Dependencies 21 and 22 were resolved before implementation. The user approved the correction/persistence and native UI test boundaries and this baseline.

## Behavior and authority

Transcript speech rows expose **Correct speaker…**, opening a native sheet built from shared Graphite Focus controls. A user can enter a name, audition retained evidence through the existing player, Apply with Return, or Cancel with Escape. The sheet remains usable at the 720 × 520 minimum window size. Errors preserve the draft and current focus, use the shared destructive status presentation, and announce the result. Saving disables competing edits until completion. Returning from Apply/Cancel restores focus to the source control. Active speaker filters keep the selected sources visible across partial and repeated renames; reused IDs with different timing do not transfer selection.

Manual identity is separate from the source track, spoken text, timing and generated cluster number. A saved correction records its source track and exact source intervals in the existing Meeting artifact manifest. A uniquely supported acoustic speaker group updates together; without unique acoustic evidence, correction is limited to the selected source. Spoken text, source IDs, source timing, retained audio, approved Action Item ownership/content/state and My Notes are not rewritten by naming. No processing Job is enqueued by correction.

The manifest and Transcript JSON/text pair share an identity revision. Current valid external Transcript label edits advance the manual choice; output without the current revision cannot replace it. JSON/text synchronization preserves unknown metadata and spoken-text edits. Changed segment IDs/labels can retain the identity when their source timing still matches uniquely. Changed or duplicated timing preserves the saved name/source for review, without guessing a new identity. Review feedback includes the saved name, track and interval. An editor retains its original operation and source precondition; externally replacing an ID's evidence or changing its name causes Apply to fail without naming the replacement.

A correction marks analysis outdated. The notice offers explicit Reprocess through the existing confirmation flow; canceling does not enqueue work. Successful explicit analysis records the identity revision it consumed and clears the outdated flag. Analysis based on an earlier manual revision is rejected. Source ambiguity remains visible independently of the analysis flag.

## Compatibility and limits

Existing manifests have no new required keys and keep their prior behavior. The existing durable artifact publication/recovery mechanism publishes the new manifest fields and synchronized Transcript pair; source references do not depend on the Meeting folder name or generated speaker labels. Synthetic fixtures isolate workspace, support, media and preference namespaces.

This slice supports free-form historical display names. It does not claim a working Person directory, Voice Profile enrollment, recognition quality, or range/word alignment where evidence is ambiguous. Person-owned voice learning remains ticket 24; individual Action Item owner editing remains ticket 26; attribution-range adjustment/splitting remains ticket 49. Ticket 20's deferred real speaker/quiet-reply quality evaluation remains unchanged. No test with synthetic audio or a fake worker establishes model quality or application-audio isolation.

## Verification

Final full Release package: **474 tests, four existing opt-in skips, zero failures**. Final full hosted integration: **55 tests, zero skips/failures**. Final focused main-app native acceptance: **4/4 tests, zero skips/failures**. The 95% changed-line gate passed with **311/317 executable lines (98.1072555205%)**, exit **0**, against the approved baseline. Red/green evidence includes missing correction API, acoustic group propagation, external edit authority, duplicate-timing safety, original-source preconditions, explicit analysis refresh, and native audition playback. Preliminary native execution exposed an inaccessible inline editor at minimum window size; the native sheet replaces that implementation.

Final evidence roots are `/private/tmp/stillmatter-23-package-complete/`, `/private/tmp/stillmatter-23-hosted-complete/`, and `/private/tmp/stillmatter-23-native-complete/`, with logs, explicit execution status, profiles, normalized reports and native result bundles. No preliminary failed run is used as passing coverage evidence. The final collectors incrementally rebuild the current shipping source, archive all earlier profiles before execution, and export only fresh profiles from successful runs. Its `collection.py` records the exact collection procedure and validates the source inventory before and after execution.

## Review

Independent fresh Standards and Spec agents reviewed `git diff 534c6c5e7a0a3a598e2e132695bf2cdae875c4b4...HEAD`. The first review found focus/error semantics, repeated review-state derivation, premature formatting of source evidence, a stale editor source precondition, and ambiguous timing assignment. All were fixed and regression tests added. Both reviewers confirmed **zero remaining findings** through final production commit `75bdbe7`, including the final active-speaker-filter correction. Final verification is complete; both reviewers report zero remaining findings on the final source.

## Coverage and resolution

The final gate requires complete shipped-source executable maps and merges compatible reports by source location without double counting. No threshold, policy exclusion, compilation flag or shipped-source exemption was changed.

| Module | Changed lines covered / executable | Coverage |
| --- | ---: | ---: |
| Core | 128 / 130 | 98.46% |
| Presentation | 17 / 17 | 100% |
| App/UI | 166 / 170 | 97.65% |
| Combined | **311 / 317** | **98.1072555205%** |

Gate report: `/private/tmp/stillmatter-23-incremental-gate.json`.

Whole-source measured coverage is **19,429/23,800 (81.63%)**: Core 9,671/10,281; Presentation 1,282/1,477; runtime 327/347; app/UI 8,149/11,695. This is existing whole-source debt for ticket 50, whose final 95% requirement remains unchanged. Ticket 23's incremental gate is satisfied; this is not a claim of whole-app completion.

The native scenarios assert repeated renaming and reopen persistence, stable saved source identity/text/timing, active speaker filters, grouped labels, Return/Escape editing, validation and stale-source failures with retained drafts, canceled Reprocess confirmation, the minimum window size, actual generated-audio audition after capture-gap mapping, and unavailable/empty evidence. All ticket 23 feature tests ran. The four package skips are existing opt-in fixture checks; no new feature test was skipped.

Final collection commands are recorded in each `execution.json`, with `collection.py`, fresh retained profiles, LCOV, normalized coverage, logs and native result bundles. The full package and hosted suites were repeated after the last production change. `git diff --check` passed. Production is committed through `75bdbe7`; all work concerns ticket 23.

Standards: **0 remaining findings**. Spec: **0 remaining findings**. Worst remaining issue on either axis: none. Ticket 23 is resolved.
