# Transfer performance

The last complete matrix validates **264/264 trials**. All nine seeding cases meet
the agreed targets. Downloads use **2.02–3.55× libtorrent's CPU/GiB**; single/many-file
downloads also miss the throughput target.

## Current matrix

14 November 2026, engine revision `e1be93b`, before worker fusion. Values are Butter/libtorrent;
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

Worker fusion (`047dcfc`) writes a payload batch and verifies at most one ready
piece in the same storage job. Picker completion, publication, corruption handling
and remaining-piece verification follow the successful write result. Unauthenticated
legacy-hybrid candidates keep their existing path. Hashing and filesystem checks
are unchanged; disk admission, request windows and write-buffer limits remain intact.

Fixed source comparisons against `b8d477d` validate **100/100 many-file hybrid**
trials (24 balanced pairs) and **52/52 concurrent-v2** trials (12 pairs). Each has
four warm-ups, counters disabled, the pinned native counterpart, independent SHA256
checks, strict checkpoint reopening and unchanged source/binary fingerprints.
No trials are repeated or discarded. Ratios are fused/baseline Butter with paired
95% bootstrap intervals.

| Download workload | CPU/GiB | Verified throughput | Peak RSS |
| --- | ---: | ---: | ---: |
| Many hybrid | 0.993 (0.972–1.001) | 1.007 (0.996–1.029) | 0.998 (0.969–1.022) |
| Concurrent v2 | 0.991 (0.977–0.997) | 1.045 (1.013–1.061) | 1.014 (0.991–1.053) |

This establishes **0.95% lower CPU/GiB and 4.5% more throughput for concurrent v2**.
The many-file result remains inconclusive. Native-control CPU and throughput
intervals include one in both comparisons; counterpart CPU intervals also include
one. These focused results do not replace the full matrix or establish the overall
download targets. The full matrix must be rerun before release.

A separate four-trial counts diagnostic removes all 4,096 standalone verification
jobs/GiB: total disk jobs fall from 13,791 to 9,410, with the same 65,536 blocks and
1 GiB hashed. These are diagnostic counts, not timing acceptance. Storage-await
reports separate synchronous verification inside a fused job from write execution,
queue time and actor/completion overhead.

All 425 package tests, 98 tests under each sanitizer, native recovery/real-ENOSPC/
read-only checks and 33 benchmark-controller tests pass. Evidence remains under
ignored `.build/benchmarks/fused-write-verify-{many-hybrid-24pairs,concurrent-v2-12pairs}-20261114`
and `.build/benchmarks/fused-counts-many-hybrid-20261114`.

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
| Last-path syntax memoization | No established CPU or throughput benefit in 28 single-file v1 trials. Reverted. |
| Merkle leaf slices | Removed per-leaf `subdata` copies, but 28 many-file hybrid trials establish no CPU or throughput gain. Reverted. |
| Direct payload read buffers | Removed intermediate chunk buffers/copies, but neither many-file hybrid nor concurrent v2 establishes a CPU or throughput gain. Reverted. |
| Parent reuse within verification | Revalidated one parent during each piece check, but 28 many-file hybrid trials establish no CPU or throughput gain. Reverted. |
| Synchronous unrestricted-rate checks | Removed admission-only actor hops, but 28 many-file hybrid trials establish no CPU or throughput gain. Reverted. |
| One bounded read ahead | Increased write jobs and reduced batching; CPU rose 30.5% and throughput fell 11.7%. Reverted. |

Snapshots are preserved on `experiment/snapshot-unconditional` and
`experiment/snapshot-projection`; staging is on `experiment/private-staging`.
Staging recovery, race and sanitizer checks pass, but final destination readback
remains necessary: source/publication hashes can miss an edit masked by stamp
recording. Detailed results and qualifications stay in `results.json`.

The path-syntax candidate `a88bef2` compares against `44d8b50` with the fixed six
balanced source/engine pairs and four warm-ups, all validated. CPU/GiB ratio is
1.004 (95% interval 0.966–1.060), throughput 0.987 (0.922–1.051), RSS
1.002 (0.989–1.022), and counterpart CPU 1.029 (0.985–1.060). Native-control
intervals also include one. Counts were disabled; fingerprints stayed unchanged.
All 95 storage tests pass under Debug and both sanitizers. Exact-Unicode and
concurrent-path tests remain; compact results stay under ignored
`.build/benchmarks/path-syntax-single-v1-20261114`.

