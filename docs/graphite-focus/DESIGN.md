---
schema: graphite-focus/v1
contract_version: 2.0.1
name: Graphite Focus
platform: macOS 13+
appearance: dark-only
status: canonical
omitted_interchange_subset: Google Labs DESIGN.md tokens are web-oriented and non-authoritative for native macOS semantics.
---

# Graphite Focus Visual Contract

## Identity and Scope

Graphite Focus is a reusable visual language for frequently used native macOS applications. It combines restrained graphite surfaces, warm high-contrast text, and a rationed violet accent. This document is the complete normative visual contract; prototypes and research are evidence, not additional rules.

The key words **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are normative. Graphite Focus Schema `graphite-focus/v1` adapts the single-file, versioned, prose-plus-tokens idea of Google Labs' alpha `DESIGN.md`; it does not claim schema conformance. Values use macOS points and native semantics. Any external token export is an optional, non-authoritative Interchange Subset.

The contract targets macOS 13 or newer, native AppKit or SwiftUI, resizable windows, keyboard and pointer use, VoiceOver, and long sessions. Dark-only appearance is a deliberate product exception to Apple's normal appearance guidance. It does not waive native window, control, focus, menu, keyboard, or accessibility behavior. Light appearance and cross-platform rendering are omitted deliberately.

Semantic versioning applies to `contract_version`: breaking meaning changes increment major, additive roles increment minor, and clarifications increment patch. A compatible Application Profile MUST name the major version it consumes.

### Contract Precedence

Resolve conflicts in this order:

1. macOS accessibility accommodations;
2. native control behavior and component semantics;
3. Graphite Focus semantic tokens;
4. Screen Recipe examples;
5. Application Profile Extension Points.

More-specific rules win within one tier. An example never overrides a rule. When the contract is silent or contradictory, record a gap rather than inventing a convention.

## Principles

1. **Native before novel.** System windows, controls, menus, focus rings, typography, symbols, resizing, and accessibility semantics remain authoritative.
2. **Calm density.** Favor information-rich, comfortable-compact compositions with stable opaque surfaces and progressive disclosure.
3. **Hierarchy without decoration.** Surface value, typography, spacing, and quiet dividers carry structure; ordinary content does not float.
4. **One principal action.** The current task or section has at most one visually dominant action.
5. **Accent is a signal.** Violet identifies the principal action, current mode, actionable links, progress, sparse identity marks, and contextual dense-list selection only.
6. **State axes stay independent.** Focus, selection, meaning, activity, and active-window context are not synonyms.
7. **Meaning survives presentation loss.** Color, transparency, and motion reinforce meaning but never carry it alone.
8. **Structure adapts, capability persists.** Width pressure changes region presentation, not available capability or in-progress state.
9. **Semantic groups, not card grids.** A Semantic Panel exists only when content has a meaningful shared boundary.
10. **Long-session comfort.** Avoid flashing, decorative animation, excess contrast, pervasive accent, and unstable translucent content.

## Tokens

Token IDs are normative and are referenced with brace syntax (for example, `surface.base` appears as a braced reference elsewhere in this document). Feature code MUST consume semantic roles rather than introduce equivalent literals. Accessibility presentations MAY resolve a role to a different value without changing its meaning.

### Color and Surface Tokens

