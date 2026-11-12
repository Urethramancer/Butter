# On-CPU transfer profiles — 12 November 2026

Production source `1931e70` was profiled with Instruments Time Profiler in
the existing comparison harness. All eight profile-only trials passed payload
digest and state-reopen checks: v1 and hybrid single-file downloads, hybrid
128-file download, and v1 single-file seeding, for Swift and libtorrent.
A preceding two-trial many-file capability run also passed and is retained.
These instrumented trials do not replace the full matrix or its acceptance
results. CPU parity remains unmet.

Both drivers wait at ready while Instruments attaches to the tested process.
An Instruments notification gates transfer start. The counterpart is not
instrumented; its phase CPU remains recorded. Recording stops after durable
completion. TOC and sample XML, source fingerprints, phase accounting and
target-filtered `.cpu.json` summaries are retained. Summary percentages use
Running sample weights, not exact CPU durations; inclusive symbols overlap.
Samples without a backtrace remain in the denominator. Native unavailable
backtraces reach 6.9% in single-file v1 download; Swift's maximum is below 0.1%.
Binary trace bundles are disposable build output.

In the four-case run, Swift's many-file hybrid download spends 35.3% of sample
weight under `StorageState.stamps()`, with 22.0% flat in `fstatat`, 12.3% in
`openat` and 4.7% in `close`. The corresponding native trace concentrates
40.3% in SHA1/SHA256 compression. Filesystem ownership and modification checks
remain required; these percentages do not authorise removing them.

Swift single-file hybrid download spends 14.1% under `requestHashes`, including
14.0% under set subtraction. The method repeatedly computes wanted minus
authenticated pieces even when every wanted piece already has authenticated
hashes. This identifies an allocation to avoid before changing pipeline limits.
Picker allocation is separately visible at 9.3%; its endgame set computation
must not be confused with the hash-request caller.

Swift v1 seeding has SHA1 compression at 15.8% flat and memory movement at
5.4%; scheduling/system transition frames also remain prominent. These short
profiles identify candidates for separate timing experiments, not improvements.

- [Four-case trials](raw/cpu-time-profiler-full/trials.jsonl),
  [environment](raw/cpu-time-profiler-full/environment.json),
  [checks and XML hashes](raw/cpu-time-profiler-full/checks.json).
- [Initial many-file trials](raw/cpu-time-profiler-many-hybrid/trials.jsonl)
  and [checks](raw/cpu-time-profiler-many-hybrid/checks.json).

Harness tests cover profiler readiness, early exit, startup/finish deadlines,
counterpart failure, process cleanup, XML reference resolution, process/state
filtering and unavailable stacks: twelve tests, 77 assertions pass.
