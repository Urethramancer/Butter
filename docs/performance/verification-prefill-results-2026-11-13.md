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

Broader source comparisons, native interoperability and the final full matrix
remain pending. This is focused evidence, not release or parity acceptance.

[Measurements, validation logs and raw hashes](verification-prefill-comparison-2026-11-13.json)
retain the evidence. Raw trials remain in
`.build/benchmarks/verification-prefill-many-hybrid-source-order`.
