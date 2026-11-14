# Transfer performance

The current full matrix validates **264/264 trials**. All nine seeding cases meet
the agreed targets. Downloads use **2.02–3.55× libtorrent's CPU/GiB**; single/many-file
downloads also miss the throughput target.

## Current matrix

14 November 2026, retained engine revision `e1be93b`. Values are Butter/libtorrent;
speed is verified throughput, CPU is seconds/GiB through durable completion.
Higher speed and lower CPU are better. Layouts are one file, 128 files or four
concurrent transfers.

| Layout | Format | Download speed | Download CPU/GiB | Seed speed | Seed CPU/GiB |
| --- | --- | ---: | ---: | ---: | ---: |
| Single | v1 | 74% | 2.52× | 161% | 1.18× |
| Single | v2 | 70% | 2.60× | 178% | 1.09× |
| Single | Hybrid | 62% | 2.02× | 217% | 1.03× |
| Many | v1 | 65% | 2.55× | 185% | 1.11× |
| Many | v2 | 62% | 2.52× | 180% | 1.12× |
| Many | Hybrid | 54% | 2.08× | 126% | 1.00× |
| Concurrent | v1 | 142% | 3.54× | 180% | 1.16× |
| Concurrent | v2 | 137% | 3.55× | 170% | 0.98× |
| Concurrent | Hybrid | 141% | 2.48× | 146% | 1.09× |

Targets: ≥90% reference throughput, ≤1.25× CPU/GiB and peak RSS within 10% of the
original Butter baseline. Throughput passes **12/18**, CPU **9/18**, memory **18/18**;
the nine seeding cases pass all three targets.

Each trial transfers 1 GiB over loopback TCP with production request windows.
There are 36 warm-ups and 228 measurements: six balanced pairs per case, extended
to twelve for single-file v1 seeding under the predefined inconclusive-result
rule. Fresh processes/destinations, source and destination SHA256 checks, strict
checkpoint reopening and durable shutdown apply throughout. Counters and profilers
were disabled; no other builds or tests ran during timing.

Memory was recomputed against the complete original baseline (`40e4347`) used by
the preceding full matrix after the launch selected an incomplete historical
baseline. No transfer measurements changed or needed repeating. The initial
summary, corrected summary and analysis are preserved under
`.build/benchmarks/current-full-20261114`. Source, harness and reference-binary
hashes stayed unchanged during the run. [Compact measurements](results.json)
include all intervals, absolute medians and the baseline correction.

Separate runs cannot establish a code regression. For example, many-file hybrid
CPU/GiB falls from 5.89 to 5.04 seconds for Butter and 3.30 to 2.42 for libtorrent
between the earlier focused run and this matrix. Butter's ratio worsens because
the reference changes more; the native binary hashes match. Matched source
comparisons below establish the retained optimisation's effect.

## Retained optimisations

Contiguous download writes use a shared 1 MiB transient budget, fresh filesystem
checks and strict verification. They apply to v2/hybrid and multiple-file v1;
single-file v1 uses ordinary writes after unrestricted coalescing increased
counterpart CPU. Wire blocks remain 16 KiB; observed transfer writes reach 128 KiB.

The controlled 1 GiB, 128-file hybrid source comparison validates all 28 samples
(four warm-ups, 24 measurements). Ratios below are current/previous Butter, with
paired 95% bootstrap intervals over six balanced source pairs.

| Metric | Ratio | 95% interval |
| --- | ---: | ---: |
| CPU/GiB | 0.773 | 0.750–0.794 |
| Throughput | 1.244 | 1.202–1.284 |
| Peak RSS | 1.011 | 1.000–1.016 |
| Counterpart CPU/GiB | 0.961 | 0.926–1.063 |

This establishes **22.7% lower CPU** and **24.4% more throughput** for that case.
A separate 500 Mbps comparison validates and saturates all 28 samples: CPU ratio
0.888 (0.781–0.942), throughput 0.963 (0.952–1.001), RSS 1.026 (1.001–1.041).
Its median throughput falls 3.7%; absence of a cost is unproven. Focused concurrent
hybrid downloads establish a 6.8% CPU reduction; single-file v1 and seeding checks
establish neither a gain nor a regression. Storage/engine tests, sanitizers,
native TCP interoperability and Debug/Release builds pass.