| Token ID | Default value | Required use |
|---|---:|---|
| `surface.base` | `#1C1D1F` | Window base and detail canvas |
| `surface.chrome` | `#242628` | Sidebar, content/list region, and opaque chrome fallback |
| `surface.panel` | `#2D3032` | Meaningful opaque grouped content |
| `surface.raised` | `#3A3D40` | Strong hover or emphasized raised region |
| `surface.selection-neutral` | `#35343D` | Global-sidebar selection |
| `surface.transient` | `#111415` at 96% | Transient overlays; resolves opaque with Reduce Transparency |
| `text.primary` | `#F4F2ED` | Primary content and titles |
| `text.secondary` | `#D0D1CC` | Supporting content |
| `text.metadata` | `#A4A8A5` | Metadata and secondary labels |
| `text.disabled` | `#7F8582` | Disabled or decorative text; never essential caption-only information |
| `accent.base` | `#B58AE8` | Principal action and permitted Accent Budget roles |
| `accent.hover` | `#C9A5F2` | Hover for app-owned accented actions |
| `accent.pressed` | `#9770C7` | Pressed app-owned accented actions |
| `accent.on` | `#1C1526` | Content placed on an accent fill |
| `status.success` | `#6BD18F` | Successful or complete meaning |
| `status.attention` | `#EFBD61` | Attention or live meaning |
| `status.destructive` | `#FF7C74` | Destructive action or error meaning |
| `status.informational` | `#7BAEEA` | Informational meaning |
| `stroke.structural` | white at 12% | Ordinary one-point structural boundaries |
| `stroke.emphasized` | white at 20% | Increased Contrast and emphasized boundaries |
| `shadow.transient` | black 48%, y 16, blur 44 | Sole custom shadow; transient surfaces only |

The ordered Surface Ladder is `{surface.base}` → `{surface.chrome}` → `{surface.panel}` → `{surface.raised}`. These are semantic depth roles, not a palette for arbitrary alternation. Ordinary content surfaces MUST be opaque and shadowless. Materials MAY appear in native title-bar/sidebar chrome and transient surfaces only, and MUST have the listed opaque fallback. State-bearing colors MUST NOT depend on translucency.

The Accent Budget permits `{accent.base}` only for the Principal Action, current mode, actionable links, progress, sparse identity marks, and contextual selection tint in Dense Collections. Global-sidebar selection MUST use `{surface.selection-neutral}` with one accent symbol. Success, attention/live, destructive, and informational meanings MUST use their separate roles and include text plus another non-color cue.

### Typography Tokens

| Token ID | Native role | Size and weight | Use |
|---|---|---|---|
| `type.page-title` | System | 24 pt bold | Page Header title |
| `type.section-heading` | System | 16 pt semibold | Section heading |
| `type.body` | System | 14 pt regular | Body and ordinary row title |
| `type.row-title` | System | 14 pt medium | Emphasized row title |
| `type.control` | System | 13 pt medium | Control label |
| `type.metadata` | System | 12 pt regular | Metadata |
| `type.caption` | System | 10 pt semibold | Caption or overline; never sole essential information |
| `type.numeric` | System monospaced digits | 12 pt regular | Numeric and elapsed-time data |
| `type.long-form` | System | 14 pt regular, about 1.5 line height | Prose up to 760 pt measure |

SF Pro/system typography is required. macOS does not provide iOS Dynamic Type, so layouts MUST remain legible and tolerate longer localized text without claiming Dynamic Type support. SF Symbols are the default symbol vocabulary; familiar outline symbols SHOULD be used in toolbars. Ambiguous icon-only controls MUST have an accessibility label and SHOULD have a tooltip. SF Symbols MUST NOT be used as logos or app icons.

### Geometry and Motion Tokens

| Token ID | Value | Use |
|---|---:|---|
| `space.1` | 4 pt | Primitive spacing |
| `space.2` | 8 pt | Primitive spacing |
| `space.3` | 12 pt | Compact inset and dense-row vertical inset |
| `space.4` | 16 pt | Panel inset |
| `space.5` | 24 pt | Page inset and major gap |
| `space.6` | 32 pt | Large separation |
| `radius.compact` | 6 pt continuous | Compact grouped content |
| `radius.control` | 10 pt continuous | App-owned controls/selectable rows when native geometry does not apply |
| `radius.panel` | 14 pt continuous | Semantic Panels |
| `radius.transient` | 18 pt continuous | Hero/transient surfaces only |
| `stroke.width` | 1 pt | Structural Stroke |
| `motion.local` | 120–180 ms | Purposeful local transition |
| `motion.region` | 180–240 ms | Purposeful region transition |
| `measure.form` | about 680 pt | Leading-aligned settings/form content |
| `measure.reading` | about 760 pt | Long-form prose |

