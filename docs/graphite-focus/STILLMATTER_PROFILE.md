---
profile_schema: graphite-focus-application-profile/v1
name: Stillmatter
contract: ./DESIGN.md
compatible_contract: ^2.0.0
platform: AppKit macOS 13+
status: canonical
---

# Stillmatter Graphite Focus Application Profile

## Product Scope

Stillmatter is a local-first native macOS work log and worktable intended for frequent use. This profile specializes Graphite Focus for Stillmatter without replacing the contract. The AppKit application remains native; adopting Graphite Focus does not authorize a SwiftUI migration or changes to canonical Markdown, SQLite operational state, capture/transcription pipelines, AI Workflow boundaries, or mutation rules.

Stillmatter intentionally adopts Graphite Focus's dark-only appearance. This is the contract's declared product exception, not evidence that macOS generally recommends forcing dark appearance. Increased Contrast, Reduce Transparency, Reduce Motion, Full Keyboard Access, VoiceOver, and active/inactive-window behavior remain mandatory.

## Information Architecture

The global navigation is a fixed-width 64 pt icon rail containing eight native `NSButton`s, ordered Today (default), Recording, Meetings, Tasks, Projects / Activities, Reports, Ask AI, Settings. It is flat, not visually grouped or resizable. Each 44 pt icon button has an accessible name and tooltip, retains native Tab focus and Space/Return activation, and uses a neutral selection surface with one violet symbol. There is no arrow-key traversal. A separate app icon stays anchored at the bottom, outside the scrolling destinations: a pointer double-click opens the native About window; keyboard/VoiceOver activation opens it once. About shows the bundled current version and creator/copyright notice, and is also available from the app menu. A single pointer click does nothing and does not change the selected destination. Search is Area Search in the Window Toolbar, visibly named “Search” and scoped to the current destination by default. Its type picker is a result-type selector that defaults to “All types”; it narrows indexed results but does not choose where to search. Meeting-browser filtering is a separate row filter named “Filter meetings” that affects only visible Meeting rows, including the selected Meeting queue and filter controls. Clearing toolbar Search and clearing Meeting-browser filters are independent. Settings, search, and relevant frequent actions remain available through menus when toolbar or sidebar chrome is hidden.

## AppKit Native Mappings

These mappings specialize contract roles; all unlisted roles use the contract mapping unchanged.

| Product role | Graphite Focus role | AppKit primitive | Ownership | Required behavior |
|---|---|---|---|---|
| Main window navigation | Shell Region | `NSSplitView` regions | system | Fixed 64 pt icon rail, hideable at width pressure; resizable activity list and detail regions, independent scrolling |
| Global destinations | Sidebar Item | native `NSButton` icon rail | system | Eight VoiceOver-labeled buttons, tooltips, Tab navigation and activation, preserved selection |
| About icon | Icon Button | native `NSButton` and standard About panel | system | Bottom-anchored outside navigation scroll; pointer double-click or keyboard/VoiceOver activation; app-menu About remains available |
| Global commands | Window Toolbar | `NSToolbar` and main-menu commands | system | Search, compact recording/Job status, navigation, and few frequent actions |
| Area Search | Search Field; Precision Ledger | `NSSearchField` plus result-type picker and table/list results | contextual | Visible current scope, query, selected result type, selection/preview or owning-area navigation; type picker defaults to All types and never changes area scope |
| Today summary | Structured Workbench | AppKit document view and native collections | app | Semantic sections and rows; no formatted aggregate-text fallback |
| Selection-heavy browsers | Precision Ledger | `NSSplitViewController` plus `NSTableView`/`NSOutlineView` | contextual | Meetings, Tasks, Activities, Reports, and search when selection benefits the task |
| Capture controls | Primary Button; Destructive Button; Status Label; Progress Indicator | native `NSButton`, labels, progress controls | system | Start principal when available; Stop destructive to session, not error-colored live state |
| Settings diagnostics | Settings; Form Row; Status Label | leading `NSGridView`/stack with native controls | contextual | Approximately `{measure.form}`, nearby help/validation/action, non-color status cues |
| Action Item review | Collection Row; Selection Summary | selectable table/list and stable action area | contextual | Visible selection count and distinct Accept/Merge/Reference Only/Dismiss hierarchy |
| Weekly Report review | Sheet | native sheet/panel | system | Editable review with clear Accept and Remind actions and focus restoration |

No product mapping replaces native AppKit interaction or focus behavior with custom drawing. The narrowly scoped visual treatment of the Meeting playback button is recorded in `SM-EX-003` below.

## Screen Recipes