Merkle-slice candidate `c6963e6` against `cd651c1` validates 28/28 trials with
counters disabled and unchanged fingerprints. CPU/GiB ratio is 0.982 (paired
95% interval 0.959–1.013), verified throughput 1.016 (0.988–1.048), and peak RSS
1.006 (0.947–1.065). Native-control CPU and throughput intervals also include one.
All 98 storage tests pass. The inconclusive candidate is retained only on
`experiment/merkle-hash-slices`; raw results remain under ignored
`.build/benchmarks/hash-slices-many-hybrid-20261114`.

Direct-read candidate `a5346a7` against `288ba91` validates 28/28 trials per
workload, each with four warm-ups and six balanced source/engine pairs. Counters
are disabled; independent SHA256 checks, strict checkpoint reopening and source
fingerprints pass. Ratios below are candidate/baseline with paired 95% intervals.

| Workload | CPU/GiB | Verified throughput | Peak RSS |
| --- | ---: | ---: | ---: |
| Many hybrid | 1.006 (0.931–1.126) | 1.008 (0.834–1.081) | 1.042 (0.964–1.100) |
| Concurrent v2 | 0.993 (0.973–1.009) | 0.992 (0.805–1.029) | 0.977 (0.947–1.029) |

Native-control CPU and throughput intervals include one for both workloads.
Neither comparison establishes a benefit; no samples were repeated or discarded.
All 98 storage tests pass normally and under AddressSanitizer, including partial
reads, padding, large hybrid/v2 pieces, repair and corruption detection. The
candidate remains on `experiment/direct-payload-read-buffer`, with results under
ignored `.build/benchmarks/direct-read-{many-hybrid,concurrent-v2}-20261114`.

Scoped-parent candidate `71c9c87` against `4b01057` validates 28/28 many-file
hybrid trials with counters disabled and unchanged fingerprints. CPU/GiB ratio
is 0.995 (paired 95% interval 0.974–1.077), verified throughput 1.012
(0.937–1.036), and peak RSS 1.002 (0.941–1.013). Native-control intervals include
one. No samples were repeated or discarded. The candidate passes 101 storage
tests, 27 tests under each sanitizer, and native recovery/ENOSPC/read-only checks.
It remains on `experiment/scoped-verification-parent`; the four-case parent-change
regression remains on main, which passes 99 storage tests. Results remain under
ignored `.build/benchmarks/verification-parent-many-hybrid-20261114`.

Synchronous-admission candidate `768f441` against `ddf63b8` validates 28/28
many-file hybrid trials with counters disabled and unchanged fingerprints.
CPU/GiB ratio is 0.991 (paired 95% interval 0.904–1.005), verified throughput
1.015 (0.989–1.101), and peak RSS 1.003 (0.944–1.099). Native-control intervals
include one. No trials were repeated or discarded. All 198 engine tests and 52
ThreadSanitizer tests pass. The candidate remains on
`experiment/synchronous-rate-admission`; the rate-transition regression remains
on main. Results stay under ignored `.build/benchmarks/rate-access-many-hybrid-20261114`.

One-read-ahead candidate `dcca213` against `3769974` validates 28/28 many-file
hybrid trials with counters disabled and unchanged fingerprints. CPU/GiB ratio
is 1.305 (paired 95% interval 1.273–1.338), verified throughput 0.883
(0.861–0.911), and peak RSS 1.010 (0.972–1.059). Native-control intervals include
one. The implementation keeps current and prefetched raw bytes within 256 KiB,
preserves dispatch order, and cancels/drains its one pending read on exit.

A separate four-trial counts diagnostic processes the same 65,536 blocks/GiB:
write jobs rise from 9,472 to 16,658, total disk jobs from 13,577 to 20,764, and
mean blocks/dispatch fall from 6.92 to 3.93. The earlier read changes batching and
adds substantial coordination work. These counts describe one diagnostic transfer
per source; they are excluded from acceptance. No samples are repeated or discarded.
The candidate passes 202 engine tests and 42 tests under each sanitizer. It remains
on `experiment/bounded-read-ahead`; results are under ignored
`.build/benchmarks/read-ahead-{many-hybrid,counts-many-hybrid}-20261114`.
This result applies to the single-prefetch implementation.

## Profiling targets

