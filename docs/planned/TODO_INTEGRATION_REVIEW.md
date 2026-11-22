# Future ToDo integration review

Status: unresolved future integration decisions, reviewed with the user on 2026-11-21. Preserve for later review; no implementation issues have been created from this list. The user approved documenting current behavior separately from future plans.

The [supplied ToDo spec](TODO_SPEC.md) is the approved future ToDo baseline. It does not silently supersede [current Meeting behavior](../product/MEETING_FEATURE.md) or applicable [ADRs](../adr/). ToDo-only choices already settled in that spec are not reopened here.

## Agreed distinctions

- **Today overview** is the current app overview. **Today planning** is the future manually selected `+today` subset of Active tasks, independent of Due Date and persistent while unfinished. Keep both concepts distinct.
- Current **Queue** priority comes from position. Future Active/Today lists use explicit P1/P2/P3, Due Date and creation-ID sorting. This is a planned change, not a current bug.
- **Project** means a special Tag used to group tasks. Current ordinary tags have no Project designation; older Meeting Project files/metadata are separate legacy functionality. The implementation gap is acknowledged, not a new issue.
- Current local transcription and optional approved ChatGPT text analysis are accurately documented in the Meeting feature. Local grounded analysis is unsupported. Future requirements must not be presented as working capability.

## Decisions still requiring review

| Area | Current contract | Future ToDo contract | Decision to resolve before implementation |
|---|---|---|---|
| Approval location | Pending items stay in their Meeting; Today has one reminder per Meeting | Personal pending items appear in Needs Approval | Whether both review surfaces coexist, and how shared review state and other/unknown owners behave |
| Canonical identity | One canonical Action Item shared across views; note tasks remain canonical in My Notes | Separate Task and Action Item identities, linked by stable metadata and synchronized | Reopen ADR-0002 explicitly if adopting linked records; define note-task authority and deduplication |
| Cross-file safety | Existing artifact transactions support recovery | ToDo bridge accepts no journal or crash recovery across two files | Scope the accepted weaker guarantee to the new bridge; decide what happens to existing stronger guarantees |
| SQL boundary | Markdown content; SQLite operational Jobs/Inbox and derived indexes | Broad no-SQL/workspace wording | Clarify ToDo persistence versus the application's operational infrastructure |
| Paths and codecs | `Todos/todo.md`, current Meeting folders and UUID metadata | Root `todo.md`/`trash.md`, new IDs and token namespaces | Define task migration and stable linkage; Meeting naming is expressly deferred in the future spec |
| Completed edits and archives | Archived Meeting content is read-only | Completed ToDo titles and other fields remain editable | Define permitted linked edits when the source Meeting is archived |
| Task deletion and restore | Same canonical item; archived content cannot be edited in app | Deleting an accepted ToDo removes its Meeting Action Item; restore does not recreate it | Define behavior for archived sources and preserve explicit authority/lifecycle rules |
| Whole Meeting deletion | Planned comprehensive deletion includes owned work | Missing Action Item preserves a Todo with stopped sync | Distinguish deleting one source Action Item from deleting its entire Meeting |
| Weekly Report archive | Personal tasks can remain canonical in Meeting/My Notes artifacts | Successful report publication removes completed ToDo records | Specify which record or projection is removed and what remains visible from the Meeting |
| Tag semantics | Shared global deletion and protected AI/review markers | No global ordinary-tag deletion; different namespaces and removable AI badge marker | Decide shared versus feature-specific controls and marker migration |
| External edit handling | Newer file wins while conflicting local drafts can be retained | ToDo discards unsaved editor text when the source changes | Keep any intentional feature-specific policy explicit in shared editor guidance |
| Legacy Meeting Projects | Project Markdown and Meeting metadata/filtering exist | Projects are dynamic task tags | Decide retention, conversion or removal of the older Meeting grouping concept |

Reject → Trash → Restore also needs integration clarification: determine the restored review state and treatment of durable rejection memory before a restored AI item can be approved or regenerated.

Dependencies matter: canonical identity must be settled before archive/deletion, Weekly Report removal and synchronization guarantees can be finalized. Keep these as open decisions rather than inventing resolutions during documentation maintenance.

## Review disposition

The user approved correcting broken links and obsolete UI documentation, retaining existing tickets for voice learning/retention/manual speaker splitting, and recording future Today/Project/priority behavior without duplicate issues. Significant rationale already lives in ADR-0001 through ADR-0004; no new consequential product decision was made by this cleanup.

Current baseline was compared with source, existing tests and recorded acceptance evidence. This review does not claim fresh device, permission, model-quality or release-wide validation.