| Area or workflow | Recipe | Required composition |
|---|---|---|
| Today | Structured Workbench | Page Header; recording and Job status; Required, Review, and Attention Inbox sections; Daily Brief; top Queue Todo Items; upcoming Meetings; active Activity Items |
| Meetings | Precision Ledger when history exists; operational canvas otherwise | Meeting browser/detail when useful; browser row filtering is labeled Filter meetings and shows active query, queue, and filters separately from toolbar Search; Capture Session controls remain available before a broader library exists |
| Meeting capture | Structured operational canvas | Prominent Capture Session state and elapsed time; Start/Stop hierarchy; live notes; progressively disclosed preflight, Teams signal, Recording Bundle, Transcript, Summary, and Job details |
| Tasks | Precision Ledger / Dense Collection | Queue order; Done, Blocked, Overdue, source and due filters; separate status, due, parent, and source-reference semantics |
| Projects / Activities | Precision Ledger | Selection browser and stable detail hierarchy for Project, lifecycle, goal, outputs, and activity log; focused creation/edit sheet |
| Reports | Precision Ledger when discovery exists | Report browser and readable detail; Daily Brief and Weekly Report remain distinct |
| Ask AI | Focused single canvas | Question controls before answer; remote-processing disclosure; explicit broader-vault state; structured citations and visible sources |
| Settings | Settings | Leading form near `{measure.form}` with permissions/components diagnostics, save feedback, and validation |
| Action Item review | Precision Ledger / Dense Collection | Proposal collection, selection summary, stable batch actions, evidence; proposals remain distinct from Todo Items |
| Weekly Report prompt | Modal and Transient | Native focused editable surface with Accept and Remind; no background prompt over a Meeting |

Long-form Summary, Transcript, report, and Contextual Ask prose is constrained near `{measure.reading}`. Operational tables, timelines, evidence collections, and diagnostics use available width.

**Page Header title and actions:** Stillmatter detail headers use the shared Graphite Focus title-and-actions composition. The visible title is one line, truncates at the tail with an ellipsis when needed, exposes the complete title through tooltip and accessibility label, and has lower horizontal compression resistance than the local action cluster. Header actions such as Meeting timeline, edit, archive, More, and Activity status controls remain visible at the supported main-window minimum; access through menus or the adaptive shell remains available only when a display is too constrained to fit the supported minimum.

**Default content alignment:** Stillmatter's browser rows, detail headings, metadata, status, controls, editors, and section content must read from the left edge in the current left-to-right UI. `NSStackView` fill alignment and intrinsic label widths placed this content on the right in practice, so Meeting detail and browser labels/editors explicitly use `.left` while full-width sections expand independently. Trailing placement is reserved for a deliberate secondary action or value within an otherwise left-aligned row. This is a deliberate LTR layout fix, not an RTL solution: forced `.left` does not mirror in right-to-left locales. RTL support requires a separate, locale-aware layout fix and validation before claiming RTL conformance.

## Stillmatter Components

Stillmatter adds only these product-semantic compositions. They use shared components internally and do not redefine shared meanings.

| Component | Family | Native mapping | State applicability |
|---|---|---|---|
| Capture Session Summary | Feedback and Status | Labels, native controls, elapsed-time text | Interaction on actions; Meaning attention/live, destructive action, error; Activity idle/starting/recording/stopping/finalizing/failed/recovered; active/inactive window |
| Capture Preflight Finding | Feedback and Status | Collection Row plus Status Label and optional Settings button | Interaction on action; Meaning informational/attention/destructive; Activity ready/degraded/blocked/unavailable; active/inactive window |
| Teams Detection Evidence | Navigation and Data | Disclosure Rows / table | Interaction/disclosure; Meaning informational; Activity observing/detected/unknown/unavailable; active/inactive window |
| Artifact Status Section | Feedback and Status | Content Section, Status Labels, Disclosure Rows | Meaning informational/success/attention/destructive; Activity pending/progress/ready/failed/unavailable; active/inactive window |

## Domain Meaning Boundaries

Presentation MUST preserve these distinctions:

- A **Meeting** is the folder/container and artifact context; a **Capture Session** is the time-bounded act of creating/recording it.
- A **Capture Preflight** finding can block or degrade capture. Blocking prevents start; degraded permits capture while naming reduced behavior.
- A **Teams Detection Signal** is observation-only supporting evidence. It never implies a Capture Session started automatically.
- A **Recording Bundle**, **Transcript**, and **Summary** are distinct artifacts with distinct readiness/failure states.
- An **Action Item** is a proposal or evidence-backed commitment. It is not an accepted canonical **Todo Item** until the existing review workflow accepts it.
- A **Todo Item** is a canonical checkbox whose priority is Queue order. Presentation does not create a second task store.
- An **Activity Item** is a days/weeks workstream owned by a **Project**. It is not a Todo Item.
- A **Job** describes app-owned processing state. It is not the state of its Meeting or artifact.
- A **Contextual Ask** is ephemeral and does not mutate canonical workspace files.
- A **Daily Brief** is a temporary planning artifact; a **Weekly Report** is an editable durable artifact requiring explicit acceptance.

## Adaptive Shell Specialization

