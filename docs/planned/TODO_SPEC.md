# Stillmatter — ToDo Module Specification

**Status:** Approved functional baseline · **Platform:** native macOS (Swift / SwiftUI) · **Theme:** Dark · **Revision:** 2026-11-15

> This document consolidates the 210 decisions made during product discovery, including later corrections. It is the implementation source of truth for the ToDo module. When earlier choices conflict with later corrections, the later choice prevails. Weekly Report content generation and Meetings file naming are explicitly separate design workstreams.

## 1. Product intent and scope

Stillmatter ToDo is a local-first, Markdown-native task manager integrated into the existing Stillmatter Meetings module. It combines manually entered work and AI-extracted meeting action items, while preserving human control over approval. Fast keyboard-driven workflows, safe file editing, and an understated macOS dark UI are primary requirements.

**In scope:** Today planning, Active tasks, Needs Approval, Completed, Projects, Trash, inline editing, one-level subtasks and comments, Smart Input, tags, priority, Due Date, search, WikiLinks, bidirectional Meetings synchronization, Undo/Redo, and Weekly Report archiving integration.

**Out of scope for MVP:** SQL/database persistence, recurring tasks, reminders, attachments, rich task descriptions, multiple nested subtask levels, manual top-level ordering, bulk selection, future Today scheduling, custom empty-project registry, reopening completed tasks, account/cloud sync.

## 2. Navigation and design system

- Main Stillmatter app has a **narrow icon-only sidebar** (Meetings, ToDo, etc.); Settings is at the bottom. ToDo may expose a secondary internal navigation area with labels: **Today, Active, Needs Approval, Completed, Projects, Trash**. No numeric sidebar badges.
- Search is **not** a persistent main navigation item. `⌘F` opens a temporary Search View over the current ToDo view. Repeating `⌘F` focuses the field and selects all text. `Esc` while search field focused removes field focus; another `Esc` closes Search View and restores the previous section. If an inline editor is active, `Esc` first cancels that editor. Search query survives navigation within the running session, not application restart.
- Dark appearance with muted surfaces, restrained purple accent, compact density, keyboard selection highlight. Shared reusable SwiftUI components for checkboxes, chips, priority badges, date labels, task rows, nested rows, comment icon, WikiLinks, popovers, inline editors, dialogs and progress bars.
- All task titles, subtask titles and comments wrap fully; no ellipses on content text. Tag chips may truncate with `…` and expose full name in tooltip. Finished tasks and subtasks use **muted text, never strikethrough**.
- Projects chips accented, ordinary tag chips neutral. P1 red, P2 orange, P3 neutral. Show no priority chip if unset. `+ Subtask` and `+ Comment` buttons appear only when task hovered or selected. Nested content is always expanded, including on Completed tasks.
- A task linked to a Meeting shows a separate clickable WikiLink row beneath the title, including while editing. Task title is not overloaded with link behavior.
- No separate task details modal; editing occurs inline. Search results are fully editable inline.

## 3. Workspace and Markdown files

Workspace Root is chosen in Settings and retained using macOS security-scoped bookmarks. All user content is Markdown; **no SQL**.

```text
WorkspaceRoot/
├── todo.md
├── trash.md
├── meetings/
│   └── YYYY/MM/<meeting-file>.md
└── reports/
    └── YYYY/Q1.md  (also Q2.md, Q3.md, Q4.md)
```

`todo.md` has managed sections `# ToDo`, `## Active`, `## Needs Approval`, `## Completed`. Unknown sections (e.g. `## Someday`) and their tasks are **preserved byte-for-byte where not edited**, not displayed, indexed as managed tasks, or changed by Stillmatter. Unknown headings, metadata and formatting elsewhere are preserved. `trash.md` holds deleted tasks with complete metadata and `🗑 YYYY-MM-DD` deletion marker.

### 3.1 Canonical task format

```markdown
# ToDo

## Active
- [ ] Review authentication PR #prj:AdoramaOne #pri:1 #API +today ~2026-11-18 <!-- id:2026111504321 -->
    - [x] Check API contract
    - [ ] Run integration tests
    - Comment: Check **new specification** and `README.md`

## Needs Approval
- [ ] Prepare Phase 2 timeline #ai:generated #sys:need-approve <!-- id:2026111504322 -->

## Completed
- [x] Finalize rollout plan #prj:AdoramaOne ✅ 2026-11-14 <!-- id:2026111408410 -->
```

