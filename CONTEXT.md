# Stillmatter

Stillmatter is a private work log connecting meetings, evidence, and personal todos. This glossary defines product language; the current Meeting AI design is recorded in the [reconciled specification](.scratch/meeting-ai/spec.md), with its review status stated there. Earlier behavior and UI context live in the [Recording and Meetings document](docs/meetings-recording-plan.md) and [screen profile](docs/graphite-focus/STILLMATTER_PROFILE.md).

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

**Voice Profile**:
Local learned voice information owned by a Person, used to suggest their identity in later Meetings. It survives Meeting archive/deletion, is removed when its Person is deleted, and requires the user's confirmation before applying a suggested match.

**Person**:
A known individual whose identity and optional Voice Profile are maintained independently of Meetings. Removing a Person removes their learned Voice Profile.

**Speaker Range**:
A time interval of recorded speech attributed to a speaker. The user can correct its limits or split a mixed-speaker interval into separately attributed ranges.

**Summary**:
An editable account of a Meeting's main points, decisions, my action items, other action items, and open questions, with citations to the Transcript.

**Action Item**:
An evidence-backed commitment or proposed obligation assigned to a person or awaiting an owner, with a review state and completion state. An approved personal Action Item is also a Todo Item, retaining the same identity and state; other people's items remain Meeting work.
_Avoid_: Todo Item for an unapproved proposal.

**Todo Item**:
A personal task represented by a Markdown checkbox; its priority is its position in the canonical Queue. It may be entered directly or be an approved personal Action Item exposed in the Todo queue, retaining that Action Item's identity and state.

**Inbox**:
Items awaiting a decision, review, or attention, separate from the canonical Todo queue. Meeting Action Items await approval within their Meeting rather than appearing individually in the Inbox.

**Project**:
A long-running area of work gathering related knowledge, meetings, todos, and decisions.

**Decision**:
A resolved choice, linked to evidence when available.

**Job**:
App-owned background work with observable stages, outputs, and retry state; distinct from Meeting or artifact readiness.

**AI Workflow**:
A bounded AI Job that reads workspace context and returns generated artifacts or proposals without directly applying canonical workspace mutations.

**Archive**:
An inactive Meeting lifecycle state excluded from default browsing and search, with no in-app restore or editing. Archived Meetings retain their artifacts and links subject to evidence retention.
