# Ticket 25 capability assessment — 2026-11-11

Ticket 25 remains **incomplete**. This assessment records the verified implementation gap and tests; it does not claim the required local grounded-analysis capability.

## Current implementation

`PiCodexWorker` launches Pi in print mode with the hard-coded `openai-codex` provider and `gpt-5.5` model. It grants `read,grep,find,ls` against the entire vault. It does not use the selected Pi RPC interface, does not provide an isolated per-run context, and does not establish a local provider. The summary executor validates citations and applies declared artifacts through the application, but those safeguards do not make the provider local or the context scoped.

## Capability constraint

The resolved ticket 03 evaluation found the only tested local analysis model unsuitable for production grounded analysis: mixed-language outcomes had incorrect owners, missing citations, untranslated text, and invalid schemas. No stronger local model has passed the required grounded-output quality lane. A remote provider or the rejected model cannot be presented as satisfying ticket 25. Until a suitable local provider and RPC lifecycle pass the required evaluation, local grounded Summary and outcomes are unsupported; the app must surface provider/setup failure and offer Retry without remote fallback.

Reference: [ticket 03 local capability contract](local-capability-contract.md), especially its local Pi analysis result and remaining requirements.

## Executed verification

- `swift test --filter MeetingSummaryTests`: 9 passed, 0 failed.
- `swift test`: 474 passed, 4 skipped, 0 failed.
- Existing behavioral tests cover validated artifact publication, citation checks, note-task identity, preservation, regeneration, and timeout/retry. They use synthetic responses and do not verify RPC settlement, scoped prompt contents, local model selection, or real-model output quality.
- UI tests skipped because no UI code changed.
- The incremental 95% gate is not applicable: no shipped executable Swift lines changed (0/0). The final whole-source 95% gate remains assigned to ticket 50 and was not rerun here.

## Remaining acceptance work

Implement Pi RPC with settled-generation/error/cancellation handling, select and verify an appropriate local provider, supply only explicitly permitted per-run Transcript/My Notes/context with tools disabled, and pass the real local quality cases. Keep app-side citation/source validation and publication atomic. Do not mark ticket 25 complete until those requirements and its remaining tests pass.