Native control geometry overrides spacing and radius tokens where necessary for correct macOS behavior. Essential controls SHOULD retain native 22–24 pt minimum geometry. Capsules are reserved for Metadata Tags, Status Labels, and pill selectors; they are not a general container shape. Native motion is preferred. Under Reduce Motion, `{motion.local}` and `{motion.region}` resolve to immediate change or a restrained fade only when it preserves clarity.

## Native Mappings

Each mapping is implementation-independent. **System** means native behavior owns interaction and presentation; **app** means Graphite Focus composes native primitives; **contextual** means the listed native choice depends on content. Exceptions require an Application Profile record.

| Semantic role | Normal AppKit / SwiftUI primitive | Ownership | Allowed exception | Required behavior |
|---|---|---|---|---|
| Window Toolbar | `NSToolbar` / unified toolbar | system | None | Window identity, navigation, Area Search, and few frequent actions; every command also in menus |
| Page Header | Label stack in document view | app | None | Identifies current area/context without duplicating window title; normally scrolls; when paired with local actions, the title is a single tail-truncated line with full tooltip/accessibility text and yields width to a noncompressing action cluster |
| Content Section | View group | app | None | Groups a coherent topic with semantic heading |
| Section Header | Text/Label | app | Native table header | Names a section and optional local action |
| Shell Region | `NSSplitView` / split-view column | system | None | Flush, independently scrolling regions; the sidebar rail is fixed-width while content/list and detail can resize where supported |
| Semantic Panel | Opaque grouped view | app | Native group box when semantically suitable | One meaningful group; no ordinary shadow |
| Structural Divider | `NSSplitView` divider / separator | system | App one-point stroke | Quiet boundary without floating geometry |
| Contextual Inspector | Inspector split item / inspector scene scaffolding | contextual | Popover only when narrow | Follows selection, is toggleable/resizable, remembers preference, has no-selection state |
| Sidebar Item | Native icon `NSButton` / Button | system | None | One destination per button in the fixed icon rail; accessible name and tooltip, native Tab focus and activation, neutral selection plus accent symbol |
| Location Label | Toolbar label | app | None | Concise current narrow-navigation location |
| Segmented Mode Selector | `NSSegmentedControl` / Picker segmented style | system | None | Shows one current mode without impersonating tabs |
| Collection Row | `NSTableCellView`, collection item, or List row | contextual | Custom composition around native selection | Full-row selection; independent trailing action/disclosure; arrow navigation and Return activation |
| Disclosure Row | Outline row / disclosure control | system | None | Disclosure changes hierarchy without unintended selection action |
| Table | `NSTableView` / Table | system | None | Native selection, columns, sorting, focus, and accessibility |
| Outline | `NSOutlineView` / OutlineGroup | system | None | Native hierarchy disclosure and keyboard behavior |
| Selection Summary | Label plus native actions | app | None | States selected count and batch-action availability |
| Primary Button | `NSButton` / Button | system | App accent styling | Sole Principal Action in current task or section |
| Secondary Button | `NSButton` / Button | system | None | Available without competing with Principal Action |
| Quiet Button | Borderless/link button | system | None | Low-emphasis action remains discoverable and focusable |
| Destructive Button | Destructive-role button | system | None | Spatially and semantically separated; confirmation where irreversible |
| Icon Button | Toolbar/button item with SF Symbol | system | Product symbol with justification | Accessible label; tooltip where useful; native focus |
| Text Field | `NSTextField` / TextField | system | None | Native editing, selection, focus ring, validation semantics |
| Search Field | `NSSearchField` / searchable | system | None | Area scope, visible query/filter state, menu/keyboard route |
| Secure Field | `NSSecureTextField` / SecureField | system | None | Native privacy and editing behavior |
| Multiline Field | `NSTextView` / TextEditor | system | None | Native editing, scrolling, selection, and accessibility |
| Checkbox | `NSButton` checkbox / Toggle checkbox style | system | None | Native mixed/selected/disabled states |
| Radio | Radio button group / Picker radio style | system | None | Native exclusive choice and keyboard behavior |
| Toggle | `NSSwitch` / Toggle | system | None | State label remains explicit |
| Picker | `NSPopUpButton` / Picker | system | None | Native menu and keyboard behavior |
| Stepper | `NSStepper` / Stepper | system | None | Value exposed as text, not control shape alone |
| Date/Time Control | `NSDatePicker` / DatePicker | system | None | Native locale, calendar, and keyboard behavior |
| Form Row | `NSGridView`/Form composition | contextual | Stacked form at constrained width | Leading label, control, help, validation, status, and action as applicable |
| Status Label | Label with text, symbol, and optional border | app | None | Meaning uses text and at least one non-color cue in addition to color |
| Metadata Tag | Quiet descriptive capsule | app | Plain metadata text | Description only; never action or status by appearance alone |
| Count Badge | Native badge or numeric label | contextual | Plain count text | Quantity only; never sole important state |
| Progress Indicator | `NSProgressIndicator` / ProgressView | system | Static progress treatment under Reduce Motion | Exposes text or numeric value and accessible activity state |
| Inline Notice | Label/group near affected content | app | Native validation message | Persistent when user action is required; semantic cue and next action |
| Content State | Content-unavailable composition | app | Native unavailable view where supported | Cue, concise explanation, and useful next action for loading/empty/no-results/offline/error/unavailable |
| Menu / Context Menu | `NSMenu` / Menu | system | None | Native command roles, shortcuts, and accessibility |
| Popover | `NSPopover` / Popover | system | None | Brief anchored choices; opaque fallback; focus returns on dismissal |
| Sheet | `NSPanel` sheet / sheet | system | Separate window for independent long work | Focused blocking edit with clear hierarchy and focus restoration |
| Alert / Confirmation | `NSAlert` / alert or confirmation dialog | system | None | Native role ordering, destructive clarity, and focus restoration |
| Lightweight HUD | Non-key transient panel | app | Inline confirmation | Brief confirmation that never steals focus; static text meaning |

