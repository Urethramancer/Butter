# Return the owned verified-piece buffer

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
All 57 existing storage tests and 15 focused resource/upload tests pass.

Raw results, exact source/build hashes and phase/counterpart measurements remain
locally in `.build/benchmarks/piece-buffer-handoff-source-order`. The
machine-readable summary is retained beside this report; broader correctness
and performance verification are pending.