The file inspector uses one lazy stack of visible rows while preserving search,
collapse and spacing. Its fixed 2,000-file rendering workload validates 28 samples:
CPU falls 88.8% (ratio 0.112, interval 0.109–0.118), and median peak memory falls
from 798 to 127 MB. This includes window creation and twelve updates, with no
payload traffic; it establishes no transfer CPU gain.

## Rejected experiments

| Candidate | Result |
| --- | --- |
| Block reordering and sequential proofs | Removed most readback but established no lower total CPU. Reverted. |
| Pure-v2 leaf proofs | Established no lower total CPU. Reverted. |
| Summary/detail snapshots | Reduced synthetic polling costs, without establishing a live-transfer CPU gain. Fixed-rate native controls were unsaturated. Reverted. |
| Private staging | Storage replay CPU fell 31.8% for single blocks but rose 52.6% for eight-block batches. Doubled payload writes and tripled reads/hashing. Archived before transport integration. |
| Popularity-based upload eviction | Increased reloads. Reverted; shared in-flight reads and the existing bounded cache remain. |

Snapshots are preserved on `experiment/snapshot-unconditional` and
`experiment/snapshot-projection`; staging is on `experiment/private-staging`.
Staging recovery, race and sanitizer checks pass, but final destination readback
remains necessary: source/publication hashes can miss an edit masked by stamp
recording. Detailed results and qualifications stay in `results.json`.

## Profiling targets

Final many-file hybrid download samples attribute 31.3% to stored-byte verification,
30.6% to write jobs and 24.9% to peer transport. Metadata/open/close accounts for
27.8% of executing leaves. Seeding samples attribute 33.5% to payload reads,
31.4% to transport and 15.2% to upload admission/cache.

Guarded path opens/closes and transport are the next targets. Separate counters
show 65,536 download blocks in 13,761 ranges and 48,736 directory opens. Download
readback and upload cache loads each total 1 GiB; seeding performs no payload
hashing. The earlier 18-case profile matrix predates coalescing and remains
labelled separately in the measurements. Samples describe execution ancestry,
not measured CPU savings or kernel residence.

## Download write pipeline

The `--write-profile` run at revision `90c48b3` validates **36/36 trials**:
1 GiB each, one warm-up per mode, then **off, counts, timed, timed, counts, off**
for each workload below. All modes use one Release binary, production windows,
the pinned native counterpart, fresh destinations, independent SHA256 validation
and strict checkpoint reopening. Source and binary fingerprints stayed unchanged.
Numeric aggregates and trial records remain under ignored output
`.build/benchmarks/write-profile-20261114`.

Exclusive thread CPU **milliseconds/GiB**, averaged over two timed transfers per
column. Thread CPU combines user and kernel execution. Elapsed phase totals,
scope-entry counts, per-entry/job costs, process user/system CPU, counterpart CPU
and bounded distributions are retained in each workload's `summary.json` report.

| Phase | Single v1 | Many hybrid | Concurrent v2 | Concurrent hybrid |
| --- | ---: | ---: | ---: | ---: |
| Setup | 11.0 | 12.2 | 36.9 | 28.9 |
| Target inspection | 61.7 | 229.6 | 150.1 | 114.3 |
| Progress invalidation/checkpoint | 9.4 | 10.6 | 19.9 | 16.2 |
| Packing | 0 | 54.2 | 97.1 | 89.6 |
| Descriptor acquisition | 259.0 | 356.8 | 530.5 | 412.6 |
| Prewrite checks | 298.6 | 203.0 | 145.6 | 110.7 |
| Full-scan fallback | 0.5 | 38.5 | 0.5 | 0.6 |
| Payload `pwrite` | 371.2 | 204.1 | 375.1 | 308.9 |
| Postwrite stamping | 52.6 | 9.7 | 26.4 | 19.6 |
| Cleanup | 168.2 | 309.2 | 511.6 | 433.7 |
| Unassigned/instrumentation remainder | 384.7 | 149.4 | 295.3 | 231.7 |
| Total write jobs | 1,616.8 | 1,577.3 | 2,188.9 | 1,766.9 |

Write-job CPU shares of process CPU are **37.2%, 29.9%, 32.0%, 28.0%**, in column
order. The investigation ranking across these four equally sized workloads is:

1. **Descriptor acquisition and cleanup:** 26–48% of write-job CPU,
   0.43–1.04 CPU seconds/GiB. Guarded traversal/open/close work is the first target.
2. **Filesystem observations:** target inspection, prewrite checks and stamping
   add 14–28%, or 0.24–0.44 seconds/GiB. Preserve their identity, link, permission
   and replacement guarantees when proposing changes.
3. **Payload syscalls:** 13–23%, or 0.20–0.38 seconds/GiB. Mean syscall sizes are
   16, 96, 65 and 81 KiB; mean blocks/job are 7.01, 6.98, 4.34 and 5.53.
4. **Packing and scans:** packing is at most 5.1%; in-job full scans at most 2.4%.
   Many-file creation causes 128 mismatch scans/GiB, visiting 16,384 files;
   another 8,576 file visits/GiB occur outside writes. Every measured mismatch
   follows an absent stamp. No recorded-file mismatch, in-write checkpoint scan,
   overlap, budget fallback, syscall retry, short write or failed job is observed.

Counts/off process CPU ratios are **1.063, 1.035, 1.053, 1.035**; timed/off ratios
are **1.161, 0.991, 1.037, 1.033**. Timed/off transfer-duration ratios are
**1.229, 1.002, 0.939, 1.069**. Two measurements per mode cannot establish a speedup
or isolate instrumentation cost from run variation. These are diagnostic ratios,
with no acceptance inference or timer-cost subtraction. Counters also contribute
to phase costs; final aggregation/merge lies outside job timers. Exclusive phase
CPU/elapsed totals plus the explicit remainder reconcile exactly to job totals.
Summed parallel job elapsed time is not transfer duration.

Before traffic, 10,000-read calibrations report 42 ns resolution for both clocks,
about 9–10 ns/read for monotonic time and 125–130 ns/read for thread CPU. Histogram
percentiles are power-of-two upper bounds; individual-job traces are not retained.
All 91 storage tests, 28 controller tests and focused Address/Thread Sanitizer
checks pass. Temporary fixtures, drivers and sanitizer/compiler caches are removed.
Descriptor caching, larger batches, verification and scheduling changes need a
subsequent plan; these measurements establish costs, not achievable savings.

## Reproduction

After `Scripts/bootstrap-engine.sh`:

```sh
BUTTER_BENCHMARK_BASELINE="$PWD/.build/benchmarks/baseline-seeding-fixed" \
  Scripts/test-benchmark.sh --full .build/benchmarks/new-full
Scripts/test-benchmark.sh --smoke .build/benchmarks/new-smoke
```

Use a fresh output directory and the retained complete baseline for memory checks.
`--compare-source` and `--rate-compare` accept `BUTTER_BENCHMARK_PREVIOUS_REVISION`;
select workloads with `BUTTER_BENCHMARK_CASE`, `BUTTER_BENCHMARK_FORMAT` and
`BUTTER_BENCHMARK_DIRECTION`. `--rate-sweep` is exploratory.

For separate diagnostics, use `--profile` with `BUTTER_BENCHMARK_PROFILER=time-profiler`,
or `BUTTER_STORAGE_DIAGNOSTICS=1 BUTTER_BENCHMARK_PROFILER=counts`. UI comparisons
use `Scripts/test-ui-profile.sh`, `BUTTER_UI_COMPARE_SOURCE=1` and
`BUTTER_UI_PROFILE_PREVIOUS_REVISION`; add `BUTTER_UI_COMPARE_SMOKE=1` for layout checks.
Use `Scripts/test-benchmark.sh --write-profile OUTPUT` for the fixed write-pipeline
protocol; it selects off/counts/timed child environments automatically. Separate
phase timing runs require `BUTTER_STORAGE_WRITE_TIMINGS=1` together with
`BUTTER_STORAGE_DIAGNOSTICS=1` and a diagnostic command; acceptance runs reject it.
Instrumented runs supply no timing acceptance evidence. Raw traces/XML are deleted
after compact extraction unless `BUTTER_PROFILE_KEEP_RAW=1` is explicitly set.
Fixtures, drivers and temporary compiler caches are removed after each run.

The pinned libtorrent reference is `6da363d2994f17c0b3c0450d124cf73a31a73847`.
Archive ABI indicates Boost 1.92 while cached flags name 1.88; compiler/header
provenance remains unresolved. Recorded archive hashes anchor the comparisons.