The above example shows the **conceptual** syntax; project, priority, and regular tag tokens are metadata within the task line. The sample `#API` is a regular tag example; the parser should also recognize configured ordinary `#tag` syntax. Use `#prj:Project` for projects, `#pri:1|2|3` for priority, `~YYYY-MM-DD` for Due Date, `+today` for Today, `#ai:generated` and `#sys:need-approve` for AI approval status. The source of truth for task identity is the `<!-- id:... -->` comment. Completion date is `✅ YYYY-MM-DD`; a Today task completed on that date replaces `+today` with `+today-done:YYYY-MM-DD` until the next day. A separate stable Meeting/action-item linkage is required, represented in Markdown metadata without relying on the displayed WikiLink text; exact encoding should be isolated behind a versioned codec.

**Nested elements:** exactly one nesting level, using indented Markdown list items. Subtask: `    - [ ] Text` or `    - [x] Text`. Comment: `    - Text` (no checkbox). Their original interleaved order is preserved. A comment has a speech-bubble icon in the UI and is excluded from subtask progress. Markdown bold/italic/code/WikiLinks render in read mode, raw Markdown is edited inline. No automatic sorting of nested elements.

### 3.2 IDs and timestamps

- Task ID: `YYYYMMDDSSSSS` (local date plus five-digit seconds since midnight); collision suffix `-1`, `-2`, etc. Unique across `todo.md` and `trash.md`.
- Creation date is derived from the ID, shown only in tooltip; no separate `createdAt`. No `updatedAt` anywhere.
- Missing ID on manually added task: assign when first detected using detection date. Malformed/duplicate ID: repair while retaining date where recoverable; otherwise use repair date. Preserve Meeting links during repair.
- `completedAt` is date only, `✅ YYYY-MM-DD`, displayed e.g. `Completed 12 Nov 2026`. For tasks completed on same date, stable ID is tie-breaker.
- Deleted date is `🗑 YYYY-MM-DD`; no automatic Trash retention expiry.

### 3.3 Lossless editing contract

Parse the Markdown into an AST/CST with exact source ranges, trivia and unknown tokens. Change only recognized spans. Do not regenerate the entire document from an abstract model. Preserve unknown sections, user formatting, line endings, comments and unrelated whitespace. Unsafe or malformed managed task spans are flagged; block writes affecting ambiguous spans instead of silently corrupting them. External file edits take precedence.

## 4. Task lifecycle

| State | Entry | Exit | Editable? |
|---|---|---|---|
| Active | Manual creation; approved AI task; restore from Trash | Completed; Trash | All supported fields |
| Needs Approval | Meeting AI action item assigned to user | Approve → Active; Reject → Trash | All supported fields **except Today** |
| Completed | Checkbox/Space/X on main task | Trash; Weekly Report archive | Title, tags, priority, Due Date, subtasks, comments; **never status or completion date** |
| Trash | Delete from any managed section; reject AI task | Restore previous section; permanent delete | Restore / permanent delete; no active editing |
| Archived in report | Successful Weekly Report archive | None via ToDo | No ToDo edit or restore; manual report Markdown edit only |

Main-task completion is **terminal** and immediate, without confirmation or Undo. A completed task cannot reopen, including through Meetings; create a new task for new work. Completing a parent does **not** change subtask checkbox states. A parent with all subtasks checked remains Active until explicitly completed; `3/3` is informational only. A completed parent can still edit/toggle its subtasks, without changing its Completed status.

Moving a task to Trash is not Undoable; restore through Trash only. Restoring a completed task returns it to Completed, not Active. Rejecting a pending AI task retains the original Meeting Action Item; deleting a linked accepted ToDo task also removes its Meeting Action Item (subject to synchronization error handling). Restore of that deleted ToDo task does **not** recreate the Meeting Action Item.

## 5. Today planning

Today is a **manual subset of Active**, marked by `+today`. It is independent of Due Date: overdue or due-today tasks are not automatically added. Toggle via sun icon or `⌘T`; when a nested element is selected, `⌘T` applies to its parent. Sun icon stays visible on Today tasks; otherwise appears on hover/selection.

