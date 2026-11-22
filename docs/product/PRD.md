# Stillmatter product requirements

Status: working product baseline, consolidated 2026-11-22. This document combines current documented behavior with explicitly agreed changes; it is not a claim of release acceptance or implementation completeness. Meeting Tab Content definitions remain in progress.

## Purpose

Stillmatter is a private work log connecting recorded conversations, evidence and personal tasks. The user can capture a conversation, understand it later, review commitments and work on personal tasks without losing their source context.

## Authority and scope

Use current documented behavior when historical specs or PRDs disagree. Apply the user's newer explicit decisions, including the amendments below. Archived requirements are historical evidence, not additional scope. An archived requirement does not become active merely because it has not yet been implemented.

- [CONTEXT.md](../../CONTEXT.md) owns business meanings and UI vocabulary.
- This PRD owns consolidated product direction. [Meeting feature documentation](MEETING_FEATURE.md) distinguishes the implementation baseline from agreed Tab Content requirements.
- [UI principles](../UI_PRINCIPALS.md) own shared visual and interaction rules.
- [ADRs](../adr/) retain decision rationale and constraints. This consolidation does not overturn them.
- The [implementation specification](../../.scratch/meeting-ai/spec.md) and tickets retain delivery details and evidence. Their older wording must be interpreted with the current baseline and explicit amendments here.
- [Future Todo work](../planned/INDEX.md) remains planned. Its cross-feature conflicts are unresolved until explicitly decided; this PRD does not choose a new identity or synchronization model.

## Application structure

The Top Bar spans the Sidebar and Application Area and contains recording status and Search. The Sidebar is icon-only, with Settings and the Application Icon anchored at the bottom. Current destinations remain Today, Recording, Meetings, Tasks and Settings; this consolidation does not rename Today to Inbox or Tasks to Todo.

Each function defines its Listing and Workbench where appropriate. A Listing Item can represent an individual record or a group. The optional Listing Bar searches and filters only its Listing. Multiple selection is supported where the feature calls for it, not automatically in every Listing.

Future Todo navigation can select Today, Tomorrow, Important and project groups, with their tasks shown in the Workbench. Grouped Settings navigation can similarly select groups of settings; neither example establishes that the layout is implemented.

Markdown is rendered for reading throughout the application. Editing shows plain Markdown source. This is an agreed shared requirement, not a claim that every current screen has been verified against it.

## Recording and processing

- Recording owns the active Capture Session, source selection, Preflight, elapsed time, track health, Start/Stop and live My Notes.
- One Capture Session is active at a time. A new capture can start while a previous Meeting is processing.
- Microphone and system audio remain distinct sources. Show reduced capture truthfully and never silently widen the recording scope after permission or source failure.
- Manual import preserves the user's original file and enters the ordinary Meeting processing flow.
- Transcription is local. Auto is the default language policy. Settings offers Turbo, Medium, Small and retained Full support; Turbo is the default choice.
- ChatGPT analysis through Pi requires persistent Settings permission, off by default. It transfers Transcript and My Notes, not original audio, Voice Profiles or search data.
- Complete Meeting workflows run sequentially while capture remains independent. Jobs expose stages, failure and Retry; closing the window does not stop background work, while Quit stops execution and relaunch recovers durable work.
- Retry resumes failed work; confirmed Reprocess regenerates with current settings, protecting My Notes and approved/user-authored work as described in the feature baseline.

## Meetings

The Listing represents individual Meetings. Items can show title, recording start time, duration and status. Selection opens the Meeting Workbench: Info Bar, Tabs, then the selected Tab Content.

