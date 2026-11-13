# Grouped upload Release profiles

All eight diagnostic trials validate independent payload digests and saved-state
reopening. Both engines' four prescribed workloads are profiled separately from
timing acceptance. All 94 production-source hashes and the package match the
completed grouped-upload full matrix.

| Swift workload | Running samples | Missing backtraces | fstatat/openat/close, flat | Layout scans, inclusive |
| --- | ---: | ---: | ---: | ---: |
| Many-file hybrid download | 8,980 | 19 | 45.1% | 33.5% |
| Single-file v1 download | 3,655 | 43 | 26.0% | 2.7% |
| Single-file hybrid download | 4,494 | 26 | 22.4% | Below reported top symbols |
| Single-file v1 seeding | 2,493 | 0 | 4.5% | 2.3% |

Inclusive weights overlap; sample weights are statistical, not function CPU
durations. Missing backtraces remain in denominators. Native v1 download has
377 unavailable backtraces out of 1,813 Running samples (20.8%), limiting detailed
attribution. All native counts remain in JSON; no capture is retried or omitted.
No acceptance claim follows from these instrumented trials.

Swift many-file write operations account for 47.2% inclusive sample weight;
request selection is 1.3%. Seeding sendPieces is 3.8% inclusive, versus 6.2%
in the earlier profile, but these independent captures are not causal timing
estimates. Stored-byte SHA-1 compression remains 18.6% flat in seeding.

Source inspection confirms a full-layout scan before each write batch, with
further scans before/after verification. Writes already enter bounded jobs,
yet repeated metadata inspection covers more files than the writes touch.
The next experiment will narrow write invalidation to touched files while
preserving full verification, snapshot, checkpoint and filesystem barriers.
Existing per-block identity/link checks, cancellation and stored-byte hashing
remain required. This differs from the rejected faster-scanner experiments.

[Attribution, process measurements and raw hashes](upload-publication-profiles-2026-11-13.json)
retain evidence. Raw traces remain under `.build/benchmarks/upload-publication-profiles`.
