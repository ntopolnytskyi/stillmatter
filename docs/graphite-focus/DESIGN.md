---
schema: graphite-focus/v1
contract_version: 2.0.3
name: Graphite Focus
platform: macOS 13+
appearance: dark-only
status: canonical
---

# Graphite Focus

## Identity and Scope

Graphite Focus defines Stillmatter's native macOS visual language: graphite surfaces, warm text, and sparse violet accents. This file owns shared visual rules; the [Stillmatter profile](STILLMATTER_PROFILE.md) owns screen composition and product exceptions.

Rules are requirements unless marked optional. Resolve conflicts in this order: accessibility accommodations, native control behavior, semantic tokens, screen recipes, product specializations. Examples never override rules. The profile consumes the contract's major version; token references use `{surface.base}` syntax.

## Principles

- Use native controls, menus, focus, system typography, and SF Symbols.
- Build compact, readable layouts with opaque surfaces and quiet dividers.
- Give each task or section at most one principal action.
- Use panels for bounded workspaces such as editors, transport, and review. Ordinary detail stays in open sections or rows.
- Keep focus, selection, status, and progress distinct. Meaning must survive loss of color or motion.
- Preserve capability, selection, scroll position, and input when resizing.

## Tokens

Feature code consumes shared semantic roles rather than equivalent literals. Accessibility settings may change values while retaining meaning. All geometry uses macOS points.

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

Surfaces progress from base → chrome → panel → raised. Ordinary content is opaque and shadowless; materials belong only in native chrome or transient surfaces, with opaque fallbacks.

Violet is reserved for the principal action, current mode, links, progress, sparse identity marks, and contextual dense-list selection. Sidebar selection uses a neutral surface and one accent symbol. Status colors require text and a symbol or another non-color cue.

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

Use system fonts and SF Symbols. Caption and disabled text cannot carry sole essential information. Icon-only controls need accessible names and useful tooltips. Symbols are not app icons.

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

Native control geometry takes precedence; retain native hit targets and focus rings. Capsules are for metadata, status, and pill selectors. Prefer native motion; Reduce Motion uses immediate changes or a restrained fade.

## Native Mappings

System owns native interaction; app composes native primitives; contextual selects the appropriate primitive. Styling must preserve editing, enabled state, hit targets, keyboard behavior, and accessibility.

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

## Adaptive Shell

Reading order is toolbar → sidebar → optional list → detail → optional inspector → transient surface. Regions are flush, independently scrolling, and divider-separated. Toolbar stays fixed; page headers normally scroll.

| Region | Width | Behavior |
|---|---|---|
| Sidebar | 64 pt | Fixed icon rail; hideable; native Tab and Space/Return activation |
| List | 260–380 pt; ideal 300 pt | Only for selection-heavy work |
| Detail | At least 480 pt beside other regions | Fluid; forms and prose use their measure tokens |
| Inspector | 280–420 pt; ideal 320 pt | Optional, selection-following, normally closed |

Validate at **1200×760**, **720×520** (minimum), and **1440 pt** wide. Adapt when useful widths no longer fit: hide/present the inspector transiently, collapse the sidebar, then let list replace detail. Narrow navigation provides native Back and a location label. Preserve the user's sidebar preference when space returns.

Header titles truncate at the tail with full tooltip/accessibility text. Prose, errors, and essential status wrap. Secondary metadata may truncate with full text available. Actions retain native size and independent focus; crowded citations/filters wrap or use a named native menu. Never clip controls or essential information horizontally.

Toolbar commands also have menu routes. Area Search defaults to the current area and exposes scope, query, and filters. Tables and operational content use available width; forms and prose align leading within their measure tokens.

## Components and State Axes

| Family | Components |
|---|---|
| Structure | Window Toolbar; Page Header; Content Section; Section Header; Shell Region; Semantic Panel; Structural Divider; Contextual Inspector |
| Navigation and Data | Sidebar Item; Location Label; Segmented Mode Selector; Collection Row; Disclosure Row; Table; Outline; Selection Summary |
| Actions and Input | Primary Button; Secondary Button; Quiet Button; Destructive Button; Icon Button; Text Field; Search Field; Secure Field; Multiline Field; Checkbox; Radio; Toggle; Picker; Stepper; Date/Time Control; Form Row |
| Feedback and Status | Status Label; Metadata Tag; Count Badge; Progress Indicator; Inline Notice; Content State |
| Transient Surfaces | Menu / Context Menu; Popover; Sheet; Alert / Confirmation; Lightweight HUD |

