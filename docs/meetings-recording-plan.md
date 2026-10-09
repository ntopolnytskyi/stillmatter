# Recording and Meetings split

## Goal

Recording manages the current Capture Session. Meetings manages every Meeting and its artifacts, including Meetings still processing while a later Capture Session is active. Ended capture clears Recording for reuse immediately; Transcription and Summary Jobs continue independently and appear in the corresponding Meeting detail.

## Product behavior

### Recording

- Add a Recording area and move the current Meetings capture interface there: capture controls, live notes, capture preflight/diagnostics, and current-session status.
- Preserve the global recording and Job indicators. Do not make Recording depend on older Meetings' processing work.
- A live Meeting is also discoverable in Meetings; its detail links back to Recording for capture controls.

### Meetings browser

- Adapt the Activities left-browser/right-detail shell pattern, including narrow-window navigation, scrolling, selection, empty/error states, and accessibility.
- Discover existing and newly created Meeting folders; display live, processing, failed, ready, and archived Meetings. Default to newest first, excluding archived Meetings.
- Search title and Meeting text; filter by date range, Project, processing state, and Archived. A **Not finished** filter groups Processing and Needs attention. The selected Meeting remains visible in the right-hand detail while its Jobs progress.
- Distinguish capture lifecycle from processing state: finished recording does not imply finished transcription/summary. **Ready** requires both Transcript and Summary; failures show **Needs attention**, not an indefinite running state.

### Meeting detail

- Show title, date, Project when known, human notes, Summary, Transcript reference, artifact/source-file links, processing stage/status/errors, and My/Other action items. Show the status and existing Inbox decisions for My action items; keep accept/merge/dismiss actions in the Inbox.
- Edit the title, human-written notes in `meeting.md`, and `summary.md` in-app. Protect generated processing/metadata sections from notes editing. Offer source-file opening for advanced use. Transcript editing is deferred.
- Represent missing Transcript/Summary, missing or partial audio, queued/running/failed Jobs, and live capture explicitly rather than hiding the Meeting.

### Audio and evidence

- Provide a single mixed microphone/system-audio player (microphone-only when no usable system track exists), with play/pause, a sampled waveform seek slider, elapsed/total time, and clear availability/degradation status. Sample without loading entire recordings; preserve native slider keyboard, focus, and accessibility behavior. Do not modify original audio evidence.
- Clicking a timestamped Transcript segment or a Summary/Action Item citation seeks the player to that approximate time; highlight the current segment where available. Approximate seeking is acceptable, but missing audio or timestamps must not masquerade as a functional jump.
- Playback speed and per-track mixer are deferred; waveform display is in scope for the selected Meeting's seek control.

### Per-Meeting processing

- Look up Jobs by Meeting/session identity, independent of the current Capture Session. Show each selected Meeting's Job stage and diagnostics.
- **Retry** a failed Job using its original settings. **Reprocess** starts a fresh Transcription → Summary chain from that Meeting's validated Recording Bundle. Its dialog selects a supported language and explicitly warns that the existing Transcript and Summary, including user edits, will be replaced. A fresh generation may run only when no Job for that Meeting is queued/running; Jobs for other Meetings are unaffected.
- Preserve accepted Todo Items and prior review decisions after reprocessing. Newly extracted My action items may create new Inbox proposals; identify old proposals no longer supported by the current Summary rather than silently treating them as current. Do not overwrite audio evidence.

### Management and retention

- Rename the Meeting title and canonical folder, updating Stillmatter-controlled workspace references and stored references. Do not leave an alias at the old path. Warn that links copied outside the workspace cannot be updated. Disable rename while that Meeting's Jobs are queued/running; avoid collisions and partially rewritten references.
- Archive hides a Meeting from the default list but preserves folder, audio, Jobs, and links; Archived filter exposes it and Restore returns it to the default list.
- Permanent deletion requires a separate confirmation describing both the Meeting folder and recording media outside the workspace. Block it during active Jobs. Keep accepted Todo Items, warning that their source links will become unavailable; do not silently remove unrelated linked content.

## Implementation slices and acceptance

1. **Area split and independent lifecycle:** new Recording navigation, Meetings shell and browser; stopping a capture immediately frees Recording while older Jobs remain attached to their Meetings. Test navigation, multiple simultaneous Meeting lifecycles, and narrow layout.
2. **Meeting read model and detail:** load existing Meeting folders and their artifacts; resolve per-Meeting Jobs and Inbox status; support selection, searching, filters, live/processing/failed/ready/archived and missing-artifact states. Test indexing, sorting, state transitions, and path resolution.
3. **Playback and timestamp navigation:** resolve Recording Bundle tracks safely, mix available tracks for playback, seek from Transcript segments and evidence citations. Test mic-only, mixed, partial/missing inputs, approximate timestamps, and playback selection changes.
4. **Editing and processing actions:** scoped edits with conflict handling; Retry and language-choice Reprocess with replacement warning, per-Meeting concurrency guard, and preserved Todo/review decisions. Test edits, validation failures, concurrent Jobs, regenerated proposals, and Summary replacement.
5. **Rename, archive, and delete:** reference-aware no-alias rename across Stillmatter-controlled stores; reversible archive and explicit permanent deletion of workspace and media assets. Test collisions, rollback/partial failure, blocked active Jobs, stale links, and retained accepted Todos.

## Decisions and constraints

- A Meeting is the existing domain container; Recording is a UI area for its current Capture Session, not another kind of Meeting. Processing status is separate from Capture Session state.
- Existing title review currently leaves a symlink alias after a folder move. The new rename requirement supersedes that behavior for the new management flow; reconcile title review and path-based Jobs/links before shipping.
- Existing Transcript regeneration is tied to the current capture snapshot and generated Summary publication replaces `summary.md`. Reprocessing old Meetings and protecting per-Meeting ownership require new orchestration, not just moving controls.
- Media may live outside the workspace root. Rename, playback, and deletion must reconcile workspace paths, external media paths, bundle metadata, operational SQLite references, and search indexing without guessing from folder names.
- Transcript editing belongs to a later phase; summary edits are saved normally but deliberately overwritten by confirmed Reprocess.
