# Ticket 04 — canonical Markdown identity and migration contract

This is a tested **disposable prototype**, not a storage migration enabled in the app. The chosen contract below is an input to tickets 08 and 16. It does not establish production Swift coverage, native UI behavior, or model quality.

Run from the repository root:

```sh
python3 -W error::ResourceWarning -m unittest discover -s docs/meeting_ai_handoff/prototypes/markdown_identity -v
```

Recorded on 2026-11-01 with Python 3.15.2, macOS 15.8.1 (24H32): **21 tests, 0 failures**, using newly created temporary workspace and separate support directories, destroyed after each test. No user library, preferences, media, network, credentials, or inference runtime are accessed. The prototype and fixtures are under [`prototypes/markdown_identity/`](prototypes/markdown_identity/).

## Evidence from the existing implementation

The prototype fixtures use the formats currently written by Stillmatter:

- [`TodoItemParser`](../../Sources/StillmatterCore/TodoItems.swift) recognizes `-`/`*` checkboxes with open, `x`, `B`, and `C` markers, `due: YYYY-MM-DD`, wiki links, indentation, and child comments. Its current identity is `relativePath:lineNumber`, which cannot survive ordinary insertion or rename.
- [`ActionItemProposalReviewer.accept`](../../Sources/StillmatterCore/ActionItemProposalReview.swift) writes an edited title/source link to `Todos/todo.md`, then records acceptance separately. The copied Todo contains **no proposal ID**. A source link typically names the entire Summary section, not an individual outcome.
- [`TasksInbox.migrate`](../../Sources/StillmatterCore/TasksInbox.swift) creates `proposal_reviews(proposal_id,state,suppression_key,source_ref,title,updated_at)`. Scoped IDs have `owner:<canonical-workspace-path-UTF8-hex>:` prefixes. The prototype reads exactly these fields from an actual synthetic SQLite database opened read-only. Legacy unowned and another workspace's rows are not imported into a selected scoped workspace.
- [`MeetingCaptureService`](../../Sources/StillmatterCore/MeetingCapture.swift) writes `capture_session_id` and `## Live notes` into the doorway; [`MeetingManagementService`](../../Sources/StillmatterCore/MeetingManagement.swift) also accepts `## Notes` and writes `archive.json` with only `archived: Bool`. There is **no trustworthy archive date** to derive from those markers.
- [`TranscriptDocument`](../../Sources/StillmatterCore/Transcription.swift) writes schema-1 JSON with capture ID, source path, language/engine/model metadata, and segments containing `id,start,end,text,language,track,speaker`. Its Markdown derivative loses stable segment IDs and fractional timestamps; that derivative cannot be parsed back into exact source timing. The fixture includes overlapping microphone/system segments and Ukrainian/English text.

## Chosen canonical item representation

A checkbox is the only mutable item record. A compact versioned JSON comment on its line stores immutable identity and ownership/review/provenance metadata; ordinary tags and task prose remain visible Markdown:

```markdown
- [ ] Надіслати підсумок #робота <!-- sm-item:{"id":"2e0d15af-3969-44c8-991d-996bc1f25ed9","origin":"note","owner":"me","review":"approved","v":1} -->
```

- New items receive UUIDs on an explicit successful save/adoption. Reads never silently rewrite external files or mint ephemeral identities. An unadopted external checkbox is identifiable as awaiting adoption; production must make adoption a version-checked write and refresh projections afterward.
- Once assigned, the ID does not depend on task text, checkbox state, line number, folder slug, owner, or speaker label. Migration may derive an initial UUID from the **captured old snapshot location**, but it persists that UUID in the journal before any replacement; it is never recomputed after lines move.
- Note-authored tasks default to Me/approved. Generated tasks default to unknown owner/pending. `#need-approve` and `#ai-gen` are ordinary rendered tags, not permission to approve a task. Removing a tag cannot change the metadata's review state.
- State is the checkbox marker. Existing blocked/canceled markers round-trip instead of being discarded. Inline dates, tags, Unicode prose, bullet/indentation, child prose, and source references survive adoption and migration. No private vector or profile data belongs in this metadata.
- Meeting and Todo projections carry only item IDs. Every read/mutation resolves the current canonical file. Editing/completing from either projection updates one checkbox. Reassignment away from Me removes the item from the personal projection; deleting the checkbox removes it from all projections without resurrecting a copy.
- The Todo queue holds references such as `- [[item:<UUID>|display text]]`, **not second mutable checkboxes**. Reference labels are presentation hints, never task content authority. Existing independent standalone Todo items remain canonical in `Todos/todo.md`.
- Note-authored checkboxes remain in `my-notes.md`. Migrated Meeting-linked copied Todos move, with their edited text/status/comments, to `action-items.md`; their queue positions become stable references. Generated pending items are canonical in `action-items.md`.
- Duplicate IDs or malformed/version-incompatible metadata produce actionable errors, preserving bytes. Similar text with different IDs is valid. Erasing metadata deliberately removes identity; matching by title must not silently recreate the old item.

The prototype proves ID-based resolution after physically renaming a Meeting folder without creating an old-path alias. It does not implement the full controlled-reference rename transaction required by ADR-0001; that remains tickets 08/34.

## File conflicts and publication

An editor retains a base version and its draft. On save, if disk differs from that base, it keeps the current external file and persists **base, external, and local draft** in the isolated support directory. Reopening still exposes both versions. It does not guess a text merge or report a successful save.

