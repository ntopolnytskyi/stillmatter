# Ticket 12 — product-owner acceptance exceptions

The product owner explicitly authorized these ticket-12-specific exceptions in conversation. They do **not** change the coverage tooling, the default 95% incremental coverage contract for other tickets, or the final whole-source gate.

1. **Crash-boundary evidence deferred.** The kill-and-relaunch matrix at capture → finalization → Job boundaries is not required to accept ticket 12. Existing synthetic restart and recovery tests remain evidence for the specific paths they execute. Do not describe untested crash boundaries as verified. Address an observed failure later as a bug.
2. **Incremental coverage accepted at the observed level.** The fresh four-lane report against `f890bcb` at `.build/coverage/ticket12-request-incremental-20261107.json` measures **632/708 changed executable lines (89.27%)**; the unchanged automated 95% gate **fails**. The owner accepts that measured level for ticket 12 instead of requiring a passing 95% report. Do not label the gate passing, delete uncovered shipping lines, exclude shipping adapters, or apply this waiver to other tickets.

The owner's prior real-call A→B continuity verification is accepted for ticket 12 and must not be repeated for this ticket. These exceptions do not establish ScreenCaptureKit scope/permission behavior or resolve ticket 02's independent acceptance criteria.
