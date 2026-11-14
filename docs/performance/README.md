# Transfer performance

CPU parity remains unmet. The latest many-file hybrid write-coalescing candidate
uses **22.7% less CPU** than the retained implementation, with **24.4% more
throughput**, across six balanced source pairs. A matching fixed-rate comparison
also qualifies, and focused checks are complete. Single-file v1 retains ordinary
writes after a measured counterpart cost. This is not a release-wide improvement claim.

[Current measurements](results.json) contain the latest full matrix, compact
profile summaries, native rendering observations and all 28 write-comparison
measurements. Generated traces, per-run logs and historical experiment reports
belong under ignored `.build/`, rather than in documentation.

## Retained write coalescing

The 14 November comparison uses 1 GiB, 128 files, hybrid metadata and ordinary
request windows. Four warm-ups and 24 measured samples all passed independent
payload checks and checkpoint reopening. Counters and profilers were disabled;
no builds or tests ran during timing. Ratios are candidate/retained source, with
paired 95% bootstrap intervals over six balanced source pairs.

| Metric | Ratio | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.773 | 0.750–0.794 |
| Verified throughput | 1.244 | 1.202–1.284 |
| Peak RSS | 1.011 | 1.000–1.016 |
| Counterpart CPU seconds/GiB | 0.961 | 0.926–1.063 |

Median Swift CPU fell from 7.64 to 5.89 seconds/GiB. Native control CPU and
throughput intervals include one. Peak memory remains within the approved 10%
allowance. The candidate still uses about 1.79× libtorrent's CPU in this case.
The controller labels source comparisons separately from full-matrix acceptance.

A separate diagnostic reduced payload write ranges from 65,536 to 10,511 and
directory opens from 95,273 to 42,529. The implementation packs non-overlapping
blocks in file order inside an existing job, with a shared 1 MiB buffer ceiling,
fresh write/retry guards and strict verification. Actual transfer writes reached
128 KiB; the storage API also passes 1 MiB write tests. Larger network-collection
buffers have not been introduced.

Checks passed: storage/engine suites, focused Address and Thread Sanitizer tests,
48 bidirectional native TCP fixtures, and unsigned Debug/Release app builds with
native linkage and an unchanged repeat build.

At 500 Mbps, all 28 samples validate and meet saturation with the original 4 GiB
fixture and unchanged five-second settling/ten-second measurement windows:

| Metric | Ratio | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.888 | 0.781–0.942 |
| Throughput | 0.963 | 0.952–1.001 |
| Peak RSS | 1.026 | 1.001–1.041 |
| Counterpart CPU seconds/GiB | 0.975 | 0.662–1.125 |

This establishes lower CPU and passes the agreed retention gates. Throughput's
median falls 3.7%, with its interval narrowly including no change; absence of a
cost is not established. RSS remains within the 10% allowance. A preceding run
was invalidated by kernel-confirmed ENOSPC affecting both engines (22/28 validated);
it is excluded from inference. Obsolete build/profile artefacts were removed and
the harness now checks temporary disk capacity before creating fixtures.

Focused comparisons each validate 28 samples:

| Case | CPU ratio (95% interval) | Outcome |
| --- | --- | --- |
| Concurrent hybrid download | 0.932 (0.889–0.972) | Lower CPU; other checked intervals include no change |
| Many-file v1 seeding | 1.007 (0.999–1.038) | Neither gain nor regression established |
| Single-file v1, ordinary-write fallback | 0.996 (0.968–1.031) | Neither gain nor regression established |

Unrestricted single-file v1 coalescing increased counterpart CPU 11.2%
(1.073–1.163) without establishing a Swift CPU benefit. That case now uses the
original write path; its new counterpart interval is 0.908–1.031. The qualified
coalescer remains enabled for v2/hybrid and multiple-file v1 transfers. The
coalescer itself is unchanged by this eligibility restriction. Full-matrix parity
and absence of all costs remain unproven.