- Today tasks persist across midnight while unfinished. No carryover day counter, date-of-first-planning or automatic escalation.
- Today sort: priority P1 → P2 → P3 → unset; then earliest Due Date; then oldest creation ID.
- Compact progress fraction and bar (e.g. `4/7`). A Today task completed today remains at bottom of Today through the end of that day, even across restart, using `+today-done:YYYY-MM-DD`; remove temporary marker the next day. Completed tasks are not shown overdue.
- When `⌘T` removes a task from Today and it disappears, select next top-level task, else previous, else none; remain in Today.
- `⌘N` in Today automatically adds `+today`.

## 6. Projects, tags and priorities

Projects are dynamic `#prj:*` tags, not separate storage. A task can have multiple projects and appears in each project view, but is one physical task. Projects sidebar alphabetical A–Z, case-insensitive; virtual **Unassigned** last. No empty project persistence. Project `+` creates the first task tagged with that project. Rename Project globally rewrites managed occurrences; Delete Project removes project tag, leaves tasks. `⌘N` within a project automatically tags the new task with that project.

Ordinary tags and project chips appear together, wrapping, in original Markdown token order. No arbitrary cap and no UI reordering. Clicking either chip opens the same tag-editor popover, **not navigation**. Selected tags are chips at top with × remove, excluded from suggestions below; hide the selected block when empty. Suggestions grouped Projects and Tags, alphabetized and dynamically derived from todo.md including Completed; unused tags vanish. Case-insensitive matching; preserve first encountered spelling, unify variants in managed tokens. Reserved namespaces: `prj:*`, `sys:*`, `ai:*`, `pri:*`.

Popover behavior: edits save **immediately** and are Undoable; popover remains open after add/remove; close via Esc/outside click. Search clears and retains focus after add. New name offers `Create Tag "name"` (default Enter action) and explicit `Create Project "name"` (click or keyboard selection). Global Rename Tag updates all managed tasks and merges duplicates; global Delete Tag is not supported. Removing a tag in the popover affects only selected task. `#ai:generated` can be manually added/removed and controls AI badge, but not actual Meeting linkage.

Priorities: optional P1 Critical, P2 High, P3 Normal, unset. Smart Input `!1`, `!2`, `!3`; persisted `#pri:1|2|3`. `⌘1/2/3` assign, `⌘0` clear. Priority chip is read-only; change via context menu → Priority or shortcuts. Sort Active/Project by priority, then Due Date, then oldest creation.

## 7. Due Date

Optional, stored as absolute `~YYYY-MM-DD`. Smart Input accepts `~tomorrow`, `~fri`, `~+3d`, `~YYYY-MM-DD`, normalized on save. UI relative dates `Today`, `Tomorrow`, `In 3 days`, `2 days overdue`; distant dates absolute. Overdue Active dates highlighted red. Completed dates neutral. Clicking existing date opens compact date popover; if absent, context menu → Due Date. Popover: calendar, quick Today/Tomorrow/Next Week, natural date entry, Clear. **Next Week = Monday of the next calendar week**. No reminders or automatic Today assignment.

## 8. Subtasks and comments

- Exactly one nested level; no nested tags/priority/Due Date/Today. Always expanded, including Completed and Search results.
- Checkbox on subtask toggles independently; never auto-completes parent. Show compact `n/m` counter beside parent title when subtasks exist, no progress bar. Comments excluded from count.
- Comments are Markdown list items prefixed `- `, displayed in muted text with message icon; they can contain Markdown and WikiLinks.
- New subtask/comment via hover-or-selected `+ Subtask` / `+ Comment`, appended **after all existing nested elements**, regardless of type.
- Preserve original interleaved order. Context menu for subtask: Edit, Complete/Uncomplete, Move Up, Move Down, Delete. For comment: Edit, Move Up, Move Down, Delete. No parent actions in nested context menu.
- Move Up/Down swaps with adjacent nested element regardless of type, updates Markdown immediately, Undoable. No drag/drop.
- Delete nested element immediately with no confirmation; Undo restores exact prior position. After deletion select next nested element, else previous, else parent.
- Double click or Enter/E on selected nested item edits that item. `J/K` traverses **all visible** parent/nested elements in screen order. `Space/X` toggles checkboxes only on tasks/subtasks, does nothing on comments. `⌘Backspace` deletes selected nested item (Undoable); on parent moves task to Trash (not Undoable). `⌘N` always creates a new top-level task.
- New subtask Enter saves and creates next subtask; new comment Enter saves and creates next comment. Tab indent and Shift+Tab outdent where supported by the one-level structure. Existing item Enter saves only. Inline text editing uses `⌘Enter` explicit save and Esc cancel.

