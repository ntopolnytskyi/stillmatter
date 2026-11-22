# Meeting feature

Status: current implementation baseline, reviewed against source and existing tests on 2026-11-21. Real-device capture, permissions and model quality require the separate [manual validation](../development/manual-validation.md) lane. Terms follow [CONTEXT.md](../../CONTEXT.md); shared UI rules live in [UI_PRINCIPALS.md](../UI_PRINCIPALS.md).

## Capture and import

Recording owns the active Capture Session: source selection, Preflight findings, elapsed time, track health, Start/Stop and live My Notes. Capture is separate from processing; a new recording can start while an earlier Meeting is processing. One Capture Session is active at a time.

Preflight reports Ready, Degraded or Blocked. Blocked findings prevent capture; Degraded findings explain the reduced mode and corrective action. Microphone access is required; denied system-audio access can permit explicitly disclosed microphone-only capture. Calendar access is optional. Permission failures do not authorize silently switching to all-system audio.

Teams capture targets the application audio path; Zoom and Google Meet use the disclosed all-system path, not individual browser-tab capture. Source isolation and permission behavior depend on macOS and require hardware validation. Microphone and system audio are separate synchronized tracks when both are available. Track provenance, Speaker identity and task ownership are separate facts.

Teams detection observes evidence of a possible native Teams call. A **Teams Detection Signal** is an observation, not recording permission. Ask, Automatic and Manual recording policies control the response; uncertain detection is not proof that a call ended.

Import accepts readable WAV, AIFF/AIF, CAF, MP3, M4A, AAC, MP4 and MOV media with audio. It preserves a private copy of the original, extracts usable audio and creates an ordinary Meeting processing Job. Imported mixed audio does not identify the microphone owner or imply that the user spoke every line. Interrupted preparation is recoverable and scoped to its Workspace.

### Recording evidence and derivatives

The glossary uses **Recording Bundle** for the complete Meeting file set, with an agreed layout of one folder under the parent media folder. Current storage does not yet consistently implement that layout: media and Workspace Markdown can live separately. The existing `RecordingBundle` code type is narrower: a capture manifest containing validated audio references, timing, integrity information and diagnostics handed to processing. Its ready, degraded and partial states describe available recording evidence, not whether the Meeting's analysis has finished. The business definition does not establish that storage consolidation has been implemented.

A **Transcription Audio Sidecar** is a replaceable derivative used to improve transcription while preserving original recording evidence. Playback, recovery and reprocessing distinguish original audio from derivatives; a failed derivative does not authorize deleting original evidence.

## Processing and data transfer

The AI Meeting Workflow processes transcription and analysis in order. Acoustic operations such as diarization run within the transcription machinery; each operation is not necessarily a separate persisted Job stage. Complete Meeting workflows are serialized while capture remains independent, as explained in [ADR-0004](../adr/0004-serial-meeting-workflows-with-independent-capture.md).

- Transcription runs locally, supports mixed Ukrainian/English speech and defaults to Auto. English/Ukrainian overrides are available through confirmed reprocessing.
- Analysis currently uses ChatGPT through the installed Pi sign-in. Settings exposes **Allow ChatGPT analysis of Meeting text**, off by default for new and migrated settings. Enabling it persists permission for future analysis; it is not a per-Meeting confirmation.
- That analysis path sends the Transcript and My Notes. It does not send original audio, Voice Profiles or search data. Pi runs with ambient tools/context disabled; only the scoped input is supplied.
- Disabling permission prevents future transfers and publication from a revoked run. It cannot retract a request already sent. When disabled, analysis explains the required permission and retains the recording and Transcript. There is no supported local grounded-analysis fallback.
- Generated Summary and outcomes are validated against original Transcript evidence before publication. Invalid, partial, stale or canceled output cannot be presented as a successfully completed Meeting. User-authored language and source speech are retained; generated narrative/outcomes are English.