## Full matrix

The last complete matrix predates write coalescing. All 264 trials validated.
Throughput passed 11/18 cases, CPU 0/18 and original-baseline memory 18/18.
Ratios below are Swift/libtorrent; CPU is seconds/GiB through durable completion.

| Layout | Format | Download throughput / CPU | Seed throughput / CPU |
| --- | --- | ---: | ---: |
| Single | v1 | 0.660 / 2.059 | 1.293 / 1.510 |
| Single | v2 | 0.677 / 2.073 | 1.332 / 1.561 |
| Single | hybrid | 0.591 / 1.738 | 1.380 / 1.799 |
| Many | v1 | 0.495 / 2.399 | 1.157 / 1.311 |
| Many | v2 | 0.512 / 2.489 | 1.177 / 1.473 |
| Many | hybrid | 0.438 / 2.047 | 0.815 / 1.676 |
| Concurrent | v1 | 1.268 / 2.188 | 1.782 / 1.423 |
| Concurrent | v2 | 1.270 / 2.149 | 1.783 / 1.597 |
| Concurrent | hybrid | 1.235 / 1.782 | 1.652 / 1.730 |

Targets remain at least 90% of reference throughput, at most 1.25× CPU/GiB and
peak RSS within 10% of the original fresh Swift baseline. Separate runs do not
establish the cause of differences between implementations.

## Current profiling findings

All 18 layout/format/direction cases have validated Swift and native CPU captures,
plus separate counter runs. Download write jobs account for 49–68% of Swift
samples. In many-file hybrid download, writes account for 57.2%, stored-byte
verification 17.1% and peer transport 17.0%. Sample ancestry is attribution, not
measured CPU savings or kernel residence.

The existing seeding cache joins in-flight reads across peers and retains eight
pieces per torrent within a 64 MiB session budget. Eight concurrent readers
received 512 MiB from 64 MiB of storage reads. A tested ageing popularity policy
increased reloads and was reverted. The earlier sequential and pure-v2 proof
experiments did not establish lower CPU and were also reverted.

Eight synthetic native-view captures include window creation and twelve updates.
Hidden inspectors cost 0.54–1.22 CPU seconds; a visible 2,000-file inspector costs
13.52–13.75, and 200 torrent rows with a 512-file inspector cost 5.30–6.21.
These observations include initial rendering and do not isolate polling cost.

File Activity captures passed in the selected download/seeding cases. Allocation,
System Trace and Swift Concurrency attempts did not yield validated coverage.
Raw Instruments traces stay private because they can retain environment metadata;
exported metadata is redacted and child environments use an explicit allowlist.

## Reproduction

`Scripts/test-benchmark.sh --full` runs the native comparison matrix; `--smoke`
checks correctness with smaller fixtures. `--compare-source` uses four warm-ups
and 24 measurements; set `BUTTER_BENCHMARK_PREVIOUS_REVISION` and select a case,
format and direction with the corresponding `BUTTER_BENCHMARK_*` variables.
`--rate-compare` performs the fixed 500 Mbps comparison; `--rate-sweep` is
exploratory. `--profile` and `Scripts/test-ui-profile.sh` are diagnostic only.
Use `BUTTER_STORAGE_DIAGNOSTICS=1 BUTTER_BENCHMARK_PROFILER=counts` for a separate
operation-count run. Never use instrumented measurements for timing acceptance.
Profiler runs retain compact attribution reports and delete traces and raw XML,
including failed captures. Set `BUTTER_PROFILE_KEEP_RAW=1` only when those raw
exports are needed; retained allocation-table manifests mark whether exports remain.

The native anchor is libtorrent revision
`6da363d2994f17c0b3c0450d124cf73a31a73847`. Installed archive ABI indicates
Boost 1.92 while cached build flags name 1.88; compiler/header provenance remains
unresolved. Archive fingerprints anchor existing comparisons, but cached flags
alone do not establish a reproducible dependency build.