Stillmatter uses the contract Region Collapse Order unchanged. The fixed 64 pt icon rail remains visible at 720 pt when the list replaces detail, unless the user hides it; it collapses only if even the rail and useful content cannot fit. Its divider cannot change its width. The Meetings browser currently initializes at 320 pt and clamps its divider to 320 pt; the Activities browser remains resizable. The optional inspector is a layout fixture, not a shipped feature. Validate at 1200×760, 720×520, and 1440 pt width.

At narrow width, the toolbar Back button and Location Label preserve list/detail continuity. Sidebar visibility is remembered in user defaults (not per-window); list widths are not persisted. Existing selection and input remain in the retained views across region changes. A simple screen remains a single canvas rather than keeping an empty middle column. An inspector is added only when context genuinely follows selection and is useful independently.

## Accessibility and State Specialization

- Recording/live uses attention meaning with the text “Recording” and a recording symbol or shape; Stop remains a destructive action without recasting recording as an error.
- Capture Preflight uses explicit “Ready,” “Degraded,” or “Blocked” text, a distinct symbol, explanation, and Settings action where available.
- Teams Detection always says it is observational and uses “Detected,” “Not detected,” or “Unknown”; unknown permission/process state is not “ended.”
- Job and artifact progress exposes stage text or a numeric value. Motion is never needed to know the stage.
- Todo open, done, blocked, canceled, and overdue states use visible text/checkbox marker/symbol in addition to color.
- Action Item selection exposes count and batch-action availability in stable text.
- Contextual Ask exposes current scope, broader-vault selection, remote-processing disclosure, citations, visible sources, and static loading/no-source/invalid-citation/failure text.
- Settings permission/component states combine status text, symbol, explanation, and relevant action.
- Icon-only toolbar and row actions have accessibility labels and useful tooltips. Focus returns after every transient surface.

## Token Specializations

Stillmatter introduces one product typography specialization: the active Transcript segment uses a 14 pt bold system font to mark playback position without color alone (`Typography.activeTranscriptSegment`). It introduces no semantic-token value override. It consumes Graphite Focus roles including `{surface.base}`, `{surface.chrome}`, `{surface.panel}`, `{text.primary}`, `{text.secondary}`, `{accent.base}`, `{status.success}`, `{status.attention}`, `{status.destructive}`, and `{status.informational}`. Native AppKit control geometry and system focus presentation remain documented contract-level exceptions, not new literals.

## Exceptions

| ID | Affected rule | Reason | Scope | Replacement behavior | Accessibility evidence | Review condition |
|---|---|---|---|---|---|---|
| `SM-EX-002` | Dark-only is a rare macOS appearance exception | Stillmatter adopts the contract's intentional dark-only high-frequency worktable scope | All Stillmatter windows owned by this profile | Force Graphite Focus dark semantic roles while preserving native controls and all accessibility presentations | Validate contrast, Increased Contrast, Reduce Transparency, Reduce Motion, active/inactive windows, VoiceOver, and Full Keyboard Access | Re-review if Stillmatter adds light appearance or changes minimum supported macOS |
| `SM-EX-003` | Native controls and focus rings MUST NOT be replaced by custom drawing merely to match tokens | The selected Meeting transport uses a recognizable, large circular play/pause face beside the waveform; a standard text button did not meet this transport layout | `MeetingPlaybackButton` only; no general license to redraw buttons | Retain `NSButton` for action, enabled state, mouse, keyboard, focus ring, and accessibility; custom drawing changes only the face and SF Symbol, with semantic colors for hover, pressed, and disabled states | Explicit Play/Pause accessibility labels and tooltips; native `NSButton` focus-ring mask and action; verify Full Keyboard Access, VoiceOver, Increased Contrast, and inactive-window presentation in experience review | Re-review if a native symbol button provides the same transport layout or keyboard/focus/accessibility behavior regresses |
| `SM-EX-004` | `{status.success}` green indicates completion | The approved Meetings view uses violet as the only chromatic ready-state accent; green controls and panels would confuse readiness with action acceptance | Meeting detail Ready badge and Meeting browser Ready symbol only, not global statuses | Keep the explicit checkmark and Ready text; tint the neutral badge outline/text and list symbol with `{accent.base}` instead of success green. Live and error retain their distinct semantic roles. | Text and symbol convey meaning without color; check Increased Contrast and inactive state | Re-review if Meetings status design changes |

No exception authorizes changes to Contract Precedence, State Axes, native focus, Region Collapse Order, or accessibility accommodations.

## Product Acceptance

Structural validation MUST pass before Experience Review. Experience Review covers at least Today, Meeting capture/detail, Tasks, Activities, search results, Ask AI, Settings, Action Item review, and Weekly Report prompt.

For each representative state, check the Reference Canvas and Minimum Operable Window, then the 1440 pt spacious case where width use matters. Check default and Increased Contrast, Reduce Transparency, Reduce Motion, active/inactive window, Full Keyboard Access, and VoiceOver. Confirm domain actions still call existing behavior, no migrated collection falls back to formatted aggregate text, no capability disappears on collapse, and no product exception silently expands its scope.
