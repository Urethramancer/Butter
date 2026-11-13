# Refill the existing window before verification

Candidate `e9aa57e` versus `49841a7`, many-file 1 GiB hybrid TCP download,
128 files, 256 KiB pieces and production request windows. Four warm-ups precede
six balanced source/engine pairs. All 28 trials validate independent payload
digests and saved-state reopening. No samples are retried or omitted.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.901 | 0.852–0.949 |
| Verified throughput | 1.059 | 0.999–1.116 |
| Peak RSS | 0.955 | 0.916–1.045 |
| Counterpart CPU seconds/GiB | 0.914 | 0.811–0.924 |

CPU falls reproducibly by 9.9%; throughput and memory changes are inconclusive.
No measured cost is established, but these intervals do not prove absence of
cost. Raw Swift medians are 11.476 → 10.193 CPU seconds/GiB and
99.7 → 107.6 MB/s. Candidate/native CPU remains 3.753 [3.692–3.998] and
verified throughput 0.239 [0.220–0.244], far from parity. Native control CPU
is inconclusive; its throughput rises 1.1% [0.2–8.2%], retained separately.

The change refills the current peer's existing request window after writes
finish, before ready-piece verification. Only unrestricted TCP with authenticated
wanted hashes uses it. Requests retain ordinary send timestamps and deadlines;
the eight-request default, disk admission limits, queues and caches remain.
Stored-byte hashing, filesystem checks and completion still await verification.
No reader task, additional buffer or backend is introduced.

The new scalar/batched overlap test fails on unchanged production and passes
on the candidate with the periodic ticker held still. It checks the next piece
is requested within the existing window while verification holds the sole disk
permit, without publishing piece completion. All 356 package tests, eight
focused tests under each sanitizer and Release build pass.

## Broader checks

Two further fixed six-pair source comparisons each validate all 28 trials,
bringing source timing coverage to 84 accepted trials with no failures.

| Workload | CPU ratio [95%] | Throughput ratio [95%] | RSS ratio [95%] | Counterpart CPU ratio [95%] |
| --- | ---: | ---: | ---: | ---: |
| Concurrent hybrid download | 0.915 [0.875–0.947] | 1.105 [0.972–1.254] | 1.014 [0.917–1.105] | 0.858 [0.756–1.044] |
| Single-file v1 download | 0.937 [0.847–1.003] | 1.008 [0.912–1.121] | 0.994 [0.947–1.058] | 0.865 [0.704–1.046] |

Concurrent CPU falls reproducibly by 8.5%; single-file CPU is inconclusive.
Neither case establishes throughput, RSS or counterpart CPU changes. In
particular, the concurrent RSS interval includes a 10.5% increase relative
to the preceding source, so a memory cost has not been ruled out. Native
controls' intervals cross one in both cases. No null is extended or retried.

The unfiltered native suite exits successfully with 466 PASS records, including
bidirectional transfers, TCP/µTP, encryption, selective storage, fragmented
IPv4/IPv6, session discovery and web seeds. The historical µTP timeout passes
with unchanged deadlines; its original cause remains unexplained.

Application contract and lifecycle suites pass, including numeric snapshots,
shutdown/persistence deadlines and completion moves. Native storage records
52 passes covering killed-process recovery, real ENOSPC, failed publication,
checkpoint retention and read-only volumes. Unsigned Debug/Release application
builds, linkage/licence checks and the unchanged repeat build pass. The user's
Xcode edits remain untouched; no tag is created.

The [fresh profiles](verification-prefill-profile-2026-11-13.md) validate both
engines and remain consistent with lower write-side work; they do not prove
call-count changes. Filesystem checks/opening remain the largest gap.

The candidate remains provisional. Broader format coverage and the
final full matrix remain pending; wide throughput and memory intervals are
inconclusive. This is focused evidence, not release or parity acceptance.

[Measurements, validation logs and raw hashes](verification-prefill-comparison-2026-11-13.json)
retain the evidence. Raw trials remain in
`.build/benchmarks/verification-prefill-many-hybrid-source-order`.
