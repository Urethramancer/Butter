# Grouped upload publication experiment

Candidate `afad9d1` versus `d37ffe5`: single-file 1 GiB v1 TCP seeding,
256 KiB pieces and production request windows. Four warm-ups precede six
balanced source/engine pairs. All 28 trials validate independent payload digests
and saved-state reopening; no sample is retried or omitted.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.953 | 0.947–0.972 |
| Verified throughput | 0.997 | 0.977–1.058 |
| Peak RSS | 1.010 | 0.957–1.126 |
| Counterpart CPU seconds/GiB | 1.002 | 0.905–1.028 |

CPU falls 4.7% [2.8–5.3%]. Throughput, RSS and counterpart CPU remain
inconclusive; the wide RSS interval includes a substantial cost. Native control
intervals cross one. This is experimental, with no cost-free or parity claim.
Broader source comparisons, native interoperability and a final full matrix
remain open.

The existing encoded upload buffer still contains at most sixteen frames and
256 KiB. Its already-reserved frames now publish under one lock with one writer
wake-up, rather than locking and yielding per frame. Total byte/message
admission is checked once because moving exact reservation credit into queued
credit preserves those totals. Every token and its exact credit remain checked.
A late cancellation or invalid reservation retains the original published
prefix and wakes its writer before propagating the error. No additional buffer,
queue capacity, request window, cache or wait for more requests is introduced.
Scalar enqueue, output joining and µTP upload bodies match the baseline exactly.

A new parameterised contract first passes on unchanged production and covers
late cancelled/wrong-size reservations, published-prefix wire order and retained
unattempted credit. All 363 package tests, 20 focused ownership/admission tests
under each sanitizer and Release build pass. TCP already has connection-owned
deadlines; the current profiles do not establish a need for a timer rewrite.

[Summary, source checks, validation and raw hashes](upload-publication-comparison-2026-11-13.json)
retain evidence. Raw trials remain in
`.build/benchmarks/upload-publication-single-v1-seed-source-order`.
