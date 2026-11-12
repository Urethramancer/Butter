# CPU profiles after grouped upload workers

Production `61584b7`, evidence revision `d328e1a`, passes ten profile-only
trials: both engines in the four standard cases plus many-file v1 seeding.
Independent streaming digests and saved-state reopening pass in every trial.
These instrumented measurements are separate from timing acceptance.

Time Profiler attaches to the tested PID while both drivers are ready; its
notification gates start. Capture stops after durable completion. Only Running
samples for that PID are analysed; unavailable backtraces remain in the totals.
The native counterpart is uninstrumented, with separate wall/user/system phase
measurements. Source/build flags, machine/cache conditions and fixture hashes
are recorded in each environment file. All archived source hashes match the
retained production source.

| Case | Swift/native Running samples | Swift durable user/system s | Native durable user/system s |
| --- | ---: | ---: | ---: |
| Single v1 download | 2,908 / 1,547 | 1.476 / 1.502 | 0.857 / 0.726 |
| Single hybrid download | 3,503 / 2,319 | 2.076 / 1.512 | 1.539 / 0.858 |
| Many hybrid download | 6,806 / 2,339 | 3.069 / 3.808 | 1.529 / 0.901 |
| Single v1 seed | 2,739 / 1,565 | 1.554 / 1.224 | 0.354 / 1.286 |
| Many v1 seed | 4,134 / 1,915 | 2.014 / 2.270 | 0.398 / 1.612 |

Each row contains one trial per engine, not a timing median. Instrumentation
overhead applies. Complete counterpart phase durations are in the
[phase CSV](upload-groups-profile-phases-2026-11-12.csv); setup, persistence,
shutdown, whole-process accounting and all events remain in raw trials.

In single-file seeding, global task enqueue is 2.4% inclusive, compared with
5.7% in the [fresh pre-change profile](upload-scheduling-profile-2026-11-12.md).
Upload task work is 8.8% inclusive, group completion 6.6%, and admission 3.2%.
Flat SHA1 is 17.9%, worker-thread startup 11.9%, Mach messages 8.2%, send 5.3%
and copying 5.3%. Inclusive costs overlap; fractions cannot be added or treated
as a causal estimate of the timing improvement. The separate source comparisons
establish the [measured CPU reduction](upload-groups-results-2026-11-12.md).

Many-file stamp inspection remains material: 33.1% inclusive for hybrid
download and 38.6% for v1 seeding. Flat `fstatat` is 20.8%/25.3%, respectively.
Many-file download also spends 16.4% flat in `openat`, while the write operation
is 39.4% inclusive. These costs overlap stamp/hash/read/write call trees.
The next investigation should batch available filesystem work while retaining
ownership checks, full verification, independent cancellation and resource caps.

Single-file v1 download has flat SHA1 16.8%, write 11.6%, close 6.8% and copying
6.1%; hybrid download has SHA256 13.1%, SHA1 12.8%, write 8.9% and copying 7.6%.
Native download profiles principally show accelerated hashing and disk/network
calls. Native seeding profiles principally show read/send and pthread
coordination. Kernel waits attributed to Running samples are retained as
reported. Missing native backtraces peak at 6.2% (single v1 download); all five
Swift profiles have none. These limitations constrain attribution.

Raw exports, analysed weights and checks are in
[`raw/upload-groups-standard-profiles`](raw/upload-groups-standard-profiles)
and [`raw/upload-groups-many-seed-profile`](raw/upload-groups-many-seed-profile).
Successful profiler logs and binary trace bundles are removed after preserving
the XML exports. Across the 84 timing trials there are 119 distinct native
completion notices and no other peer diagnostics; the ten profile trials add
two completion notices. All original phase repetitions are preserved, with
first-reported-phase summaries in each raw folder's `diagnostics.json`.
Reported phase is not an inferred occurrence time.

The [earlier full-candidate profiles](window31-profiles-2026-11-12.md) and all
full-run regression samples remain intact. This profile set does not resolve
their sequence/environment cause, establish CPU parity or replace the final
matrix and release acceptance.