## 9. Creation and inline editing

- Manual task is immediately Active, no Inbox. New task editor is compact and inline. `⌘N` creates a top-level task regardless of selected nested item.
- `⌘N` in Active, Today or Project: new task appears in sorted list, is selected and scrolled into view. Today adds `+today`; Project adds current `#prj:*`.
- `⌘N` in Completed, Needs Approval, Trash: creates a **normal Active task** using compact editor above current list, **without navigating**; after save show `Task created` with optional `View` action to Active.
- `⌘N` in Search: creates a normal Active task, **does not inherit search filters**, keeps Search View open, **shows no creation notice**. New task appears in results only if it matches.
- Double click title, subtask, comment to edit; single click selects. Enter/E edits selected item. `⌘Enter` saves; Esc cancels. No autosave. Navigating away, selecting another task, clicking empty area or switching apps **discards unsaved editor text without confirmation**. Exception: tag popover changes save immediately.
- Inline editor uses raw Markdown; read view renders Markdown. WikiLinks remain clickable outside editor.
- After completing a task or moving it to Trash, select next visible top-level task, else previous, else none. After restoring from Trash remain in Trash and select next/previous. When new task appears in active view, select and scroll to it.

## 10. Keyboard shortcuts

| Shortcut | Behavior |
|---|---|
| `⌘N` | New top-level task (context-dependent defaults as above) |
| `⌘F` | Open temporary Search View; repeated use selects query |
| `Esc` | Cancel editor; dismiss search field focus; then close Search View; close popovers |
| `J/K` or `↑/↓` | Move selection through all visible parent and nested rows |
| `Enter/E` | Edit selected row |
| `⌘Enter` | Save current inline editor |
| `Space/X` | Toggle checkbox on task/subtask; no-op on comment |
| `⌘T` | Toggle Today on parent task |
| `⌘1`, `⌘2`, `⌘3`, `⌘0` | Set P1/P2/P3/none |
| `⌘Backspace` | Parent → Trash; nested → immediate Undoable delete |
| `⌘Z`, `⌘⇧Z` | Multi-level session Undo/Redo (eligible operations only) |

Keyboard letter shortcuts do not intercept text input. Context menus must provide discoverable alternatives.

## 11. Undo/Redo and selection

Multi-level in-memory session history, scoped by affected files. Undo/Redo covers title, tags, project assignment, priority, Due Date, Today, nested item creation/edit/delete/reorder/check states, and comments. **Does not cover** main-task completion or moving a main task to Trash. When title edit is linked to Meetings, Undo/Redo updates both files coherently. External file change clears Undo history for affected file. History is not persisted across restart.

Selection is single-item only; no multi-select or bulk actions. Main list sorting is automatic. Completed list groups Today / Yesterday / This Week / Earlier, newest first (completion date, then ID). Project views show Active first and Completed at bottom; Needs Approval excluded until approved. Needs Approval newest creation ID first, no grouping.

## 12. Search View

Temporary view invoked with `⌘F`, closed with Esc according to focus hierarchy. No persistent Search sidebar item. Search covers managed tasks (Active, Needs Approval, Completed) and their titles, subtasks, comments, tags, projects, priority, Today, Due, creation/completion dates and Meeting metadata/title. **Exclude Trash**; Trash has its own search including `deleted:YYYY-MM-DD`. Unknown Markdown sections are preserved but not searched as managed tasks.

Supported Smart Search tokens include:

```text
#backend
#prj:AdoramaOne
!1
+today
~overdue
meeting:"Sprint Planning"
created:2026-11-15
due:2026-11-18
completed:2026-11-14
meeting-date:2026-11-12
date:2026-11-15
```