Multi-file migration/pair publication uses a durable journal containing the complete intended replacements and exact previous bytes before the first write. Each file is replaced atomically; completion is published only after every output exists. Readers must consult the transaction state: a partial migration is not a successfully migrated Meeting. Reopen resumes the recorded plan/IDs; retrying a committed plan is a no-op. Unexpected external bytes block recovery/rollback and remain untouched; both planned and old versions remain in the journal for explicit resolution. The prototype tests interruption after **every** replacement, recovery by newly constructed journal objects, exact old-byte rollback, and external modification during partial migration.

This experiment uses fsync plus atomic replace. It does **not** claim OS-level compare-and-swap with an arbitrary third-party editor in the tiny check-to-replace interval, a hard kill/power-loss test, macOS file coordination, or multi-process locking. Production ticket 08 must use the workspace's coordinated/version-checked mutation boundary and durable transaction visibility. The journal also needs bounded retention and explicit recovery UI; this prototype intentionally retains backups rather than deleting recoverable data.

## Legacy migration policy and discovered constraints

1. Snapshot doorway, Todo file, extraction, scoped review rows, archive marker, and legacy Transcript. Preserve old source bytes/review rows in the recovery record.
2. Preserve `capture_session_id` as Meeting ID where present. If absent, allocate a UUID once in the prepared journal; do not infer identity from a later title/path.
3. Extract only the existing Notes/Live notes section, preserving prose and note checkbox content. Replace that doorway section with the explicit My Notes file link and preserve subsequent headings/content. Assign distinct persisted IDs even to duplicate-looking note tasks.
4. Preserve linked accepted Todo edits, dates, completion state, comments, source references, queue order, and canonical identity. Pending proposals retain the review title and citations; dismissed/reference-only/merged states remain in explicit legacy history.
5. **Do not claim that old accepted proposal ↔ copied Todo identity can be reconstructed.** The old format lacks that association, and a section link/title is insufficient when titles were edited, tasks duplicated, or proposals merged. Preserve the approved Todo as one canonical item, retain candidate references and original review/extraction evidence, and record unresolved mappings. Do not create a second executable approved item or a new pending duplicate from the old extraction. An explicit confirmed mapping can bind one or several old proposal IDs to that preserved UUID. The prototype proves both ambiguity preservation and explicit binding without text matching.
6. A nested Meeting-linked Todo block needs explicit migration review in this experiment. It fails before writes instead of flattening/dropping child tasks. Production must preserve hierarchical task structure and associated IDs, or keep the legacy representation readable until a supported migration is available. This is a reported prototype limitation, not permission to reject or lose valid legacy user content.
7. Preserve `archived: true`, but set archive time unknown and cleanup ineligible. Never derive an archive time from modification dates or start time and silently purge old evidence. A trustworthy explicit date or review is required by the retention implementation.
8. Leave the legacy operational SQLite database and unrelated workspace rows untouched during this prototype. Production must commit references/indexes/Job compatibility through its own durable recovery boundary before marking migration complete. This experiment does not claim it migrates all Jobs or indexes.

## Transcript text/JSON authority and round trip

Both files represent **one logical Transcript**, with a recorded last-synchronized document/version. The plain text contains a version header, shared metadata header, and tab-separated segment rows: stable ID, original start/end seconds, source track, language, speaker, utterance, and extension metadata. String cells are JSON escaped to preserve literal tabs/newlines/Unicode; this is readable plain UTF-8 text rather than a lossy rendered Markdown document. Unknown extension fields, including stable Person IDs and attribution evidence, round-trip.

- Starting from existing schema-1 JSON retains exact fractional timing, segment IDs, overlapping tracks, source/engine metadata, and language text. The old pretty `transcript.md` is a retained migration input/legacy derivative, not a second authoritative timed source. Production generates the new `transcript.txt` and updates controlled references while retaining recoverable prior bytes.
- A valid one-sided edit to `.txt` or `.json` is accepted and regenerates the other representation. This includes externally changed display text or identity metadata. There is no hidden database version that wins over a valid file edit.
- If both representations changed to the same logical document, they converge. If both diverged differently from the last synchronized version, preserve both and surface a conflict. Never silently pick the newer timestamp or rebuild one from unrelated stale content.
- Validate segment IDs, finite nonnegative ordered timing, source track, and text fields. Untimed prose cannot invent word/segment alignment. Empty/silent segment arrays remain valid. App Transcript content stays read-only as specified; external edits are explicit file edits and must have revision/provenance recorded in production.
- Publish consistent text/JSON pairs through the journal. A partial pair is not completed content. The prototype tests retry after only the text replacement and verifies exact logical equality after recovery.

## Observable verification and downstream scope

The 21 passing tests cover canonical projections, completion/ownership/removal, Unicode duplicate-looking tasks, immutable IDs after line edits and folder rename, approval-tag separation, malformed/duplicate IDs, persistent unsaved-draft conflicts, actual-format SQLite scope filtering, edited/completed legacy Todos, pending/dismissed/reference-only/merged history, unknown archive dates, legacy mapping ambiguity/confirmation, nested-task refusal without writes, every between-file interruption/restart, rollback, external edits during recovery, Transcript round trips/edits/conflicts/person metadata, and pair publication.

This ticket introduces **zero shipped Swift lines**, so there is no changed production denominator to claim at 95%. Python prototype tests do not contribute to the final whole-source Swift coverage numerator. Tickets 08/16 must port the tested contract to real workspace/operational stores, implement native edit/conflict/migration behavior, and independently pass the coverage gate and their UI expectations. Hardware/model evaluation is unrelated to this storage prototype.
