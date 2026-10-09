# Stillmatter Domain Glossary

## Log Entry

The broad product-level record for something Stillmatter knows happened or was captured. Stillmatter is a personal log, so meetings, reports, decisions, activities, and other records connect back to the log over time.

## Meeting

A folder/container for a time-bounded conversation and its artifacts. A Meeting is not one canonical database object; it is represented by a meeting folder with `meeting.md` as the human-readable doorway and linked artifacts such as recordings, transcript files, summary content, manual notes, decisions, and action items. Teams Meetings are recorded automatically when possible, with manual force start/stop controls.

## Capture Session

The time-bounded act of creating and recording a Meeting. A Capture Session may be idle, detecting, starting, recording, stopping, finalizing, failed, or recovered. Starting makes the Meeting available immediately for live notes and manual action checkboxes; stopping preserves its artifacts for later processing.

## Capture Preflight

The fail-closed readiness check performed before a Capture Session starts. Capture Preflight verifies microphone permission and the selected input device, reports whether system audio is ready or operating in a known degraded mode, and checks that the recording media location is configured, writable, and has at least 1 GB available. Blocking findings prevent Meeting creation and carry an actionable Settings destination; degraded findings permit capture while naming the reduced mode.

## Teams Detection Signal

A read-only observation used to diagnose whether a native Microsoft Teams call is active. Stillmatter polls the native Teams process and traverses that process's macOS Accessibility tree for Teams' `hangup-button`; default microphone-device activity is shown as corroborating evidence but is not required for muted or listen-only calls. One conclusive process-plus-control sample starts the latched detection state, while three conclusive missing-control samples end it. Missing Accessibility permission, inconclusive scans, and Teams process restarts are unknown rather than evidence that a meeting ended. The signal monitor remains read-only; the recording policy uses its latched evidence to ask or auto-start according to Settings, and stops only captures it owns after a confirmed end. Manual force start/stop suppresses automation for that call. Unknown observations never end a latched call.

## Microphone Track

The user's independently recorded input audio for a Capture Session. While capture is active, Stillmatter writes linear PCM to a durable CAF recovery/preview artifact. A normal stop creates a compact AAC/M4A file alongside it; the recovery source is retained rather than replaced. A JSON metadata sidecar records artifact paths, duration, codec, sample rate, channel count, state, and diagnostics. On startup, unfinished metadata is detected and Stillmatter either finalizes the retained source or marks it partial with an actionable diagnostic—recovery never deletes source artifacts.

## System Audio Track

The independently recorded audio produced by meeting and other Mac applications during a Capture Session. It remains separate from the Microphone Track; when macOS support or permission is unavailable, the Capture Session is explicitly degraded to microphone-only rather than representing system audio as captured.

## Recording Bundle

The canonical, versioned JSON handoff from a finalized or recovered Capture Session to later processing Jobs. A Recording Bundle references the separate Microphone and System Audio Tracks, records their existence and SHA-256 hashes where files are available, preserves codec/sample-rate/channel/duration metadata and diagnostics, and identifies the best retained audio for each track. Its state is `ready`, `degraded`, or `partial`. Meeting artifacts reference the bundle, and downstream Jobs consume the validated bundle rather than assembling ad hoc audio paths.

## Transcription Audio Sidecar

A replaceable, transcription-only audio artifact derived from a validated Recording Bundle. Stillmatter may use the System Audio Track as a reference to reduce correlated speaker bleed from the Microphone Track, but selects the sidecar only when confidence, reference correlation, estimated echo reduction, and retained-signal quality pass policy. `transcription-audio-selection.json` records the selected source and diagnostics. If cancellation is unavailable or uncertain, transcription fails open to the original Microphone Track. Original recordings are immutable evidence and are never overwritten by sidecar generation.

## Transcript

A timestamped text representation of meeting audio. The post-meeting Transcription Job consumes a validated Recording Bundle, uses the selected echo-cancelled or original Microphone Track plus an available System Audio Track, and runs as serial heavy work. English (`en`) and Ukrainian (`uk`) are the only supported language selections; changing the selection queues regeneration from immutable audio.

A durable Transcript is written beside `meeting.md` as human-readable `transcript.md`, machine-readable `transcript.json`, and interoperable `transcript.vtt`. The artifacts preserve timestamps, track-derived speakers, selected/detected language, engine/model provenance, source paths, generation time, and diagnostics. JSON segments are indexed with their audio time ranges after generation. Transcript files are replaceable generated artifacts; recordings remain evidence.

The default local transcription engine is faster-whisper. Its recommended multilingual Large v3 Turbo model is installed on demand under Stillmatter's Application Support directory through an explicit Settings action; users may instead select the larger full-quality Large v3 model. Runtime and model setup is pinned, staged, structurally validated, and loaded before atomic promotion. Model switches preserve the current valid installation until the replacement is ready, and partial or interrupted setup is never considered ready. Explicit developer-only whisper.cpp CLI/model environment overrides remain available but are not part of user setup.

## Summary

An editable and regeneratable Markdown summary of a Meeting, generated from its durable Transcript by an app-owned AI Workflow. It has stable Summary, Decisions, My action items, Other action items, and Open questions sections plus a structured JSON extraction sidecar. Extracted outcomes cite exact Transcript segment IDs and time ranges so claims remain traceable to evidence.

