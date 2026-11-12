# Bounded contiguous vector writes

Production candidate `cbd0863` joins contiguous buffers for one file into one
vector write, at most sixteen buffers and 256 KiB. File boundaries, gaps and
overlap split runs; the existing eight-descriptor per-job cache and all queue
admission limits remain. Direct single-buffer writes retain their original
limits. Payload hashing, durable invalidation and checkpoint policy stay intact.
Each short vector write checks cancellation and path identity again, updates the
known file stamp after actual progress, and retains pending flushes after failure.
Borrowed pointers remain inside nested immutable-buffer lifetimes.

All 350 package tests and 113 focused tests under each of Address and Thread
Sanitizers pass. New coverage exercises sliced buffers, short writes crossing
buffer boundaries, EINTR, zero-progress EIO, ENOSPC, cancellation/replacement
between partial writes, selective multi-file runs and overlapping write order.
A test declaration syntax error is corrected before the successful package run;
its failed output remains locally with the diagnostics.

Six balanced many-file hybrid download source pairs against `3914272` give:

| Current/previous | Median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.981 | 0.969–0.985 |
| Verified throughput | 1.024 | 1.021–1.043 |
| Whole-process peak RSS | 0.995 | 0.945–1.023 |

Swift medians change from 170.0 to 175.6 MB/s and 6.626 to 6.455 CPU s/GiB.
Native controls are 453.0 MB/s and 2.351 CPU s/GiB; paired CPU/native remains
2.753 [2.720–2.816], outside the unchanged 1.25 target. Memory passes against
the original fresh Swift baseline. Native-control and counterpart CPU intervals
cross one. These fixed six-pair source diagnostics are not final acceptance.

All 28 trials pass payload digests and saved-state reopening. Each source/engine
has one warm-up, followed by six balanced source/engine pairs, identical driver
source and one pinned native counterpart. Sources are warm, processes and
destinations fresh, pieces 256 KiB and request windows the production defaults.
Intervals use paired median percentile bootstrap, 10,000 resamples. Full raw
phases, source/compiler/machine metadata, counterpart measurements and failures
remain locally in `.build/benchmarks/vector-writes-source-order` and
`.build/diagnostics/piece-buffer/vector-*`. The machine-readable summary is
retained beside this report. Broader performance and native interoperability
verification remain pending; CPU parity is not established.

A further six single-file v1 download source pairs against the same baseline
(28 validated trials) give CPU 0.995 [0.992–1.001] (inconclusive), throughput
1.012 [1.003–1.015] and peak RSS 1.017 [1.008–1.020]. Swift medians are
409.4 MB/s and 3.151 CPU s/GiB; native controls are 448.7 MB/s and 1.540 CPU
s/GiB. Paired CPU/native remains 2.043 [2.029–2.086]. The counterpart uses
4.3% more CPU [1.3–6.1%] in this source comparison; native-control CPU and
throughput intervals cross one. This increase is retained, not hidden as an
engine gain. Original-baseline memory passes, despite higher incremental RSS.
All 56 trials across both source diagnostics validate; the single-file case
does not establish a CPU benefit or full-matrix throughput acceptance.
Its complete local records are `.build/benchmarks/vector-writes-single-source-order`.

All 52 native storage checks pass, including a new actual-ENOSPC vector write:
unverified payload exhausts its remaining allocation without publishing progress,
the last durable checkpoint remains byte-for-byte intact, and retry after freeing
space hashes successfully. Existing crash recovery and read-only checks also pass.
Native interoperability and final-candidate matrix acceptance remain pending.
