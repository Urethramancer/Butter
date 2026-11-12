# Rejected descriptor-identity experiment

Six balanced source pairs compare `f2bbfed` with `7ab222c` in single-file 1 GiB
v1 TCP download, with production eight-request defaults and the same native
counterpart. All 28 trials pass streaming digests and saved-state reopening.

| Candidate/previous | Median | 95% paired interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.995 | 0.941–1.144 |
| Verified throughput | 1.009 | 0.836–1.068 |
| Peak RSS | 1.014 | 0.981–1.036 |
| Counterpart CPU seconds/GiB | 0.982 | 0.794–1.153 |

Rejected and reverted: neither CPU nor throughput establishes a reproducible
benefit. Raw medians are 282.4 → 290.3 MB/s and 4.750 → 4.650 CPU s/GiB;
those differences do not override the paired uncertainty. Native-control
intervals cross one. No failed trial is retried or source null extended.

The candidate passes 61 storage tests, 61 under each sanitizer, all 52 native
storage checks and a Release build. Restored production passes 61 storage tests
and both Release builds; all 94 source hashes match `7ab222c`. The new replacement
and hard-link contracts remain. [Ratios, checks and raw hashes](fd-identity-comparison-2026-11-12.json)
retain evidence. Raw trials remain in `.build/benchmarks/fd-identity-single-source-order`.

The host sidecar's current-load observation was recorded after the first measured
trial, despite its setup label; its original contents are retained with this
correction. A separate eighteen-process allocation probe does not support the
hypothesis that reserving the read buffer would eliminate the earlier owned-buffer
RSS regression. Its source, raw records and summary remain locally under
`.build/diagnostics/piece-buffer/data-footprint-*`; it is not an engine benchmark.