When match occurs in a subtask or comment, display its **single parent task** with all nested items and highlight the matching text in place. Search results are fully inline-editable. After save, recompute immediately; if task no longer matches, remove it and select next result, else previous. Search query persists only during current app session. Meeting title search follows stable Meeting ID even after title rename.

## 13. Meetings integration

### 13.1 Import and approval

AI-extracted action items assigned to the user create tasks in Needs Approval with `#ai:generated #sys:need-approve`, stable `meetingId` and `actionItemId`. Approve individually moves to Active, removes need-approve. Reject moves to Trash but leaves original Meeting Action Item. Durable deduplication and rejection memory prevent reruns from recreating approved/rejected items. Pending tasks editable except Today; title edits sync to Meeting immediately. No bulk approval requirement.

### 13.2 Linking and WikiLinks

Linked tasks display protected clickable row `[[meetings/2026/11/filename|Meeting Title]]` relative to Workspace Root, including during edit. Opens Meeting page, not specific Action Item. WikiLinks `[[path]]` and `[[path|Alias]]` can also appear in titles, subtasks, comments; render alias clickable outside editor, raw syntax while editing. Meeting Markdown opens in Stillmatter, other Markdown opens as file. Missing targets visually indicated. In-app renames update known WikiLinks; external renames updated only if identity can be established. Meeting filename convention deferred to Meetings design.

### 13.3 Bidirectional synchronization

Only **title** and **terminal completion status** synchronize ToDo ↔ Meeting Action Item. Other ToDo fields are local. Identity is based on stable Meeting/action IDs, **not** title matching. Re-running AI analysis must not overwrite existing linked Action Items or IDs; genuinely new IDs create new Needs Approval items, respecting dedup/rejection memory. Completed items never reopen. If source Action Item is removed, keep ToDo task with unavailable Action Item link and stop sync; retain Meeting WikiLink. Deleting accepted linked ToDo removes original Meeting Action Item; restoring ToDo from Trash does not recreate it.

For ordinary sync failure: revalidate files, attempt rollback, present **modal Retry / Cancel**. Retry revalidates before write. Cancel restores prior title, exits editor and does not add failed edit to Undo history. No retry queue. Use safe per-file atomic writes and pre-write version checks. **Explicit MVP limitation:** no transaction journal, no crash-recovery protocol across two files. Process crash between file writes may leave temporary divergence; this risk is accepted. Do not falsely promise cross-file atomicity.

## 14. File monitoring and safety

- Monitor `todo.md`, `trash.md` and Meeting files independently. Reload on external modification. External file always wins; discard unsaved UI changes and show brief notice only when user edits were lost, otherwise silent.
- Verify file version/hash immediately before write; use temporary file + atomic replacement per file. Never silently overwrite an external edit.
- Maintain independent per-file Undo history invalidation when externally changed. Malformed/ambiguous task spans block unsafe writes, with actionable error.
- Security-scoped bookmark access and sandbox permissions handled in repository layer; never assume persistent raw paths alone grant access.
- Workspace has no SQL store. Ephemeral indexes/caches are derived and rebuildable; durable rejection/dedup metadata must be Markdown-backed or another explicitly documented **non-SQL** workspace mechanism, without contradicting Markdown-only user content.

## 15. Weekly Report archival boundary

Weekly Report is scheduled for Fridays and collects completed tasks into `reports/YYYY/Qn.md` quarterly Markdown files. Detailed report content, AI prompt controls and presentation are **separate specification work**. This module defines only the archival safety contract:

1. Identify completed tasks eligible for the reporting period.
2. Generate/append report content with stable task IDs for deduplication.
3. Persist and verify report successfully **before** removing corresponding tasks from `todo.md`.
4. On failure, leave tasks in `todo.md`, record pending archive state, automatically retry at next app launch/activation; retries must be idempotent.
5. After successful archive, tasks are no longer editable/restorable through ToDo. Summaries/history remain in report Markdown.

## 16. Proposed Swift architecture