A fresh running-thread profile of cache-free `4d004b1` validates both transfers
and retains 4,993 Swift running samples. Disjoint sampled purposes attribute 31.9%
to stored-byte verification, 30.8% to write jobs and 24.5% to peer transport.
Metadata/open/close accounts for 28.6% of executing leaves and hashing for 19.9%.
Verification copying is only 1.1%, compared with 4.0% in peer transport. These are
sample weights, not measured CPU durations or kernel residence; intrusive captures
do not establish performance acceptance. Results and unchanged fingerprints remain
under ignored `.build/benchmarks/running-cpu-many-hybrid-20261114`.
Seeding samples attribute 33.5% to payload reads,
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

## Rejected payload-descriptor reuse

Two bounded payload-descriptor cache variants were tested against `97b815c` on
1 GiB many-file hybrid downloads. Each fixed comparison validates **28/28 trials**:
four warm-ups and six balanced source/engine pairs, with counters disabled,
independent SHA256 checks, strict checkpoint reopening and unchanged fingerprints.
Both variants are reverted; the between-job permission and ACL tests remain.

| Current/previous | Initial (`f86f537`) | Refined (`7584bc7`) |
| --- | ---: | ---: |
| CPU/GiB | 0.980 (0.968–0.997) | 1.038 (1.003–1.137) |
| Verified throughput | 0.932 (0.912–0.953) | 0.913 (0.840–0.944) |
| Peak RSS | 1.012 (0.984–1.037) | 1.016 (1.001–1.063) |
| Counterpart CPU/GiB | 0.918 (0.819–1.015) | 0.899 (0.864–0.953) |

Intervals are paired 95% bootstrap intervals. The initial variant rechecked path
identity during acquisition as well as before writing. One separate diagnostic
transfer reduces total file opens from 13,756 to 4,378 and in-job payload closes
from 9,498 to 120, but this does not translate into better transfer performance.
In that instrumented sample, summed write-job elapsed time falls from 1.68 to
1.50 seconds while verified transfer time rises from 4.71 to 5.11 seconds.
The same 65,536 blocks form 10,085 jobs instead of 9,430. Smaller batches and
unmeasured queue/transport/verification waits are possible contributors; these
aggregates do not isolate the cause or establish that descriptor closes help.
The reader flushes each receive's blocks and awaits storage plus any completed
piece verification before the next receive (`PeerSession.readInput` and
`TCPTransfer.receivedBlocks`). TCP receives can complete with one byte. Faster
storage can therefore advance the next receive and reduce its batch size,
increasing read/actor/disk round trips. The observed batch change is consistent
with this feedback; per-stage wait times are still needed to attribute the loss.
The refinement uses checkpoint stamps only to select candidates, retains fresh
effective-access and prewrite identity checks, and drains handles at checkpoints.
Both keep eight idle slots per owner and 32 across the process, with cold-path
fallback on exhaustion and cleanup on errors, filesystem operations and shutdown.

External load of roughly two CPU cores from Etemmu was observed during the second
comparison. Native-control CPU ratios are 0.989 (0.973–0.993) and
1.055 (0.970–1.083); native throughput intervals include one in both comparisons.
These results justify rejecting the implementations, not concluding that all
forms of descriptor reuse are ineffective. No samples were repeated or discarded.

The candidates pass storage tests (97 and 98), focused Address/Thread Sanitizers
(43 and 51 tests each), and native recovery, real ENOSPC and read-only-volume
checks. Compact evidence remains under ignored `.build/benchmarks/descriptor-cache-*`;
the refined results use `descriptor-cache-refined-many-hybrid-20261114`.

## Receive-pipeline follow-up

The diagnostic comparison of baseline `ec7d226` and retained-descriptor experiment
`d5a7636` validates **18/18 trials**. Each source has one warm-up per mode, then
off/counts/timed/timed/counts/off with alternating source order. Every transfer is
1 GiB, many-file hybrid, with the pinned native counterpart, independent SHA256
checks, strict checkpoint reopening and unchanged source/binary fingerprints.

Elapsed seconds/GiB below average two timed trials per source. These are nested
budgets: write execution and queue time are inside the storage await, which is
inside payload dispatch. Do not add all rows together or interpret them as CPU.

| Measurement | Baseline | Retained descriptors |
| --- | ---: | ---: |
| Verified transfer duration | 4.931 | 5.252 |
| Positive stream-read awaits | 0.386 | 0.443 |
| Payload dispatch awaits | 3.998 | 4.225 |
| Storage-write awaits | 1.860 | 1.811 |
| Synchronous write jobs | 1.600 | 1.428 |
| Worker admission/submission/queue | 0.045 | 0.156 |
| Verification/publication awaits | 1.709 | 1.961 |

