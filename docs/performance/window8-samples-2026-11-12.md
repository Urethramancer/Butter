# Eight-request diagnostic captures

All eight captures validate payload digests and saved-state reopening for both
engines in single v1 download, single v1 seeding, single hybrid download and
many-file hybrid download. All 94 production source hashes match `40bb54f`.

These are two-second thread-stack samples, including waits, rather than Running
CPU percentages. Sustained host load of 11–18 and concurrent game/compiler work
were observed. Swift's first download took 316 seconds. These data are diagnostic
and must not replace the quiet-host comparison or establish performance gains.
Captured storage stacks include write operations, descriptor/path inspection,
stored-byte hashing and worker scheduling. They support investigating redundant
per-block descriptor checks while preserving full-layout and path safeguards.

The preceding Time Profiler run contains three readiness/finish deadline failures
and one capture interrupted when its controller was stopped. Owned children were
reaped; no system Instruments service was restarted. Every record remains.
Reliable fresh Running profiles, final timing and native acceptance remain open.

[Sample summary and raw hashes](window8-sample-summary-2026-11-12.json) and
[Instruments failures](window8-profiler-failures-2026-11-12.json) retain compact
evidence. Raw samples, phases, metadata and failure logs remain locally in
`.build/benchmarks/window8-current-samples` and
`.build/benchmarks/window8-current-profiles`.
