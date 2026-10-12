---
profile_schema: graphite-focus-application-profile/v1
name: Stillmatter
contract: ./DESIGN.md
compatible_contract: ^2.0.0
platform: AppKit macOS 13+
status: canonical
---

# Stillmatter screen profile

## Product Scope

Stillmatter is a local-first macOS work log. This profile applies [Graphite Focus](DESIGN.md) to its screens; shared tokens, native behavior, and accessibility rules remain there. Domain language lives in [CONTEXT.md](../../CONTEXT.md); workflow requirements live in [Recording and Meetings](../meetings-recording-plan.md).

## Information Architecture

The fixed 64 pt icon rail has five destinations: **Today**, **Recording**, **Meetings**, **Tasks**, **Settings**. Settings and the About icon stay bottom-anchored outside the scrolling destinations. Each 44 pt destination button has a name, tooltip, native Tab focus and Space/Return activation; selection is neutral with one violet symbol. The rail has no expanded mode or resizable divider.

About opens on pointer double-click or keyboard/VoiceOver activation and remains in the app menu. Toolbar **Search** defaults to the current area; **All types** narrows result kinds without changing scope. **Filter meetings** independently filters browser rows. Menus retain routes to Settings, search, and toolbar commands.

## AppKit Native Mappings

Unlisted roles follow the shared contract.

| Product role | Graphite Focus role | AppKit primitive | Ownership | Required behavior |
|---|---|---|---|---|
| Main window | Shell Region | `NSSplitView` | system | Fixed rail, list/detail, independent scrolling |
| Global destinations | Sidebar Item | `NSButton` | system | Five named buttons; native focus and activation |
| About | Icon Button | `NSButton`, About panel | system | Bottom anchor; menu route |
| Commands | Window Toolbar | `NSToolbar`, `NSMenu` | system | Search, navigation, compact recording/Job status |
| Area Search | Search Field; Precision Ledger | `NSSearchField`, picker, results table | contextual | Visible scope/query/type; preview or owning-area navigation |
| Browsers | Precision Ledger | `NSTableView`/`NSOutlineView`, split view | contextual | Native selection, keyboard navigation, detail |
| Capture | Primary Button; Destructive Button; Status Label | `NSButton`, labels | system | Start principal; Stop destructive; live state attention |
| Settings diagnostics | Form Row; Status Label | `NSGridView`, native controls | contextual | Nearby explanation, validation, next action |
| Action Item review | Collection Row; Selection Summary | Native collection and actions | contextual | Selection count, evidence, stable review actions |

## Screen Recipes

| Area | Composition |
|---|---|
| Today | Structured Workbench: recording/Job status when relevant, Inbox Required/Review/Attention groups, top canonical Queue items in order, today's Meetings |
| Recording | Operational canvas: capture state, elapsed time, Start/Stop, live notes; disclose technical diagnostics progressively |
| Meetings | Precision Ledger: browser/detail, Overview/Transcript selector, shared pinned audio transport; outcomes and notes before Processing & source files; actionable failures remain visible |
| Tasks | Precision Ledger: ordered Queue, status/due/source filters, distinct parent and source references |
| Settings | Leading native form near `{measure.form}`, permissions/components, help and validation |
| Action Item review | Proposal collection, evidence, selection summary, stable Accept/Merge/Reference Only/Dismiss actions |

Meeting detail has one More menu for management. Summary and notes have local Edit actions; Copy and source opening remain available. Titles yield width to actions; prose wraps; crowded citations use an accessible sources menu. Long prose uses `{measure.reading}`; operational collections use available width.

Audio transport, action review, and Transcript navigation are bounded panels. Summary, notes, decisions, others' actions, open questions, and source files are open sections. Detail reads from the left in the current LTR UI; RTL support is not yet validated.

## Stillmatter Components

| Component | Family | Native mapping | State applicability |
|---|---|---|---|
| Capture Session Summary | Feedback and Status | Labels, native controls, elapsed-time text | Interaction on actions; Meaning attention/live, destructive action, error; Activity idle/starting/recording/stopping/finalizing/failed/recovered; active/inactive window |
| Capture Preflight Finding | Feedback and Status | Row, Status Label, Settings button | Ready/degraded/blocked/unavailable; action focus; active/inactive |
| Teams Detection Evidence | Navigation and Data | Disclosure/table | Observing/detected/unknown/unavailable; disclosure and focus; active/inactive |
| Artifact Status Section | Feedback and Status | Section, labels, disclosure | Pending/progress/ready/failed/unavailable; active/inactive |

## Domain Meaning Boundaries

Preserve the glossary's distinctions: Meeting versus Capture Session, observation versus recording policy, generated Action Item versus accepted Todo Item, and Job progress versus artifact readiness. Preflight **Blocked** prevents capture; **Degraded** permits explicitly reduced capture. Presentation never creates a second canonical task store.

## Adaptive Shell Specialization

Follow the shared collapse order. Keep the rail visible at 720 pt when list/detail switching leaves useful space; remember sidebar visibility in user defaults. The Meetings list currently clamps to 320 pt; list widths are not persisted. Inspector support is a layout fixture, not a shipped feature. Narrow Back navigation preserves selection and input. Simple screens have no empty list column.

## Accessibility and State Specialization

Recording uses attention plus text/symbol; Stop uses destructive action styling. Preflight says Ready/Degraded/Blocked. Teams detection says Detected/Not detected/Unknown; unknown does not mean ended. Jobs expose stage/value; Todo status retains checkbox/text meaning.

Review success appears inline and is announced once without stealing focus. Failures persist, preserve edits/selection, and offer retry. After removing a proposal, focus moves to the next, previous, or empty-state target. Native controls retain Tab/Shift-Tab order, checkbox Space activation, and button Return activation; task tables retain arrow navigation.

AppKit and SwiftUI share window activity/accessibility context. Status uses Meaning, progress uses Activity, and selection/disabled state stays in native controls. Apply the contract's keyboard, VoiceOver, motion, transparency, contrast, and focus-restoration rules throughout.

## Token Specializations

No shared token values are overridden. `Typography.activeTranscriptSegment` uses 14 pt bold system text to identify playback position without color alone.

## Exceptions

| ID | Affected rule | Reason | Scope | Replacement behavior | Accessibility evidence | Review condition |
|---|---|---|---|---|---|---|
| `SM-EX-002` | System appearance | Stillmatter adopts the contract's intentional dark-only high-frequency worktable scope | App-owned windows | Force dark semantic roles while preserving native controls | Check contrast, transparency, motion, keyboard, VoiceOver, inactive windows | Appearance or minimum macOS changes |
| `SM-EX-003` | Native button face | Large circular playback transport | `MeetingPlaybackButton` only | Custom face; retain NSButton action, focus, keyboard and enabled state | Named Play/Pause, tooltip, native focus mask; check keyboard and VoiceOver | Native equivalent or interaction regression |
| `SM-EX-004` | Success green | Approved violet Meeting readiness treatment | Meeting Ready badge and browser symbol only | Accent tint with explicit Ready text and checkmark | Text and symbol retain meaning; check contrast and inactive windows | Meeting status design changes |

## Product Acceptance

Run structural validators, then review Today, Recording, Meetings, Tasks, Settings, search, and Action Item review at the contract's three sizes. Include long content, accessibility settings, inactive windows, keyboard and VoiceOver. Verify retained capability/state and bounded exceptions; automated checks alone do not establish conformance.
