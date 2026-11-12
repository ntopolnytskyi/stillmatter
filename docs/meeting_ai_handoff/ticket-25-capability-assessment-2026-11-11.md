# Ticket 25 capability assessment — updated 2026-11-12

Ticket 25 remains **incomplete**. On 2026-11-12 the user amended its scope: use Pi RPC with the installed ChatGPT sign-in after explicit transfer approval. The implementation below adds this route, but a synthetic live ChatGPT smoke test settled with provider failure. The feature cannot be claimed working until provider/auth behavior, real output quality, and remaining acceptance tests pass.

## Current implementation

Settings now has a persisted, default-off approval explaining that Transcript and My Notes are sent to ChatGPT through the installed Pi sign-in; audio, voice profiles, search content and unrelated workspace files are excluded. Older settings decode with approval off. A typed `MeetingAnalysisContext` permits only Transcript and optional My Notes. The worker checks approval before launching Pi, runs tool-free RPC with ambient context disabled, asks for English artifacts, waits for `agent_settled`, and rejects aborted, errored, incomplete or invalid output before app-side validation/publication. Runtime configuration includes the resolved Pi executable, so Retry rebuilds the handler after Pi is installed. Pi credentials are not copied into app settings or logs. Turning approval off prevents a later request; active-request revocation behavior is not yet verified. The generic Pi worker now uses this gated RPC behavior.

## Capability constraint

Local analysis remains unsupported. Qwen2.5-1.5B Q4_K_M (SHA-256 `6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e`) failed grounded outcomes and quoted-instruction schema checks; grounded generation stopped at the token limit. Qwen3-4B Q4_K_M (SHA-256 `7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5`) produced invalid grounded/quoted outputs, and its clarified-prompt retry timed out at 180 seconds during grounded generation. Reports use synthetic text only and are stored under `/private/tmp/stillmatter-meeting-ai-03-analysis-*`. These failures motivated the user's explicit ChatGPT scope amendment; they are not evidence that a hosted provider meets the quality gate.

Reference: [ticket 03 local capability contract](local-capability-contract.md), especially its local Pi analysis result and the remote smoke-test limitation.

## Executed verification

- `swift test --filter 'PiCodexWorkerTests|AppSettingsTests|MeetingSummaryTests'`: 30 passed, including RPC framing, approval denial, supplied-context limits, provider failure redaction, malformed/aborted/unsettled responses, output limits, shutdown timeout and cancellation.
- Full package coverage lane: 482 passed, 4 skipped, 0 failed. Hosted AppKit/runtime lane: 10 passed, 0 skipped or failed. Its UI interaction checked the transfer disclosure, default-off state, selection and persistence; runtime tests checked approval, required configuration, and Pi installation followed by Retry.
- Combined incremental coverage against `ae8c03c`: **264/267 executable changed lines (98.88%)**, passing the 95% gate. Reports: `/private/tmp/stillmatter-ticket25-package-reviewfix/report.json` and `/private/tmp/stillmatter-ticket25-hosted-reviewfix/report.json`. Whole-source coverage remains ticket 50's gate.
- Live Pi RPC with a synthetic-only prompt: acknowledgement and `agent_settled` arrived, but the assistant's final stop reason was `error`; it supplied no assistant error text. Pi diagnostics were withheld and no Meeting content was sent. The failure cause remains unknown. The earlier premature-stdin-close attempt did not settle; the corrected runner now has passing subprocess lifecycle tests.
- Still not verified: successful ChatGPT inference or English-output quality, language validation of returned artifacts, budget exhaustion, silence, late-meeting coverage, missing/unknown owners and dates, restart checkpoints/run identity, retry-only-failed-stage, active grant revocation, and long-recording input/output budgets. This is not a complete ticket result.
- UI expectations were verified through the hosted AppKit interaction test. No separate manual end-to-end UI automation was run.

## Remaining acceptance work

Diagnose why the installed ChatGPT provider returned an error, then run synthetic grounded-output quality cases through the finished app RPC path. Add the missing partial-stream, budget exhaustion, silence, late-meeting, ownership/date, restart/checkpoint, grant-revocation and long-recording cases. Keep app-side citation/source validation and publication atomic. Do not mark ticket 25 complete until provider success and quality, these behavior tests, and the remaining acceptance cases pass. Local grounded analysis remains unsupported.
