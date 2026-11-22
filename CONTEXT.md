# Stillmatter

Stillmatter is a private work log connecting meetings, evidence and personal tasks. This glossary defines shared business language; feature documentation describes availability and behavior.

## Application layout

**Sidebar**:
The icon-only navigation bar on the left side of the window, below the Top Bar. Navigation Items run from top to bottom; Settings and the Application Icon are anchored at the bottom.

**Navigation Item**:
An icon in the Sidebar that selects a major part of the application, such as Recording, Meetings or Tasks, or opens Settings. The selected destination is shown in the Application Area.

**Application Area**:
The entire region to the right of the Sidebar and below the Top Bar, containing the selected destination's content.

**Top Bar**:
The bar in the window's title area, spanning above both the Sidebar and Application Area. It contains recording status and Search.
_Avoid_: Status Bar for this region.

**Application Icon**:
The app identity shown at the bottom of the Sidebar, separate from the navigation destinations.

**Listing**:
The area containing a collection of Listing Items within the Application Area, optionally with a Listing Bar. Each application function defines its own Listing and Workbench; a Listing supports selecting one item or, where appropriate, multiple items.

**Listing Item**:
The representation of an individual record or a group in a Listing, ranging from plain text to a composition of information and controls, including icons, chips and a context menu. In Meetings it represents one Meeting and can show title, recording start time, duration and status; in a grouped Settings layout it represents a settings group whose settings appear in the Workbench. In the future Todo layout, it can represent a task view or group, such as Today, Tomorrow, Important or a project, whose tasks appear in the Workbench.

**Listing Bar**:
The optional bar at the top of a Listing, primarily for searching its Listing Items. It may also contain Listing Filters; its search and filters apply only to that Listing.

**Listing Filter**:
A criterion available through the Listing Bar that narrows which Listing Items are shown.

**Workbench**:
The part of the Application Area where the user reads, edits and acts on the selected record or group, including its header, tabs and content. Each application function defines the content shown for its Listing selection.
_Avoid_: Detail Workspace.

## Text presentation

**Rendered Markdown**:
The formatted reading presentation of Markdown text, used throughout the application when the text is not being edited.

**Markdown Editor**:
The editing presentation of Markdown text, showing plain Markdown source, including its formatting syntax.

## Meeting Workbench

**Info Bar**:
The top part of the Meeting Workbench, presenting information about the selected Meeting. It sits above the Tabs and is distinct from the window-wide Top Bar.

**Tab**:
A named section of the Meeting Workbench, selected through the row of Tabs below the Info Bar. Selecting a Tab shows its Tab Content.

**Tab Content**:
The content of the selected Tab, shown below the Tabs in the Meeting Workbench.

## Workspace and organization

**Workspace**:
The folder selected to store and organize Stillmatter's Markdown content.

**Tag**:
A reusable label used to classify Action Items and Todo Items.

**Project**:
A special Tag used to group tasks.

## Recording

**Meeting**:
A work-log item representing an ad hoc or planned conversation with one person or a group, optionally associated with a calendar event. It contains the available recordings, Transcript, Summary, My Notes, Decisions, Action Items and Open Items.

**Capture Session**:
A period during which Stillmatter records audio for a Meeting, separate from later processing.

**Capture Preflight**:
A readiness check that determines whether recording can start and which audio sources are available.

**Microphone Track**:
Audio captured from the selected microphone during a Capture Session, representing the application user's audio input. The track alone does not establish the identity of every Speaker it captures.

**System Audio Track**:
Audio captured from Mac applications during a Capture Session, representing the other person or group participating in the conversation and kept separate from the Microphone Track.

**Recording Bundle**:
The complete set of files associated with a Meeting, organized in one folder under the parent media folder. It includes recordings, metadata, transcription files and Markdown documents.

## Meeting content

**Transcript**:
Timestamped text of a Meeting's recorded speech, with speaker attribution and links to the source audio.

**Transcript Segment**:
A timestamped portion of a Transcript containing speech and its speaker attribution.

**Speaker**:
A named or unidentified participant to whom recorded speech is attributed.

**Citation**:
A reference to the specific Transcript passage supporting a statement, Decision, Action Item or Open Item.

**Summary**:
A compact, editable account of what was discussed, agreed and acted on during a Meeting, preserving significant details. It helps the user understand the conversation and find relevant Meetings later through search.

**My Notes**:
User-authored Markdown notes for a Meeting, kept separate from generated content.

**Decision**:
A choice or agreement reached during a Meeting, with a Citation when available.

**Open Item**:
An unresolved question or issue raised during a Meeting, tracked until resolved, with a Citation when available.

## Tasks and attention

**Action Item**:
A task or commitment arising from a Meeting, assigned to someone or awaiting an owner, with a Citation when available.
_Avoid_: Todo Item for an unapproved proposal.

**Todo Item**:
A personal task entered manually or accepted from a Meeting's Action Items.

**Approval**:
The user's acceptance of a proposed Action Item after a Meeting, separate from completing it. Only Action Items require Approval; Decisions and Open Items do not.

**Inbox**:
A collection of items requiring the user's decision, review or attention.

**Today Review**:
The daily process of reviewing items needing attention, personal tasks and upcoming meetings.

## Processing and lifecycle

**AI Workflow**:
A defined process that uses AI to analyze information and produce content or proposed outcomes.

**AI Meeting Workflow**:
An AI Workflow that processes a Meeting's recorded conversation to produce a Transcript, Summary, and proposed Decisions, Action Items and Open Items.

**Archive**:
The inactive state of a Meeting with read-only in-app access, excluded from default browsing and search.