Native controls and focus rings MUST NOT be replaced by custom drawing merely to match tokens. App-owned styling MAY surround or tint native controls only when their semantics, hit targets, focus, enabled state, accessibility, and platform behavior remain intact.

## Adaptive Shell

Graphite Focus uses one Adaptive Shell. Region order and keyboard reading order are: Window Toolbar → global sidebar → optional content/list → detail canvas → optional Contextual Inspector → transient surface. An Application Profile MAY add a structural drawer and MUST place it explicitly in the path.

| Region | Useful width | Ideal | Behavior |
|---|---:|---:|---|
| Global sidebar | 64 pt | 64 pt | Fixed-width icon rail; user-hideable and automatically collapsible without changing the visibility preference |
| Content/list | 260–380 pt | 300 pt | Present only for selection-heavy workflows |
| Detail canvas | 480 pt minimum beside regions | Fluid | Reading/form measures constrain only relevant content |
| Contextual Inspector | 280–420 pt | 320 pt | Normally closed unless central; transient when narrow |

The **Reference Canvas** is 1200×760 pt, the spacious validation width is 1440 pt, and the **Minimum Operable Window** is 720×520 pt. They are validation anchors, not fixed breakpoints. Adaptation is content-driven when useful widths cease to fit.

The fixed icon rail MUST provide accessible names and tooltips for every destination. Its native buttons use Tab focus and Space/Return activation; it does not implement arrow-key traversal or a resizable divider. The Region Collapse Order is mandatory: (1) hide or transiently present the inspector, (2) auto-collapse the sidebar, then (3) let content/list temporarily replace detail. Narrow Navigation MUST provide a native toolbar back affordance and concise Location Label. Selection, scroll position, and in-progress input MUST survive every transition. No capability may disappear, no bottom/mobile navigation may be introduced, and user-requested sidebar visibility persists whenever space permits.

Shell Regions are flush and square, separated by Structural Strokes. They scroll independently. The toolbar remains fixed; Page Headers ordinarily scroll with detail. Pin only task-essential controls or headings, and avoid nested scrolling inside Semantic Panels. Operational canvases, tables, evidence streams, and timelines use available width. Forms align leading at `{measure.form}`; long-form prose aligns leading at `{measure.reading}`.

