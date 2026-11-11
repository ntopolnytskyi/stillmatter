# Ticket 25 capability assessment — 2026-11-11

Ticket 25 remains **incomplete**. This assessment records the verified implementation gap and tests; it does not claim the required local grounded-analysis capability.

## Current implementation

The generic `PiCodexWorker` still launches Pi in print mode with hard-coded `openai-codex` / `gpt-5.5` and whole-vault read tools; it is not safe for the required Meeting analysis. Production Meeting workflow no longer wires this worker. `ProcessingRuntime` now uses its existing fail-closed handler: a fully local analysis provider is required, the recording and Transcript are retained, and no Meeting text is uploaded. The app does not yet provide a verified local analysis provider or a complete configuration route, so this protects privacy while leaving Summary generation unavailable. The summary executor's citation validation and app-side artifact application remain in place for a future compliant provider.

## Capability constraint

The resolved ticket 03 evaluation found the only tested local analysis model unsuitable for production grounded analysis: mixed-language outcomes had incorrect owners, missing citations, untranslated text, and invalid schemas. No stronger local model has passed the required grounded-output quality lane. A remote provider or the rejected model cannot be presented as satisfying ticket 25. Until a suitable local provider and RPC lifecycle pass the required evaluation, local grounded Summary and outcomes are unsupported; the app must surface provider/setup failure and offer Retry without remote fallback.

Reference: [ticket 03 local capability contract](local-capability-contract.md), especially its local Pi analysis result and remaining requirements.

## Executed verification

- `swift test --filter MeetingSummaryTests`: 9 passed, 0 failed.
- `swift test`: 474 passed, 4 skipped, 0 failed before the AppDelegate fail-closed wiring change; package tests do not compile that app-only file.
- Existing behavioral tests cover validated artifact publication, citation checks, note-task identity, preservation, regeneration, and timeout/retry. They use synthetic responses and do not verify RPC settlement, scoped prompt contents, local model selection, or real-model output quality.
- Scenario disposition: malformed/undeclared worker outputs and unknown citation IDs are covered; partial RPC streams, acknowledgement/interleaved-event/settled/abort lifecycle, explicit token/context-budget exhaustion, silent-meeting analysis, late-meeting evidence coverage, unknown/missing owner/date uncertainty, and restart persistence of validated checkpoints/run identity with failed-stage-only retry are **not verified**. Existing fixture citations exercise the second of two short segments, not a long-recording tail-coverage case. The RPC subprocess suite required by ticket 25 has not been added or run.
- UI tests skipped because no UI code changed.
- Hosted coverage attempt for `ProcessingRuntimeHostedTests` failed during Xcode compilation because the filesystem ran out of space while writing its module cache (`No space left on device`); it produced no passing coverage report. Its failed generated directory was removed after approval, freeing 268 MB. The AppDelegate change only removes executable code, so there are no added executable Swift lines; however, the incremental coverage report was not produced and is recorded **unverified**, not passed. The final whole-source 95% gate remains assigned to ticket 50 and was not rerun here.

## Remaining acceptance work

Implement a supported local provider configuration route, then Pi RPC with settled-generation/error/cancellation handling, supply only explicitly permitted per-run Transcript/My Notes/context with tools disabled, and add the missing restart/checkpoint, budget, silence, long-recording tail, ownership/date, and local quality cases. Keep app-side citation/source validation and publication atomic. Do not mark ticket 25 complete until those requirements, the fail-closed hosted behavior, its coverage gate, and its remaining tests pass.