A Summary does not require approval as a whole. Only My action items become Review Inbox proposals; Other action items remain reference-only in the Summary unless the user later promotes them. The AI Workflow never writes Todo Items directly.

## Action Item

An evidence-backed commitment or proposed obligation found in a meeting, transcript, note, or manual meeting note. Action Items appear in meeting summaries and are separated into **My action items** and **Other action items**.

Only Action Items assigned to the user require approval before becoming Todo Items. Action Items assigned to others can remain reference-only in the meeting summary.

Action Item review outcomes are: accepted, reference-only, dismissed, or merged.

## Todo Item

A one-sentence Markdown checkbox describing something to do. Todo Items can be added at any time and may originate from an accepted Action Item or direct user entry.

Todo priority is physical order in `Todos/todo.md` `## Queue`: higher means higher priority. Todo comments and subtasks are indented beneath the item. Nested unchecked checkboxes are also queryable Todo Items with a parent-child relationship.

The app may show filtered task views and a mixed Inbox, but `Todos/todo.md` remains the main canonical queue; the Inbox is app/SQLite review state rather than a Markdown section.

Todo status is visible in the checkbox marker:

- `[ ]` open
- `[x]` done; completion date is written at the end of the line and the item moves under `## Done` with a dated subsection
- `[B]` blocked
- `[C]` canceled

Due dates use visible `due: YYYY-MM-DD` syntax. Accepted source-backed todos keep compact Obsidian refs such as `[[Meetings/.../summary#My action items|ref]]`.

## Activity Item

A days/weeks-scale workstream represented by a Markdown file with status, description, notes, outputs, linked todos, and an activity log. Activity Items are long-running work references in the todo/worktable system, usually producing documents, code, or other outputs.

Every Activity Item belongs to a Project. If no specific Project fits, it belongs to the General Project. Activity Item files live chronologically under `Activities/YYYY/MM/`, use frontmatter status values `active`, `blocked`, `completed`, or `canceled`, and record `ended_at` while in a terminal state. Their output and timestamped activity-log sections remain readable Markdown and searchable workspace content.

## Project

A months/years-scale area of work represented by a canonical index Markdown file. A Project gathers knowledge, meetings, activities, todos, action items, decisions, and reports related to that long-running area.

## Person

A lightweight local identity used for search and reference in meetings, action items, and summaries. Stillmatter is a private personal app, so Person is not a team-management or CRM concept.

## Decision

A durable resolved choice. A Decision may come from a meeting, note, or manual entry and should link to evidence where evidence exists.

## Job

A versioned, typed unit of app-owned background work persisted in the operational SQLite store. A Job declares ordered stages, source artifacts, expected generated outputs, execution class, and retry policy. Heavy Jobs run serially by default; lightweight Jobs may run with bounded parallelism. Stage state and logs make Jobs resumable and inspectable, while generated artifacts must pass declared validators before a stage succeeds. Jobs never apply canonical workspace mutations directly.

## AI Workflow

A bounded app-owned pi/Codex Job that may read the whole vault but receives an explicit contract naming its task, primary sources, related context, expected outputs, and forbidden mutations. An AI Workflow runs with read-only vault tools and returns validated Markdown artifacts plus structured JSON sidecars or proposals; it never applies canonical workspace mutations itself.

## Contextual Ask

An ephemeral question-and-answer interaction in the dedicated Ask AI tab. The user chooses a workspace context, and Contextual Ask retrieves a bounded set of Search Index excerpts for that scope: Meetings use meeting/summary/transcript content, Tasks use Todo Items, Activities use their corresponding files, and Reports use reports/briefs. The user must explicitly enable broader-vault retrieval.

Only retrieved excerpts are sent to the pi/Codex runner. The runner has no tools or vault working directory, answers backed by workspace content must cite visible source paths, and citations to unseen sources are rejected. Answers and their visible-source lists are shown in the app but are not written to canonical Markdown.

## Daily Brief

A temporary generated planning note covering today's meetings, Inbox items, top queue items, overdue todos, blocked items, active activities, and notes. It is generated when the app is focused on a day that does not already have one. A Daily Brief is a working artifact and may be deleted after it is processed into later reporting.

## Daily Report

An optional durable daily record produced from the day’s brief, meetings, todos, and activities. The MVP may avoid producing Daily Reports if Weekly Reports are the main durable reporting artifact.

## Weekly Report

A generated editable durable weekly artifact combining review of the past week and planning for the coming week. It must be explicitly accepted by the user through an editable prompt with Accept and Remind next time choices. Acceptance moves all done and canceled tasks currently in `Todos/todo.md` into the report, removes them from `todo.md`, and marks the report accepted transactionally. Proposed follow-up todos remain `#ai-proposed` Inbox items until separately approved or canceled. When a Weekly Report covers daily material, covered Daily Briefs may be removed or skipped entirely.

## Archive

A non-destructive inactive state or move. Detailed retention and cleanup workflows are deferred beyond the MVP.

## Retention Decision

A future explicit user decision to keep, archive, delete, or defer cleanup for recordings, transcripts, generated files, or other artifacts. Detailed Retention Decision design is deferred beyond the MVP.