Use a Semantic Panel only when the boundary is part of the task meaning: a bounded editor, transport, review workspace, preflight/status workspace, or another group that must be perceived and operated as one unit. Routine read-only detail, metadata, source lists, dense collections, and ordinary reference outcomes SHOULD remain open Content Sections, native rows, tables, or divider-led groups. Section Headers use a leading title with optional trailing local actions or metadata; actions stay native controls and do not require a panel. A screen MUST NOT introduce an unconditional generic Card or Tile abstraction to decorate every group.

The Window Toolbar owns window identity, navigation, Area Search, and a small set of frequent actions. The Page Header owns the selected area or item's local title. Every toolbar action MUST have a menu command because the toolbar can be hidden or customized. Multiple windows maintain independent shell state; full-screen and window management remain system-owned.

Area Search belongs in native toolbar/sidebar placement, defaults to current-area scope, and keeps query, scope, and filters visible. Results use the content/list region when present and otherwise the detail canvas. It MUST NOT be a decorative floating search card.

## Components and State Axes

Components belong to exactly one semantic family. Native controls remain native; names describe jobs, not shapes.

| Family | Components |
|---|---|
| Structure | Window Toolbar; Page Header; Content Section; Section Header; Shell Region; Semantic Panel; Structural Divider; Contextual Inspector |
| Navigation and Data | Sidebar Item; Location Label; Segmented Mode Selector; Collection Row; Disclosure Row; Table; Outline; Selection Summary |
| Actions and Input | Primary Button; Secondary Button; Quiet Button; Destructive Button; Icon Button; Text Field; Search Field; Secure Field; Multiline Field; Checkbox; Radio; Toggle; Picker; Stepper; Date/Time Control; Form Row |
| Feedback and Status | Status Label; Metadata Tag; Count Badge; Progress Indicator; Inline Notice; Content State |
| Transient Surfaces | Menu / Context Menu; Popover; Sheet; Alert / Confirmation; Lightweight HUD |

The independent State Axes are:

- **Interaction:** normal, hover, pressed, keyboard-focused, disabled.
- **Choice:** selected, current mode, mixed.
- **Meaning:** informational, success, attention/live, destructive.
- **Activity:** loading, progress, complete, unavailable.
- **Window Context:** active, inactive.

### Plain-Language State Decision Table

This table is normative for representative cross-tab states. A presentation MUST NOT substitute one row for another: selection is not status, progress is not readiness, and action emphasis is not focus. “Text” means visible state wording or an equivalent control label; “symbol” means an SF Symbol, native marker, or text glyph with the same non-color function.

