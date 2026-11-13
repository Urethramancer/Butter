# Revised request-burst Release profiles

All eight diagnostic trials validate independent payload digests and saved-state
reopening. Both engines are profiled separately across the four prescribed
workloads. All 94 production-source hashes and the package match the completed
revised request-burst full matrix. Captures run from before transfer start
through durable completion; the counterpart is not instrumented. These are
diagnostics, separate from timing acceptance.

| Swift workload | Running samples | fstatat/openat/close, flat | Write operations, inclusive | Layout scans, inclusive |
| --- | ---: | ---: | ---: | ---: |
| Many-file hybrid download | 8,095 | 46.0% | 47.6% | 37.0% |
| Single-file v1 download | 3,543 | 22.2% | 34.7% | 2.6% |
| Single-file hybrid download | 4,498 | 20.3% | 30.5% | 2.3% |
| Single-file v1 seeding | 2,498 | 3.6% | Not on this path | 2.1% |

Inclusive percentages overlap. Swift unavailable backtraces number 18, 26,
25 and zero respectively. Native Running samples number 2,646, 1,693, 2,238
and 1,555, with 117, 285, 159 and zero unavailable backtraces. Missing samples
remain in denominators; the native v1 download's 16.8% missing backtraces limit
detailed attribution. No capture is retried or omitted.

Many-file instrumented whole-process Swift CPU is 3.28 user/4.96 system seconds,
including setup/shutdown. This is not timing-run CPU/GiB. Flat fstatat alone
accounts for 23.1% of Running sample weight. Request selection is only 1.4%
inclusive here, versus 3.1–3.3% in single-file downloads. Disk worker ancestry
is 81.3% inclusive in the many-file profile; that includes filesystem calls
and hashing, and must not be interpreted as scheduling overhead.

Stored-byte hashing remains visible in seeding (SHA-1 compression is 19.7%
flat). Upload encoding/output work remains smaller: sendPieces 6.2%, enqueue
4.1% and nextOutput 3.3% inclusive. Native seeding retains substantial read,
send and synchronisation work. Sample weights are statistical, not measured
function durations; thread-entry trampolines do not prove thread creation.
These profiles do not justify replacing per-wait timers or relaxing hashing.

Tracing the current storage path confirms full-layout scans before writes and
around verification, plus per-block leaf identity/link checks and bounded
per-job file descriptors. Filesystem work remains the largest download target.
Earlier parent-retention, UTF-8/C-string, descriptor-identity and read-buffer
experiments remain rejected; these captures do not reverse their measured
costs or null results. Any new experiment must remove different redundant work
and preserve external-modification and filesystem ownership behaviour.

[Attribution, process measurements and raw hashes](request-burst-profiles-2026-11-13.json)
retain evidence. Raw traces remain under
`.build/benchmarks/request-burst-profile-{many-hybrid-download,single-v1-download,single-hybrid-download,single-v1-seed}`.
No additional production change, parity or cost-free claim follows from profiling.