```text
StillmatterApp
├── AppShell (icon-only navigation, dark theme)
├── ToDoFeature
│   ├── ToDoCoordinator / @Observable ToDoStore
│   ├── Views: Today, Active, NeedsApproval, Completed, Project, Trash, Search
│   ├── Components: TaskRow, NestedRow, CommentRow, TagChip, PriorityBadge,
│   │              DueDatePopover, TagEditorPopover, InlineEditor, ProgressHeader
│   ├── TaskCommandHandler (keyboard, context menus, Undo)
│   ├── TaskQueryEngine (filters, sorting, search, highlighting)
│   └── TaskViewState (selection, editor, search, popover)
├── MarkdownCore
│   ├── LosslessMarkdownParser / SourceSpanEditor
│   ├── TaskMarkdownCodec / WikiLinkCodec / IDGenerator
│   ├── WorkspaceRepository (bookmarks, atomic writes, version checks)
│   └── FileChangeMonitor (external reload)
├── MeetingsBridge
│   ├── StableActionItemLinkResolver
│   └── MeetingTaskSyncService (title, completion, rollback)
└── ReportsBridge
    └── WeeklyArchiveCoordinator (idempotent archive/retry)
```

Prefer protocol-backed services and pure parser/query functions for unit testing. View models do not perform raw file IO. UI state is separate from durable Markdown state. Long parsing/search work runs off main actor; UI state changes are main-actor isolated. Debounce external file notifications, but **do not debounce committed user writes into lossy autosave**. SwiftUI lazy list rendering should preserve stable IDs and keyboard selection. One `TaskOperation` model should support validated mutations, source-span edits, eligible Undo and cross-file sync.

### 16.1 Data model (logical, not SQL)

`Task { id, titleMarkdown, section, priority?, dueDate?, todayState, projectTags[], ordinaryTags[], subtasksAndComments[], completedDate?, deletedDate?, aiGenerated, meetingLink?, sourceSpan }`

`NestedItem = Subtask { checked, titleMarkdown, sourceSpan } | Comment { bodyMarkdown, sourceSpan }`

`MeetingLink { meetingId, actionItemId, wikiLinkTarget, displayTitle }`

`SearchState { query, results, previousSection, fieldFocused }`; `EditorState { taskId, nestedIndex?, draft, originalSnapshot }`.

## 17. User stories and acceptance criteria

### US-01 — Manual capture
**As a user**, I create an Active task with `⌘N` and optional Smart Input. **Accept:** parsed tokens normalize on save, stable ID assigned, view-specific Today/Project defaults applied, non-Active sections do not navigate.

### US-02 — Plan Today
**As a user**, I toggle Today without changing Due Date. **Accept:** `+today` persists across days, sun icon reflects state, Today progress updates, completed-today item stays until midnight.

### US-03 — Prioritize and schedule
**As a user**, I set P1/P2/P3 and a Due Date. **Accept:** priority chip/context menu/shortcuts agree; due date is absolute in Markdown, relative in UI; overdue never auto-adds Today.

### US-04 — Work with projects and tags
**As a user**, I assign multiple projects/tags through one popover. **Accept:** immediate Markdown update, selected chips at top, dynamic suggestions, create tag/project, no duplicate case variants, project views share same task ID.

### US-05 — Manage subtasks and comments
**As a user**, I add, edit, check, reorder and delete nested items. **Accept:** one-level Markdown list, interleaved order retained, comments have message icon and no checkbox, `n/m` excludes comments, Undo restores deleted item.

### US-06 — Keyboard-first interaction
**As a user**, I navigate all visible rows with `J/K` and edit with Enter/E. **Accept:** nested rows participate; text fields consume normal typing; Space/X on comments no-op; `⌘Backspace` targets selection appropriately.

### US-07 — Complete work
**As a user**, I check off a parent task. **Accept:** status terminal, completion date recorded, subtask check states unchanged, no Undo or confirmation, correct destination/selection behavior.

### US-08 — Review meeting-generated work
**As a user**, I approve or reject AI items. **Accept:** approval moves to Active; rejection to Trash without deleting Meeting source; stable IDs prevent duplicate imports.

### US-09 — Edit linked action item
**As a user**, I change a linked task title. **Accept:** Meeting title updates; failure prompts Retry/Cancel and rollback; Undo/Redo on successful edit updates both.

### US-10 — Open linked content
**As a user**, I click a WikiLink. **Accept:** Meeting links open Stillmatter Meeting page, other Markdown opens file, missing link is marked, raw link syntax remains in editor.