| State | What it means | Visual treatment | Text and symbol | Progress value | Focus ring |
|---|---|---|---|---|---|
| Selected/current item | This row, destination, or mode is the user's current choice or navigation context. | Use native selection where available; global sidebar uses `{surface.selection-neutral}` with one accent symbol; Dense Collections MAY use contextual accent tint. Do not use success/attention/error colors. | The selected item's name remains visible; VoiceOver exposes selected/current state through native selection semantics. | None. | Native focus ring only when keyboard-focused; selection is not focus. |
| Ready/completed | Work or an artifact is complete, ready, or accepted. | Use `{status.success}`. The only approved accent-colored ready exception is Stillmatter `SM-EX-004`. | Include explicit Ready/Complete/Done/Granted text plus a checkmark or equivalent. | None unless a completed progress control is still present, in which case expose 100% or completed text. | Native focus only for any adjacent action. |
| Needs attention/live | Something is recording, live, degraded, blocked, overdue, queued, or otherwise needs awareness without being an error. | Use `{status.attention}`. Recording/live is attention, not destructive. | Include explicit Recording/Live/Needs attention/Blocked/Overdue/Queued text plus a distinct dot, warning, blocked marker, or recording shape. | Include stage/value when the state is queued or in progress. | Native focus only for any action. |
| Failed | A job, validation, load, permission, or generated artifact failed. | Use `{status.destructive}` for the failure meaning; keep retry/dismiss actions as native controls. | Include Failed/Missing/Error text, a destructive symbol, explanation, and the next available action. Persistent until resolved or dismissed. | If failure interrupted progress, expose the failed stage or last known value as text. | Native focus only for controls; focus should not jump merely because failure appeared. |
| Loading/processing | Work is currently being fetched, generated, installed, rebuilt, transcribed, summarized, or otherwise processed. | Use native `NSProgressIndicator` / `ProgressView`; progress tint MAY use `{accent.base}` because progress is in the Accent Budget. | Include Processing/Loading/Rebuilding/etc. text plus a stable symbol or native activity indicator. Motion is not required to understand the state. | Determinate work exposes a numeric value; indeterminate work exposes a stage description. | Native focus remains wherever the user placed it. |
| Unavailable | Content, feature, model, source, or permission-dependent capability is not usable now. | Use neutral/informational treatment, not disabled styling unless the control itself is disabled. | Include Unavailable/Not configured/No results text, explanation, and useful next action when one exists. | None. | If there is a next action, it is a native focusable control. |
| Disabled | A control or option cannot be activated in the current context. | Use native disabled control behavior and `{text.disabled}` only for nonessential labels. | The disabled control label remains explicit; help text explains why when not obvious. | None. | Disabled controls follow native focus behavior and are not custom-focusable. |
| Destructive action | An action can delete, stop, discard, cancel, or irreversibly harm work. | Use native destructive role/placement and `{status.destructive}` only for destructive meaning. Do not color live state as destructive merely because Stop is destructive. | Use a clear destructive verb and confirmation where irreversible. | If destructive work is in progress, use a separate progress row. | Native focus ring and native alert/sheet focus restoration. |
| Primary action | The one principal action for the current task or section. | Use native button with app accent styling where appropriate; only one principal action per task/section. | Verb label states the action. Icon-only primary actions require accessibility label and tooltip. | If pressed action starts long work, progress appears separately. | Native focus ring, never custom accent glow. |

### State Applicability Matrix

`—` means the axis does not apply. A listed axis MUST implement all relevant states above while preserving native semantics.

| Component group | Interaction | Choice | Meaning | Activity | Window Context |
|---|---|---|---|---|---|
| Window Toolbar; Page Header; Content Section; Section Header; Shell Region; Semantic Panel; Structural Divider | — | — | — | — | active/inactive |
| Contextual Inspector | normal; disabled | — | — | unavailable | active/inactive |
| Sidebar Item | normal; hover; pressed; keyboard-focused; disabled | selected | — | — | active/inactive |
| Location Label | — | current mode | — | — | active/inactive |
| Segmented Mode Selector | normal; hover; pressed; keyboard-focused; disabled | selected; current mode | — | — | active/inactive |
| Collection Row; Table; Outline | normal; hover; pressed; keyboard-focused; disabled | selected | informational; success; attention/live; destructive | loading; unavailable | active/inactive |
| Disclosure Row | normal; hover; pressed; keyboard-focused; disabled | selected | — | loading; unavailable | active/inactive |
| Selection Summary | normal; disabled | selected | — | — | active/inactive |
| Primary Button; Secondary Button; Quiet Button; Destructive Button; Icon Button | normal; hover; pressed; keyboard-focused; disabled | — | destructive where declared | loading; progress; complete | active/inactive |
| Text Field; Search Field; Secure Field; Multiline Field; Form Row | normal; hover; keyboard-focused; disabled | — | informational; success; destructive | loading; unavailable | active/inactive |
| Checkbox; Radio; Toggle; Picker; Stepper; Date/Time Control | normal; hover; pressed; keyboard-focused; disabled | selected; mixed where native | — | — | active/inactive |
| Status Label; Inline Notice; Content State | — | — | informational; success; attention/live; destructive | loading; progress; complete; unavailable | active/inactive |
| Metadata Tag; Count Badge | — | — | — | — | active/inactive |
| Progress Indicator | — | — | informational; success; destructive | loading; progress; complete; unavailable | active/inactive |
| Menu / Context Menu; Popover; Sheet; Alert / Confirmation | native | native | informational; destructive where declared | loading; unavailable | active/inactive |
| Lightweight HUD | — | — | informational; success | complete | active/inactive |

