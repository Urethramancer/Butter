# Grouped upload publication experiment

Candidate `afad9d1` versus `d37ffe5`: single-file/128-file 1 GiB v1 TCP seeding
and four simultaneous 256 MiB hybrid seeds, 256 KiB pieces and production
request windows. Each case uses four warm-ups followed by six balanced
source/engine pairs. Two further cases check many-file hybrid and single-file
v1 download regressions. All 140 trials validate
independent payload digests and saved-state reopening; none is retried or omitted.
The first table describes single-file seeding.

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

Many-file seeding independently establishes CPU −4.6% [−5.0% to −3.3%],
throughput +1.2% [+0.4% to +2.2%] and counterpart CPU −1.9% [−3.1% to −1.0%].
RSS remains inconclusive; absence of a source cost is not proven. Native control
CPU and throughput intervals cross one. Measured revision `82daac6` has matching
production source/package hashes to `afad9d1`.

| Many-file candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.954 | 0.950–0.967 |
| Verified throughput | 1.012 | 1.004–1.022 |
| Peak RSS | 0.995 | 0.953–1.022 |
| Counterpart CPU seconds/GiB | 0.981 | 0.969–0.990 |

Concurrent hybrid seeding establishes CPU −3.4% [−5.6% to −1.1%]. Throughput,
RSS and counterpart CPU remain inconclusive; native control intervals cross
one. Measured revision `728ed84` has matching production source/package hashes.

| Concurrent hybrid candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.966 | 0.944–0.989 |
| Verified throughput | 0.990 | 0.920–1.034 |
| Peak RSS | 0.985 | 0.947–1.075 |
| Counterpart CPU seconds/GiB | 1.007 | 0.924–1.027 |

Many-file hybrid download CPU, throughput, RSS and counterpart CPU are all
inconclusive, as are native controls. No regression is established, but absence
of costs is unproven. All 28 trials validate; measured revision `22129ca` has
matching production source/package hashes.

| Many-file hybrid download candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 1.001 | 0.973–1.028 |
| Verified throughput | 1.017 | 0.974–1.028 |
| Peak RSS | 0.997 | 0.934–1.013 |
| Counterpart CPU seconds/GiB | 1.019 | 0.937–1.057 |

Single-file v1 download CPU, throughput and counterpart CPU are inconclusive.
RSS falls 0.3% [0.1–2.4%]. Native control CPU falls 0.8% [0.05–9.4%], retained
separately; native throughput is inconclusive. No combined workload score or
absence-of-cost claim follows. Measured revision `3d58c22` has matching
production source/package hashes; all 28 trials validate.

| Single-file v1 download candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 1.000 | 0.991–1.012 |
| Verified throughput | 1.005 | 0.995–1.014 |
| Peak RSS | 0.997 | 0.976–0.999 |
| Counterpart CPU seconds/GiB | 0.979 | 0.877–1.023 |

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
`.build/benchmarks/upload-publication-*-source-order`.