### US-11 — Find and edit tasks
**As a user**, I open Search with `⌘F` and edit matching items. **Accept:** query tokens supported, nested match highlighted in context, result deduplicated by parent, nonmatching task disappears immediately after save.

### US-12 — Leave search
**As a user**, I press Esc to leave search. **Accept:** first Esc from focused search field blurs it, second closes Search and restores previous view; editor Esc cancels editor first; query retained only within session.

### US-13 — Delete and restore
**As a user**, I move a main task to Trash and restore it. **Accept:** full metadata preserved, previous section restored, Completed stays Completed, no Undo for main delete, permanent delete available.

### US-14 — Edit Markdown externally
**As a user**, I edit `todo.md` in another editor. **Accept:** Stillmatter reloads, external file wins, unrelated/unknown sections untouched, unsafe writes blocked, lost UI draft notice when applicable.

### US-15 — Archive safely
**As a user**, I expect completed work to appear in Weekly Reports without data loss. **Accept:** verified report write precedes removal, failure retains tasks, next activation retries, duplicates not created.

### US-16 — Recover from a normal sync error
**As a user**, I receive a clear Retry/Cancel dialog if a linked file write fails. **Accept:** prior state restored on Cancel, failed edit not in Undo, Retry rechecks file versions; crash-between-files limitation documented.

### US-17 — Maintain Completed history
**As a user**, I review finished tasks. **Accept:** groups Today/Yesterday/This Week/Earlier; no strikethrough; editable non-status fields; terminal completion invariant.

### US-18 — Keep workspace portable
**As a user**, I move or back up the workspace. **Accept:** user content remains readable Markdown, WikiLinks are root-relative, derived search indexes can be rebuilt, no SQL dependency.

## 18. Test matrix and release gates

| Area | Required tests |
|---|---|
| Parser | Round-trip lossless unknown sections, Unicode, mixed line endings, nested comments, malformed tasks, duplicate IDs |
| Mutations | Only intended source spans change; collision IDs; tag casing; move nested across comment/subtask |
| Task lifecycle | Complete terminal, completed subtasks mutable, Trash restore section, Today midnight behavior |
| Search | Smart tokens, Meeting title changes, nested highlighting, immediate result removal, Esc focus hierarchy |
| Undo | Multi-level edits, nested delete/reorder, excluded parent completion/deletion, per-file external invalidation |
| Meetings | Approval/rejection dedup, regenerated AI stable IDs, bidirectional title/completion, rollback, missing source |
| File safety | External change between read/write, atomic replacement, bookmark failure, malformed managed span |
| Reports | Failed report write leaves todo.md intact, retry after restart, idempotent archive |
| UI | Keyboard-only path, full text wrapping, dark theme, icon-only main rail, VoiceOver labels, no strikethrough |

**Release gates:** zero silent data loss in normal error handling; parser round-trip fixture suite passes; no accidental mutation of unknown Markdown; terminal completion invariant enforced; idempotent approval/archive; all critical keyboard workflows functional.

## 19. Explicit clarifications and superseded choices

1. New task in Project **inherits current project** (supersedes an earlier opposite answer).
2. New task from Completed, Needs Approval or Trash **does not navigate away**; creates Active task in compact top editor.
3. Search View is temporary, opened with `⌘F` and dismissed with Esc focus hierarchy; **no persistent Search nav entry**.
4. `⌘N` in Search inherits **no** filters and shows **no** post-create notice.
5. Comments use indented Markdown **`- ` list items**, not bare indented lines, and show message icon.
6. No `updatedAt`, no Today carryover count, no reopening Completed, no strike-through for completed text.
7. Unknown Markdown sections are preserved but **not shown or managed**, even if they contain task-like syntax.
8. Cross-file writes are **not crash-atomic**; user explicitly accepted no journal.
9. No further product discovery questions are required for ToDo MVP; details not defined here should use conservative native macOS conventions without overriding documented behavior.

## 20. Visual references

Use the companion mockups `mocks/01-today-active.html`, `mocks/02-needs-approval.html`, `mocks/03-search.html`, and `mocks/04-inline-edit.html` (plus PNG previews). These are **implementation references**; this document is authoritative whenever an illustration is ambiguous.
