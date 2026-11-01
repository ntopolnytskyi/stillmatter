# Ticket 03 review

Reviewed changes from `b206d08` using `git diff b206d08...HEAD` against the approved spec and ticket 03. Separate Standards and Spec reviewers ran independently through the code-review skill. This review concerns research probes/evidence, not production capability approval.

## Standards

No hard documented-standard violations. Glossary, scope, privacy boundaries and explicit capability limits are consistent with the repository instructions. No material code-smell findings justify restructuring these disposable probes.

One measurement correctness finding: the speaker probe stored raw `ru_maxrss` as `peakRSSBytes`. Linux reports KiB, unlike Darwin's bytes, so reproduction there underreported memory by 1,024×. Normalize both speaker measurement locations consistently with the analysis/retrieval probes and test both platforms. Existing macOS evidence is unaffected.

## Spec

No actionable findings. Ticket 03's research scope is satisfied: actual local ASR, diarization, voice embeddings, analysis and retrieval were exercised with reproducible fixtures, model identities, settings, measurements and preserved failures. Synthetic RPC tests distinguish acknowledgement, settlement, malformed output and process failure.

Research completion follows the spec's instruction to produce constraints usable by dependent implementation tickets and report unsupported quality. The contract rejects the tiny analysis configuration and whole-clip mixed-language ASR as production-ready, leaves human/long-recording evaluation unverified, and preserves those requirements.

No UI or production Swift was introduced. Incremental coverage is correctly reported as N/A (0/0), while existing whole-source coverage remains 75.33% and fails the final gate. No unrelated ticket implementation or scope creep was found.

Standards: one measurement finding; zero hard standard violations. Spec: zero findings.

## Resolution

Commit `4b1545e` normalizes both speaker RSS measurements through `peak_rss_bytes()` and adds a mocked Darwin/Linux units regression test. The full probe suite passed 53 tests; the independent Standards reviewer confirmed resolution and ran all 13 speaker tests successfully. Existing macOS inference evidence is unaffected, so no model re-execution is claimed. Outstanding findings: Standards 0, Spec 0.
