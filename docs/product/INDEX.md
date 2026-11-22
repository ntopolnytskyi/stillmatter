# Product documentation

Current behavior baseline: repository source and existing verification evidence, reviewed 2026-11-21. This is a source review, not a new real-device or model-quality validation run.

## Reading paths

| Change or question | Read |
|---|---|
| Product requirements and agreed direction | [PRD.md](PRD.md) |
| Business terminology | [CONTEXT.md](../../CONTEXT.md) |
| Meeting capture, processing, review or lifecycle | [MEETING_FEATURE.md](MEETING_FEATURE.md) |
| UI composition, controls, visual rules or accessibility | [UI_PRINCIPALS.md](../UI_PRINCIPALS.md), then the relevant feature document |
| Why a consequential decision was made | Relevant [ADRs](../adr/) |
| Future ToDo implementation | [Planned ToDo work](../planned/INDEX.md), including unresolved cross-feature decisions |
| Build, run or verification | [README](../../README.md), [testing strategy](../development/testing-strategy.md) and [manual validation](../development/manual-validation.md) |

## Coverage and boundaries

- Meetings and its Recording, Today overview, Tasks and Search integrations are covered in the Meeting feature document.
- Shared shell and UI rules are covered in UI_PRINCIPALS.md. Today, Tasks and Settings have brief screen descriptions there; they do not yet have complete standalone feature documentation.
- Search is an existing app capability, covered in the Meeting feature's integration section.
- The agreed meaning of **Project** is a special task Tag. Current generic tags and older Meeting project metadata do not yet implement that complete model; see the [planned integration decisions](../planned/TODO_INTEGRATION_REVIEW.md).
- The current **Today overview** and **Queue** are distinct from future **Today planning** (`+today`). Future priority sorting and task storage are not current behavior.

## Authority and maintenance

CONTEXT.md owns meanings. PRD.md owns consolidated product requirements and links to agreed feature requirements. Feature documents distinguish current behavior from explicitly labeled agreed changes. UI_PRINCIPALS.md owns shared UI rules. ADRs own decision rationale and applicable constraints; an ADR for a deferred capability does not establish that it is implemented.

Approved implementation specs and tickets describe work to deliver, including unfinished requirements. They do not prove shipped behavior. Planned cross-feature conflicts remain explicit until reviewed; a newer feature spec does not silently supersede another feature's contract or an ADR.

Verify a disagreement against source, tests and recorded acceptance evidence. Document verified current behavior and present apparent bugs or unmet requirements to the user before creating issues. Agreed documentation corrections and already tracked work do not need duplicate issues.

A behavior or UI change is complete when affected current docs, shared rules and glossary meanings are updated in the same change. Keep one authoritative description of each rule and link to it from related documents.