A **Job** is a container for background processing. Time-consuming actions, including actions that depend on earlier work completing, are organized as Jobs or ordered Job stages. For example, a Meeting processing Job transcribes audio before its analysis stage can use the Transcript.

Jobs expose stages, errors and retry state. A stage gets two automatic attempts total, then fails so other eligible work can continue. Manual Retry resumes failed work using valid checkpoints. Reprocess is a separate, confirmed operation using current settings. Jobs continue with the window closed; Quit stops execution and relaunch recovers durable work.

Current analysis is bounded: whole-segment parts up to 24 KiB, My Notes up to 24 KiB, at most 256 parts and eight new requests per attempt. Each complete serialized provider prompt and each returned Summary/extraction artifact must fit 128 KiB. Dense evidence can exceed final synthesis capacity even after part processing. The stage then fails explicitly rather than truncating evidence; Retry alone cannot fix an unchanged capacity limit.

## Meeting workspace and UI

Meetings uses a Listing and Workbench. The Meeting Workbench is arranged vertically: Info Bar, Tabs, then the selected Tab Content. These terms are defined in [CONTEXT.md](../../CONTEXT.md#meeting-workbench). The five Tabs are, in order:

| Tab | Current responsibility |
|---|---|
| Summary | Editable Summary narrative, personal and other Action Items, and the full Decisions section; no audio player |
| Action Items | All owners' items, review, text/owner/due/tag editing, completion and evidence navigation; approve mine/others in batches where eligible |
| Open Items | Questions and issues, supported owner/source information, editing and resolution |
| My Notes | Source/preview of the separate user-authored Markdown file |
| Transcript | Timed speech, search/filter/read modes, Speaker naming, evidence navigation and retained audio playback |

There is no separate Decisions tab. The Transcript player belongs to Transcript, not a shared pinned player on every tab. Global Search, Listing filters and in-Transcript find have distinct scopes.

Recording and Processing Meetings keep their visible row/state but do not expose a partially completed content workspace. Failed processing explains the error and offers setup/Retry. Needs-attention presentation includes pending Action Item review; Ready processing does not imply all approved tasks are complete. Archive is a separate lifecycle condition.

Meeting management uses one More menu with eligibility explanations. Editors expose local edit/save/cancel behavior; valid external file changes remain authoritative. Conflicting edits must not silently overwrite newer content. Archived content preserves reading, evidence navigation and retained playback while mutating controls are unavailable.

### Agreed Tab Content definitions

The following defines the agreed Summary and Action Items experience. It records product requirements; this documentation update does not change the implementation or establish that every control is already implemented. The table above remains the current implementation baseline.

**Summary Tab Content** contains, in order, the AI-generated Summary, personal and other Action Item previews, and the full Decisions section. There is no separate Decisions Tab or audio player here. The Summary is shown as Rendered Markdown. The user can edit the Summary in a Markdown Editor and copy its text. Reading text is clean and understandable, without raw Transcript segment markers.

**Action Items Tab Content** contains a vertical list of Action Items, ordered from top to bottom. Each item provides:

- A source-reference link that opens the Transcript Tab at the referenced speech and positions the audio player at the corresponding audio, when the source is retained.
- **Accept** and **Reject** actions for pending approval.
- **Edit** to edit the item and **Copy** to copy its text.

The Tab Content provides two buttons: **Accept all mine** and **Accept all others**. Each accepts only the pending Action Items in its owner group for the selected Meeting. Unknown owners must be assigned before approval; neither button approves them. Repeated approval must not create duplicate Todo Items.

When the user accepts an Action Item assigned to them, its corresponding Todo Item becomes available with **Open** status. The Action Item and Todo Item retain the same canonical identity, rather than creating independent copies, consistent with [ADR-0002](../adr/0002-file-authority-and-shared-action-item-identity.md). Accepting an item assigned to someone else does not create a personal Todo Item. Approval is separate from completion; accepting an item does not mark it complete.

## Transcript, evidence and Speakers

The Transcript has timed, attributed segments and plain-text/structured representations kept consistent by the canonical codec. In-app speech text is read-only. Citations connect generated outcomes and manual source-linked items to specific Transcript evidence and bounded playback positions.

Decisions, Action Items and Open Items with Citations expose timestamped source controls. Selecting one opens the cited Transcript location and seeks retained audio when a valid playback position is available. Up to two sources appear as individual buttons; additional references use a Sources menu. An unavailable reference is disabled and labeled "Source no longer retained." Items without Citations do not show source controls.

Speaker naming corrects attribution for selected transcript speech, persists correction evidence and can mark generated analysis outdated. It does not assign ownership of individual Action Items. Current naming controls do not establish support for manually splitting intervals or editing their boundaries; that work remains tracked. A named Speaker is not an independently managed Person or learned Voice Profile.

## Action Items, Approval and My Notes

Only Action Items require approval; Decisions and Open Items do not. Generated Action Items begin pending approval regardless of owner. Unknown owners require assignment before approval. Personal approved items appear in the Queue as the same canonical item; other people's approved items stay Meeting-only. Approval and completion are separate states.

Pending individual items remain in their Meeting. The Today overview shows one Meeting review reminder with its pending count, not one Inbox row per Action Item. The reminder disappears when review is complete. This differs from future ToDo Needs Approval behavior, which remains planned.

Personal Action Items retain identity and state across Meeting and Todo views. Editing or completing one writes to its canonical checkbox rather than synchronizing independent task copies. Note-authored checkboxes remain canonical in My Notes; generated items remain canonical in their Meeting artifact. See [ADR-0002](../adr/0002-file-authority-and-shared-action-item-identity.md).

My Notes is separate Markdown, available during recording with autosave/draft recovery and later through its tab. A saved note-authored checkbox is already approved and defaults to the user. Removing that checkbox removes its task projection. AI may read notes and add ordinary tags, but cannot rewrite notes, task text, ownership, approval or completion. Regeneration suppresses duplicate extraction of already represented tasks.

Tags are currently ordinary reusable inline labels, with app-managed `ai-gen` and `need-approve` markers. AI tag updates are additive. Special Project tags belong to the future ToDo design; existing Meeting `project:` metadata/filtering is older functionality, not proof of that task-grouping capability.

## Today overview, Queue and Search

**Today Review** names the daily process of reviewing attention items, personal tasks and upcoming meetings. The current Today screen supports that process; the glossary term describes the process rather than the page.

The Today overview combines Inbox Required/Review/Attention groups, a preview of the first five unfinished Queue tasks and upcoming calendar meetings. Queue order currently expresses priority. Tasks exposes Queue, Done, Blocked and Overdue views; task states include open, done, blocked and canceled. Today planning using `+today` and explicit P1/P2/P3 sorting are future ToDo behavior.

The app's Search results combine keyword matches with optional local semantic suggestions over permitted Transcript, Summary, notes and outcomes. Semantic retrieval supplements the same Search interface; it is not a separate destination. Keyword matches appear first, followed by up to 20 similarity suggestions, which may be unrelated. Search does not upload content. Exclusions and archive visibility apply across canonical representations.

Missing or failed optional semantic components leave keyword search available with a visible limitation. Semantic search setup is developer-only and is not part of the current app-user installation flow.

The current model has known Ukrainian/English retrieval misses and no calibrated relevance cutoff. Large libraries can be slow because vectors are recomputed per query.

## Reprocessing, calendar and rename

Retry resumes failed processing; confirmed Reprocess regenerates generated content with current settings. Its warning explains that generated edits can be replaced without inspectable revision history. Approved/user-authored items, their completion state, retained rejections and My Notes remain protected; prior working artifacts remain recoverable until successful publication. Archived Meetings cannot reprocess.

Calendar association records event context and respects manually chosen titles. Explicit title reset is distinct from merely changing event association. Rename updates controlled Workspace and stored references without leaving an old-path alias; external links may break. Active Jobs block rename. [ADR-0001](../adr/0001-rename-meetings-without-path-aliases.md) explains the tradeoff.

## Archive and removal

Archive is explicit and requires a stopped, Ready Meeting without queued/running Jobs and without pending or unfinished Action Items for any owner. Completed items and explicitly rejected/dismissed proposals do not block it. Finishing the last item does not automatically archive the Meeting.

Archived Meetings are excluded from default browsing/search, remain explicitly browsable and retain artifacts, links and available playback. In-app edit, rename, reprocess and restore controls are unavailable. Valid external file edits remain authoritative; Archive is not a filesystem lock.

The existing Remove command moves the Meeting folder to macOS Trash, deletes processing history/Inbox entries and removes controlled search references. Its warning states that external recording files and already accepted Todos are retained. It does not promise comprehensive permanent deletion of all owned media/tasks, configurable retention cleanup or export. Removing an imported Meeting does not delete the user's original input file.

## Planned capabilities and unresolved decisions

Summary text is clean prose or readable bullets without raw `[segment-…]` markers. Generation uses citations internally for evidence validation and multi-part reconciliation; publication removes those markers from Summary Markdown. Existing summaries are also presented without those markers. Structured outcome citations remain available through source controls on Decisions, Action Items and Open Items.

Person-owned learned voices, inspectable revision history, configurable post-archive cleanup, comprehensive permanent deletion, export and read-only CLI access remain future work. Manual transcript interval splitting/boundary correction also remains tracked. Current docs do not claim these capabilities from their presence in a spec or ADR. [ADR-0003](../adr/0003-people-own-independent-voice-profiles.md) constrains the deferred voice design.

The [future ToDo integration review](../planned/TODO_INTEGRATION_REVIEW.md) records unresolved changes to identity, approval, storage, tags and lifecycle rules. Until reviewed and implemented, current Meeting behavior remains as documented above.

## Verification map

These are source and existing test entry points, not claims that tests were rerun for this documentation change.

| Area | Source / behavioral tests |
|---|---|
| Capture and evidence | [Preflight](../../Sources/StillmatterCore/AudioCapturePreflight.swift), [Recording Bundle](../../Sources/StillmatterCore/RecordingBundle.swift), [bundle tests](../../Tests/StillmatterTests/RecordingBundleTests.swift) |
| Processing and permission | [Meeting workflow](../../Sources/StillmatterCore/MeetingWorkflow.swift), [analysis setup](../../Sources/Stillmatter/App/Runtime/ProcessingRuntime.swift), [Settings](../../Sources/StillmatterCore/AppSettings.swift), [AI worker](../../Sources/StillmatterCore/PiCodexWorker.swift) |
| Five-tab workspace | [Meeting state](../../Sources/StillmatterPresentation/Features/Meetings/MeetingFeatureState.swift), [native view](../../Sources/Stillmatter/Features/Meetings/MeetingManagementView.swift) |
| Identity and approval | [action review tests](../../Tests/StillmatterTests/MeetingActionReviewTests.swift), [note task tests](../../Tests/StillmatterTests/MeetingNoteTodoBridgeTests.swift) |
| Outcomes and attribution | [outcome editing tests](../../Tests/StillmatterTests/MeetingOutcomeEditingTests.swift), [speaker correction tests](../../Tests/StillmatterTests/MeetingSpeakerCorrectionTests.swift) |
| Import | [import tests](../../Tests/StillmatterTests/MeetingImportTests.swift) |
| Archive, removal and rename | [management service](../../Sources/StillmatterCore/MeetingManagement.swift), [management tests](../../Tests/StillmatterTests/MeetingManagementTests.swift) |
| Today integration | [dashboard loader](../../Sources/StillmatterCore/TodayDashboard.swift), [task views](../../Sources/StillmatterCore/TodoItems.swift) |