The five Tabs are Summary, Action Items, Open Items, My Notes and Transcript. The agreed Summary and Action Items details are authoritative in [Agreed Tab Content definitions](MEETING_FEATURE.md#agreed-tab-content-definitions).

- **Summary:** generated Summary text, personal and other Action Item previews, and the full Decisions section. Summary text is rendered Markdown with Edit and Copy. There is no separate Decisions Tab and no player here.
- **Action Items:** a vertical list with source navigation and Accept, Reject, Edit and Copy actions. Pending approval has separate **Accept all mine** and **Accept all others** buttons; each targets its pending owner group, excluding unknown owners.
- **Open Items:** retain the current questions/issues, editing, resolution and source-navigation baseline pending further Tab Content definition.
- **My Notes:** retain the separate user-authored Markdown file and its editing/reading behavior pending further Tab Content definition.
- **Transcript:** retain timed speech, source navigation, search/filter/read modes, Speaker naming and audio playback pending further Tab Content definition. Transcript speech remains read-only in-app.

Only Action Items require approval. Decisions and Open Items do not. Accepting the user's Action Item exposes the corresponding Todo Item with Open status and the same canonical identity. Accepting another person's item does not create a personal Todo Item. Approval and completion are separate.

Source references open Transcript at the relevant speech and position the player at retained audio. Unavailable sources are identified honestly. Raw segment markers do not appear in reader-facing Summary text; internal evidence checks and structured outcome references remain available.

Recording and Processing Meetings retain their Listing state without exposing incomplete content. Failed processing provides an explanation and Retry/setup guidance. Completed processing can still require Action Item approval; Ready does not mean every task is complete.

## Personal work and search

The current Today overview combines attention/review reminders, a personal Queue preview and upcoming Meetings. Pending Action Items remain in their Meeting, with one review reminder per Meeting. Tasks currently exposes Queue, Done, Blocked and Overdue views.

Future Todo Today planning, priorities, project groups and storage changes remain governed by the planned baseline and its integration review. Do not treat that redesign as an immediate requirement to replace working Tasks behavior.

Global Search, Listing search and Transcript find have distinct scopes. Current keyword search can be supplemented by local semantic suggestions. Semantic limitations must remain visible; search does not upload content.

## Files, identity and lifecycle

Valid Workspace file edits remain authoritative. In-app editing must handle newer external content without silently overwriting it. Personal Action Items retain one canonical identity across Meeting and Todo views; note-authored tasks remain canonical in My Notes.

Rename updates controlled references without old-path aliases and warns that external links may break. Active Jobs prevent rename.

Archive is explicit and requires stopped, Ready processing with no active Jobs and no pending or unfinished Action Items for any owner. Archived Meetings are excluded by default, remain explicitly browsable and retain available reading/playback. Current in-app restore and editing are unavailable.

Current Remove moves the Meeting folder to Trash and removes operational/search references while retaining external recording files and accepted Todos as documented in the feature baseline. It is not comprehensive permanent deletion.

## Deferred scope and constraints

Person-owned learned Voice Profiles, inspectable revision history, configurable retention cleanup, comprehensive permanent deletion, export and read-only CLI remain deferred. Preserve the existing backlog and ADR constraints; consolidation does not implement, cancel or promote that work into the current baseline. Manual transcript interval splitting/boundary correction also remains tracked.

Consequential constraints remain in:

- [ADR-0001](../adr/0001-rename-meetings-without-path-aliases.md): canonical rename without aliases.
- [ADR-0002](../adr/0002-file-authority-and-shared-action-item-identity.md): file authority and shared Action Item identity.
- [ADR-0003](../adr/0003-people-own-independent-voice-profiles.md): deferred Person-owned Voice Profiles.
- [ADR-0004](../adr/0004-serial-meeting-workflows-with-independent-capture.md): serialized workflows with independent capture.

## Acceptance and remaining definition

Acceptance must check observable behavior, file identity, preservation of user work, state/error handling and source navigation. Real-device capture, permissions and model quality need the separate [manual validation](../development/manual-validation.md) lane. Documentation and structural checks alone do not establish conformance.

Continue defining the Info Bar and the Open Items, My Notes and Transcript Tab Content. Track implementation differences against agreed requirements explicitly; do not present new controls as shipped solely because they appear in this PRD. Resolve future Todo integration conflicts before adopting linked records or changing ADR-0002.