Interaction rules are stable. Hover is a subtle surface step. Pressed actions use the pressed native or accent role. Native focus rings remain visible and are never replaced with a glow. Sidebar selection is neutral with one accent symbol. Dense Collection selection MAY use contextual accent tint plus a restrained boundary cue. Inactive windows reduce chrome and hover emphasis while preserving readable text, selection, status, control labels, and focus meaning.

Clicking a Collection Row selects it and updates detail. A dedicated disclosure changes hierarchy without accidental selection side effects. A trailing action remains independently targetable. Arrow keys move selection and Return opens or activates where appropriate. A full-row hit target MUST remain distinguishable from its trailing controls.

A Status Label communicates meaning, a Metadata Tag describes content, and a Count Badge communicates quantity. None becomes an action unless rendered as a native control. Content State covers loading, empty, no-results, offline, error, and unavailable, with a recognizable cue, concise explanation, and useful next action where one exists. Errors requiring action persist until resolved or dismissed; brief success MAY use a Lightweight HUD.

## Screen Recipes

Recipes arrange shared components; they never redefine component identity, state meaning, or Adaptive Shell behavior.

### Structured Workbench

The default composition uses a fixed-width icon rail with accessible destination names, Page Header, broad detail canvas, one Principal Action where applicable, restrained Semantic Panels for genuine groups, and Collection Rows for interactive summaries. Ordinary structure stays open and divider-led rather than becoming a card grid.

### Precision Ledger

Selection-heavy work adds a resizable content/list region containing Dense Collection rows or a native table beside a detail Page Header and Content Sections. An inspector is optional only when information independently follows selection. At narrow widths, list temporarily replaces detail and native back navigation restores detail without losing selection.

### Settings

Use Section Headers and native Form Rows in a leading-aligned column near `{measure.form}`. Help and validation remain near their controls. Destructive actions are isolated. A settings screen does not maintain an empty content/list column.

### Search

Use Area Search with visible scope, query, and filters; Collection Rows or a Table show kind, title, source, excerpt, and location metadata. Selection previews context or opens the owning area. No-results and unavailable-index Content States provide a useful next action.

### Empty State

Place one Content State in its owning canvas. State what is absent or unavailable, why when known, and the single next useful action. Do not disguise loading, error, or unavailable content as an empty collection.

### Modal and Transient

Use a popover for brief anchored choices, sheet for focused blocking edits, alert/confirmation for system-style decisions, inspector for selection-following context, and a separate window for independent or long-running work. Titles, explanation, action hierarchy, destructive meaning, keyboard dismissal, and focus return remain explicit.

## Accessibility and Motion

Accessibility is a required presentation of the same semantics, not a separate theme.

- **Contrast:** Default presentation MUST meet at least 4.5:1 for ordinary text and 3:1 for large/bold text and non-text controls/indicators; target 7:1 for small custom text where practical. Increased Contrast retains roles and hue while resolving structural boundaries to `{stroke.emphasized}`, strengthening text separation, control boundaries, and redundant cues. It is not a repair mode for an inaccessible default.
- **Reduce Transparency:** Native neutral materials resolve to `{surface.chrome}` and transient materials resolve to opaque `{surface.transient}`. State-bearing colors remain stable.
- **Reduce Motion:** Remove large region transitions, simulated depth, parallax, spring behavior, looping/decorative animation, and animated status indicators. Use immediate changes or a restrained fade only when useful. Static text, symbols, and values preserve all meaning.
- **Keyboard Path:** Full Keyboard Access follows visible region order. Every action is reachable, system focus stays visible, and dismissing a sheet, popover, alert, confirmation, or menu returns focus to its invoker.
- **VoiceOver:** Icon-only actions expose meaningful labels; status/activity expose textual descriptions; reading order follows visible hierarchy; dynamic state changes provide concise announcements without relying on animation.
- **Color-independent status:** Every meaningful status combines semantic text and at least one of symbol shape, border, position, or pattern in addition to color. Progress includes text or a value.
- **Inactive windows:** Preserve text contrast, selection meaning, status cues, labels, and focus visibility while reducing nonessential hover/chrome emphasis.
- **Long-session comfort:** No flashing or decorative looping animation; surfaces remain stable; density is comfortable-compact; accent stays sparse; essential information never depends on a 10 pt caption.

