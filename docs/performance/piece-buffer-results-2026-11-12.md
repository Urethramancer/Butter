# Return the owned verified-piece buffer

Reverted after the user's no-trade-offs requirement: the measured incremental
RSS increases below disqualify this change despite its CPU savings. The results
remain historical evidence. The restored paths pass all 350 package tests and
a Release build, together with removal of the vector-write candidate.

For a complete piece of at most 256 KiB, return the owned read buffer after
hashing and full-layout checks, avoiding a second allocation and copy. Partial
ranges and larger pieces retain the existing accumulation path. No verification,
filesystem guard, cancellation check, cache or admission limit changes.

Six balanced single-file v1 seeding source pairs against `545fbff` show:

| Current/previous | Median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.938 | 0.914–0.966 |
| Verified throughput | 1.053 | 1.028–1.065 |
| Whole-process peak RSS | 0.984 | 0.934–1.053 |

Swift medians change from 591.0 to 622.2 MB/s and 2.688 to 2.497 CPU s/GiB.
The current native control gives 444.9 MB/s and 1.770 CPU s/GiB. Native-relative
paired CPU remains 1.438 [1.332–1.490], above the unchanged 1.25 target.
Original-baseline memory passes; this source diagnostic is not full acceptance.
All 28 trials pass independent payload digests and saved-state reopening.
Sources use the same driver and pinned native counterpart, production request
windows, warm sources, fresh processes/destinations, one warm-up per source and
engine, and paired median percentile bootstrap intervals (10,000 resamples).
All 347 package tests pass, with 110 focused tests under each of Address and Thread Sanitizers.

Raw results, exact source/build hashes and phase/counterpart measurements remain
locally in `.build/benchmarks/piece-buffer-handoff-source-order`. The
machine-readable summaries are retained beside this report. The full native rerun passes all 466 interoperability checks. The [full matrix](piece-buffer-full-results-2026-11-12.md) validates 276 trials; CPU parity remains unmet.

Six further source pairs per case (56 validated trials) compare the same change
with `545fbff`. All 84 trials across the three cases pass; no failures are retried.

| Seeding case | CPU current/previous | Throughput current/previous | Peak RSS current/previous |
| --- | ---: | ---: | ---: |
| 128 files, v1 | 0.945 [0.923–0.977] | 1.003 [0.985–1.085] | 1.055 [1.007–1.092] |
| Four transfers, v2 | 0.878 [0.860–0.905] | 1.044 [1.008–1.092] | 1.090 [1.066–1.108] |

Memory increases against the preceding source in both cases; the concurrent
interval exceeds 1.10 at its upper end. The acceptance requirement is against
the original fresh Swift baseline, which both cases pass: current median peak
RSS is 0.205 and 0.385 of that baseline, with observed maxima 0.210 and 0.400.
No cache limit is enlarged. Many-file Swift/native medians are 396.9/447.5 MB/s
and 4.013/1.985 CPU s/GiB. Concurrent medians are 930.9/480.1 MB/s and
2.809/1.804 CPU s/GiB. Paired native-relative CPU remains 2.004 [1.910–2.363]
and 1.570 [1.416–1.586]; neither establishes parity. Native control and
counterpart CPU intervals cross one in each case.

Broader raw phases, source hashes and counterpart results remain locally in
`.build/benchmarks/piece-buffer-handoff-broader`. These focused source diagnostics
do not replace the eighteen-case final matrix or resolve earlier full-run
sequence/runtime regressions.

The first native run exits unsuccessfully after at least 179 observed passes.
Its redirected log, fixture directory and Swift module cache under `/tmp` are
missing at completion; no child remains and 58 GiB is available. Its cause is
unresolved and no failure text can be recovered. A recorded rerun changes only
the temporary fixture and compiler-cache locations to workspace directories;
all 466 checks pass. The first failure record and rerun wrapper remain in
`.build/diagnostics/piece-buffer`. No correctness failure is attributed to the
buffer change from this missing evidence. Benchmark temporary storage now
honours `TMPDIR` and records its location, allowing a workspace directory for
the full run without changing the measurement protocol.
