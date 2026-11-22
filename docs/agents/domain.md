# Domain and product documentation

This repository uses one root glossary and feature-oriented documentation.

## Before a feature change

1. Read [CONTEXT.md](../../CONTEXT.md) for business meanings and [product/INDEX.md](../product/INDEX.md) for coverage and the relevant feature reading path.
2. Read the relevant current feature document. For UI changes, also read [UI_PRINCIPALS.md](../UI_PRINCIPALS.md) for shared composition, controls, tokens and interaction rules.
3. Read relevant [ADRs](../adr/) and the task's approved spec/tickets. Future ToDo work also requires [its integration review](../planned/TODO_INTEGRATION_REVIEW.md); unresolved conflicts are not permission to override current Meeting behavior.

## Ownership and disagreement

CONTEXT.md is a compact glossary: meanings, natural groupings and useful avoided synonyms. Behavior and implementation details belong in feature docs. Shared UI rules belong in UI_PRINCIPALS.md. ADRs explain consequential tradeoffs; a future-capability ADR does not establish implemented behavior.

Current docs describe verified implementation. Specs and tickets describe intended work. Check disagreements against source, tests and accepted amendments; surface ADR conflicts explicitly. Historical documents under `docs/archive/` preserve evidence and rationale and are not active instructions.

Present apparent bugs, unmet requirements and unresolved contradictions to the user before creating issues from a documentation review. Preserve the agreed distinction between a correction, existing work and a new issue. Keep unreviewed future integration decisions in the planned review document.

## Completing a change

Update affected feature docs whenever behavior or feature-specific UI changes. Update UI_PRINCIPALS.md when shared UI rules change, CONTEXT.md when meanings change, and INDEX.md when coverage or reading paths change. Keep each rule authoritative in one place and link to it elsewhere.

Use glossary vocabulary in code discussions, proposals, issues and tests. Propose missing business concepts when needed; avoid adding general programming terminology to the glossary. Record an ADR when a hard-to-reverse decision involves a real tradeoff and its rationale would otherwise be surprising.

Before completion, verify changed documentation against the implementation, check links and run relevant existing validators. State verification limits honestly; automated checks do not establish device behavior or model quality.