Both sources perform 4,096 verifications and read/hash the same 1 GiB per transfer.
Mean blocks/dispatch fall from 7.25 to 6.92, but extra call counts alone do not
explain the slowdown: actor-entry/admission/release costs remain small. Verification
awaits grow 0.252 seconds/GiB and worker waits 0.111 seconds/GiB, offsetting faster
write execution. Verification p99 upper bounds rise from 2.10 to 8.39 ms; roughly
64 calls/GiB occupy the longer tail, matching the 16 MiB checkpoint cadence.
Checkpoint involvement is a hypothesis until its execution is timed directly.

A separate baseline execution diagnostic at `4b01057` validates both transfers.
Its 4,096 synchronous verifications use 1.645 CPU seconds/GiB and 1.654 elapsed
seconds/GiB, including 64 checkpoints using 0.077 CPU and 0.079 elapsed seconds.
Four other checkpoints add 0.005 CPU seconds. Thus baseline checkpoint execution
is a small target; this single diagnostic does not explain the cache regression.
Nested verification/checkpoint budgets must not be added. Compact evidence is in
ignored `.build/benchmarks/checkpoint-execution-many-hybrid-20261114`.

Timed/counts CPU overhead against off is 6.0%/0.5% for the baseline and 8.5%/4.4%
for the cache. Timed mode also changes batch geometry. The off-mode cache is 6.3%
slower here, but two measurements per mode provide diagnostics, not acceptance.
Clock calibration, bounded distributions, positive-read/dispatch remainders and
post-durable tail counts are retained under ignored
`.build/benchmarks/receive-pipeline-20261114`. No payload traces are retained.
Main retains opt-in diagnostics, not the descriptor cache. Both sanitizers pass
62 focused tests, alongside the package and benchmark-controller suites.

### Closing retained handles before verification

Candidate `1684b5f` keeps the initial cache's fresh filesystem checks but closes
affected write handles before piece verification and hybrid readback. Against
cache-free `a299efa`, all **28/28** many-file hybrid download trials validate:
four warm-ups, six balanced source/engine pairs, counters disabled, independent
SHA256 checks, strict checkpoint reopening and unchanged fingerprints.

| Candidate/baseline | Median ratio | Paired 95% interval |
| --- | ---: | ---: |
| CPU/GiB | 1.038 | 1.032–1.046 |
| Verified throughput | 0.965 | 0.958–0.977 |
| Peak RSS | 0.995 | 0.921–1.044 |
| Counterpart CPU/GiB | 0.999 | 0.981–1.168 |

Native-control CPU and throughput ratios are 0.995 (0.992–1.024) and 0.993
(0.982–1.008). Closing handles before verification does not recover a benefit;
this candidate is reverted too. This result does not establish the cause of the
earlier verification tail. No trials were repeated or discarded.

The candidate passes 427 package tests, 13 focused tests under each sanitizer,
and native recovery, real ENOSPC and read-only-volume checks. Evidence is under
ignored `.build/benchmarks/preverification-cache-many-hybrid-20261114` and
`preverification-cache-validation-20261114`. The candidate remains on
`experiment/preverification-write-descriptors`; main has no payload-handle cache.

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
For `--compare-source`, predeclare `BUTTER_BENCHMARK_SOURCE_PAIRS=12` or `24`
for a larger fixed comparison (52 or 100 trials including four warm-ups).
The default remains six pairs. Source comparisons never extend or repeat samples
in response to their results.

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

Use `--receive-profile` with `BUTTER_BENCHMARK_PREVIOUS_REVISION` pointing to an
instrumented comparison source; both sources must contain matching diagnostic
helpers. It defaults to many-file hybrid downloads and selects off/counts/timed
child environments automatically. `BUTTER_RECEIVE_PIPELINE_TIMINGS=1` requires
`BUTTER_STORAGE_DIAGNOSTICS=1` and a diagnostic command; acceptance runs reject it.
Async spans measure elapsed time only. Terminal/empty reads are excluded from
positive-read budgets; final histogram/merge work is outside sample timers.

The pinned libtorrent reference is `6da363d2994f17c0b3c0450d124cf73a31a73847`.
Archive ABI indicates Boost 1.92 while cached flags name 1.88; compiler/header
provenance remains unresolved. Recorded archive hashes anchor the comparisons.
