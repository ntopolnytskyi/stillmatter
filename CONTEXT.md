# Stillmatter

Stillmatter is a private work log connecting meetings, evidence, and personal todos. This glossary defines product language; behavior and UI rules live in the [Recording and Meetings document](docs/meetings-recording-plan.md) and [screen profile](docs/graphite-focus/STILLMATTER_PROFILE.md).

## Language

**Meeting**:
A conversation and its collected recordings, transcript, summary, notes, decisions, and action items.

**Capture Session**:
The time-bounded recording of a Meeting, separate from its later processing.

**Capture Preflight**:
A readiness assessment that blocks capture when requirements are unmet or explains a reduced capture mode.

**Teams Detection Signal**:
Evidence that a native Teams call may be active; detection is distinct from permission or policy to record it.

**Microphone Track**:
The user's independently recorded input audio.

**System Audio Track**:
Audio recorded from Mac applications, kept separate from the Microphone Track.

**Recording Bundle**:
The validated collection of a Capture Session's audio references, integrity information, and diagnostics used for later processing.

**Transcription Audio Sidecar**:
A replaceable audio derivative used to improve transcription without altering original recordings.

**Transcript**:
Timestamped text derived from Meeting audio, linked back to its evidence.

**Summary**:
An editable account of a Meeting's main points, decisions, my action items, other action items, and open questions, with citations to the Transcript.

**Action Item**:
An evidence-backed commitment or proposed obligation. My action items require approval before becoming Todo Items; others' action items can remain reference-only.
_Avoid_: Todo Item for an unapproved proposal.

**Todo Item**:
A personal task represented by a Markdown checkbox; its priority is its position in the canonical Queue. It may be entered directly or created by accepting an Action Item.
_Avoid_: Action Item for an accepted canonical task.

**Inbox**:
Items awaiting a decision, review, or attention, including proposed Action Items; separate from the canonical Todo queue.

**Project**:
A long-running area of work gathering related knowledge, meetings, todos, and decisions.

**Decision**:
A resolved choice, linked to evidence when available.

**Job**:
App-owned background work with observable stages, outputs, and retry state; distinct from Meeting or artifact readiness.

**AI Workflow**:
A bounded AI Job that reads workspace context and returns generated artifacts or proposals without directly applying canonical workspace mutations.

**Archive**:
A reversible inactive state that hides a Meeting from the default browser while retaining its artifacts and links.