The five independent axes are Interaction (hover, pressed, focus, disabled), Choice (selected/current/mixed), Meaning (information, success, attention/live, destructive), Activity (loading/progress/complete/unavailable), and Window Context (active/inactive).

| State | Treatment |
|---|---|
| Selected | Native selection; sidebar uses neutral surface plus accent symbol. Selection does not imply keyboard focus. |
| Ready/complete | Success role, explicit text, checkmark; product exceptions must be recorded. |
| Live/degraded/blocked/queued | Attention role, explicit text and distinct symbol; include stage when relevant. |
| Failed | Destructive meaning, explanation, next action; persist until resolved/dismissed. Do not steal focus. |
| Processing | Native progress, stage text, numeric value when determinate; motion is optional. |
| Unavailable/empty | Explain the condition and useful next action; distinguish from loading or failure. |
| Disabled | Native disabled control; explain why when unclear. |
| Destructive action | Clear verb and native role; confirm irreversible work. Live recording itself is attention. |

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

Rows support native selection, arrow navigation, and Return activation. Disclosure and trailing actions remain independently targetable. Status labels describe meaning, metadata tags describe content, and badges count; actions use native controls. Inactive windows retain readable content, selection, status, and focus meaning.

## Screen Recipes

### Structured Workbench

Page header, broad canvas, coherent sections, and interactive summary rows. Panels only for bounded workspaces.

### Precision Ledger

Native list/table beside detail; optional selection-following inspector. Narrow layouts switch between list and detail without losing state.

### Settings

Leading native form near `{measure.form}`; help and validation beside controls; destructive actions isolated.

### Search

Visible scope, query, and filters; result rows show kind, title, source, excerpt, and location. Selection previews or opens the owning area.

### Empty State

One explanation and useful next action in the owning canvas. Distinguish empty, loading, error, and unavailable states.

### Modal and Transient

Popover for brief anchored choices, sheet for focused edits, alert for confirmation, separate window for independent work. Restore focus on dismissal.

## Accessibility and Motion

- Default contrast: at least 4.5:1 for ordinary text and 3:1 for large text and controls; aim for 7:1 for small custom text. Increased Contrast strengthens boundaries and text separation.
- Reduce Transparency resolves chrome and overlays to opaque surfaces.
- Reduce Motion removes large transitions and decorative/looping animation; text and values preserve progress meaning.
- Full Keyboard Access follows visible order; every action is reachable with native focus. Transient dismissal restores focus.
- VoiceOver exposes names, selection, status, progress, and concise updates. Color alone never communicates state.
- Test combinations of contrast, transparency, and motion settings, plus active/inactive windows. Dark-only appearance does not waive these requirements.

## Customization

The application profile may define navigation, compositions, product components, token specializations, and bounded exceptions. It cannot override accessibility, native focus, state meanings, or collapse order.

Each exception records an ID, affected rule, reason, scope, replacement behavior, accessibility evidence, and review condition. Repeated exceptions require reviewing the shared rule.

## Acceptance

Run the contract and presentation validators listed in the [README](../../README.md). They check document structure, token references, mappings, state coverage, profile compatibility, and undeclared visual literals. Necessary native geometry literals require an inline `// graphite-focus-native-exception: <reason>`.

Structural checks do not establish usability. Review representative screens at all three validation sizes with long content, keyboard, VoiceOver, accessibility settings, and inactive windows. Check hierarchy, action clarity, resizing, retained state, and panel/accent restraint before claiming conformance.

## Do and Don't Constraints

Use semantic tokens and native behavior. Avoid decorative gradients, pervasive glass, ordinary-content shadows, floating shell cards, generic Card/Tile wrappers, custom focus glows, and mobile-style bottom navigation. Screenshots and automated checks do not replace experience review.