Combined validation MUST cover default and Increased Contrast × normal and Reduce Transparency × normal and Reduce Motion, plus VoiceOver and Full Keyboard Access, at the Reference Canvas and Minimum Operable Window across representative recipes. Narrow Navigation and selection changes retain location, selected treatment, scroll position, and input even when motion is immediate.

## Customization

An application customizes Graphite Focus only through a versioned Application Profile. Allowed Extension Points are:

- product information architecture and content;
- selected or additional Screen Recipes;
- product-specific semantic components with complete Native Mapping and State Applicability entries;
- semantic-token specialization that preserves role meaning and accessibility;
- justified platform/product exceptions.

A profile MUST NOT redefine component meanings, State Axes, Region Collapse Order, native focus behavior, accessibility accommodations, Contract Precedence, or the distinction between selection and status. It MUST NOT silently replace a shared role with a literal.

Every exception record MUST include: unique ID, affected rule, reason, bounded scope, replacement behavior, accessibility evidence, and review condition. “Brand preference” alone is not sufficient. A repeated exception is a candidate for explicit contract revision, never an automatic new convention.

## Acceptance

Conformance requires both layers:

### Structural Checks

Automated checks MUST reject:

- absent or invalid front matter, required sections, schema, or semantic version;
- duplicate or undeclared token IDs and broken braced token references;
- incomplete Native Mapping rows or missing mappings for declared components;
- missing State Applicability coverage or unknown components;
- Application Profiles with incompatible versions, forbidden override claims, unknown token references, or incomplete exceptions;
- newly introduced literal visual values outside this contract or a profile's documented native-control exception.

`scripts/validate-graphite-focus-presentation.py` scans every active `Sources/Stillmatter/*.swift` file except the two shared presentation providers; its line-level checks reject direct NSColor/SwiftUI RGB and native font literals, SwiftUI fixed font sizes/spacing/radii, and numeric AppKit spacing/radii. A necessary native-control geometry or fixture literal requires an inline `// graphite-focus-native-exception: <specific reason>` on that line. Semantic status colors and provider values are defined only in the shared layer. This is a structural guard, not a Swift parser or exhaustive visual audit. Structural Checks prove document integrity, not visual quality.

### Experience Review

A human MUST evaluate Structured Workbench, Precision Ledger, Settings, Search, Empty State, and Modal/Transient recipes at 1200×760, 720×520, and 1440 pt width where relevant. Review hierarchy, scanability, native macOS character, action clarity, density, resizing, keyboard use, VoiceOver meaning, accessibility combinations, inactive-window state, and Long-Session Comfort. Confirm panels and accent are restrained, prose has comfortable measure, structured data uses available width, and technical diagnostics do not dominate primary work.

Only a passing Structural Check and Experience Review permit a conformance claim.

## Do and Don't Constraints

**Do**

- Use native controls, system focus, menus, keyboard conventions, SF Pro, and SF Symbols.
- Use Surface Ladder roles and Structural Strokes to establish hierarchy.
- Keep one Principal Action and distinguish secondary, quiet, and destructive actions.
- Pair status color with text and another cue.
- Preserve capability and in-progress state across resize and collapse.
- Constrain prose and forms while allowing structured data to use width.
- Record genuine contract gaps and profile exceptions explicitly.

**Don't**

- Don't create decorative gradients, pervasive glass, ordinary-content shadows, floating shell cards, or excessive rounding.
- Don't replace native focus with custom glow or use accent for focus, every selection, success, warning, and brand decoration.
- Don't create generic Card, Tile, Hero, or Pill abstractions.
- Don't use color, transparency, or motion as the sole carrier of state.
- Don't crowd the toolbar or make it the only route to a command.
- Don't hide capabilities, lose state, or introduce mobile/bottom navigation at narrow widths.
- Don't copy another product's brand, exact palette identity, taxonomy, copy, icon assignments, or screen composition.
- Don't treat Structural Checks, screenshots, or pixel matching as substitutes for Experience Review.
