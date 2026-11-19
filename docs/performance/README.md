# Transfer performance

The latest full matrix validates **252/252 trials**. Five cases meet all targets;
downloads use **2.01–3.52× libtorrent's CPU/GiB**. Competing builds and other CPU
load were observed, so this is a **contended-host result**, not quiet-host release
qualification. The earlier matrix and controlled source comparisons remain retained.

The later [request-window comparisons](#thirty-two-block-request-window) retain a
thirty-two-block default after successive increases from eight and sixteen. They
establish additional CPU gains with modest memory use. Larger windows help the
tested 1 MiB-piece workload at 48, while 64 establishes no further gain. Those
larger defaults remain isolated. The full matrix below predates both retained changes.

## Public Debian download

19 November 2026, `debian-13.7.0-arm64-netinst.iso.torrent`, 735,358,976 bytes,
256 KiB pieces. Fresh isolated Release sessions reproduced the reported slowdown:

| Configuration | Observation |
| --- | --- |
| Original `0ef8ad2` | 4 MiB received in 40 s, entirely from HTTP; no peers |
| DHT fix `dbe0c34` | 78.0 MB received in 38 s, including 74.1 MB from a peer |
| Both fixes, HTTP only | 45.6 MB received in 40 s; approximately 11× the original fallback speed |
| Both fixes `9c326d1`, discovery enabled | Entire ISO verified in approximately 108 s; 917.7 MB received including redundant data |

DHT rejected replies containing more than eight compact nodes. It now accepts
longer lists while admitting at most eight valid referrals per address family.
HTTP seeds now coalesce adjacent blocks into ranges of at most 256 KiB within
one piece, preserving 16 KiB storage blocks and existing integrity checks.

The full download independently passed all 2,806 piece hashes after reopening
the payload. Regression checks passed 208 engine tests, the focused DHT and
web-seed/picker suites, ten native HTTP-to-libtorrent comparisons and the Release
app build. The tracker timed out; public-peer availability and cold discovery
vary. These are single diagnostic runs, with approximate sampling times and no
controlled Transmission timing. Cold-start latency and redundant traffic remain
targets; this does not establish parity with Transmission.

## Current matrix

15 November 2026, engine revision `450e229`, including worker fusion `047dcfc`.
Values are Butter/libtorrent; speed is verified throughput, CPU is seconds/GiB
through durable completion.
Higher speed and lower CPU are better. Layouts are one file, 128 files or four
concurrent transfers.

| Layout | Format | Download speed | Download CPU/GiB | Seed speed | Seed CPU/GiB |
| --- | --- | ---: | ---: | ---: | ---: |
| Single | v1 | 47% | 3.02× | 151% | 1.39× |
| Single | v2 | 49% | 2.92× | 145% | 1.54× |
| Single | Hybrid | 40% | 2.49× | 114% | 1.40× |
| Many | v1 | 52% | 2.91× | 159% | 1.63× |
| Many | v2 | 53% | 2.77× | 176% | 1.10× |
| Many | Hybrid | 55% | 2.01× | 124% | 1.00× |
| Concurrent | v1 | 131% | 3.52× | 181% | 1.08× |
| Concurrent | v2 | 123% | 3.51× | 188% | 1.07× |
| Concurrent | Hybrid | 137% | 2.38× | 154% | 1.02× |

Targets: ≥90% reference throughput, ≤1.25× CPU/GiB and peak RSS within 10% of the
original Butter baseline. Throughput passes **12/18**, CPU **5/18**, memory **18/18**.
Many-file v2/hybrid and all three concurrent seeding cases meet all targets.
Single-file seeding and many-file v1 seeding miss the CPU target in this run.

Each trial transfers 1 GiB over loopback TCP with production request windows.
There are 36 warm-ups and 216 measurements: six balanced pairs per case. None
triggers the predefined extension to twelve pairs. Fresh processes/destinations,
source and destination SHA256 checks, strict checkpoint reopening and durable
shutdown apply throughout. Counters and profilers
were disabled. No assistant-initiated builds or tests ran during timed transfers;
other compiler processes, Etemmu and indexing were observed on the host.

Memory uses the complete original baseline (`40e4347`), checked before launch:
264 accepted trials covering all 18 cases, with matching fixture hashes. Its
trial/fixture hashes remain unchanged. Raw results, baseline proof, host-load
observations and analysis are under ignored `.build/benchmarks/fused-full-20261115`.
Tested source, harness and driver/reference-binary hashes stayed unchanged.
[Compact measurements](matrix-20261115.json) retain intervals and absolute medians.

Early observations show several compiler processes and Etemmu each using roughly
one core, with indexing also active. Etemmu and indexing remain visible at the
midpoint. These snapshots describe observed activity, not average load for the run.
Other processes were left untouched. A quiet-host release check remains queued.
The preceding `e1be93b` matrix validates 264/264 trials and passes all nine seeding
cases; its measurements remain in [the earlier results](results.json). Differences
between these separate runs cannot establish a fusion regression. Matched source
comparisons below establish its retained effect for concurrent v2.

## Retained optimisations

The [thirty-two-block download window](#thirty-two-block-request-window) establishes
an additional 6.5% CPU/GiB reduction for many-file hybrid with 256 KiB pieces and
7.7% with 1 MiB pieces, plus smaller concurrent gains. Single-file v1 remains
inconclusive. Throughput medians are not lower, and matching memory checks pass.

The [sixteen-block download window](#sixteen-block-request-window) reduces CPU/GiB
by 10.8–21.1% and increases throughput by 12.0–26.5% across four matched workloads,
with modest additional memory and every original memory budget passing.

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
one. These focused results do not establish the overall download targets. The
subsequent full matrix above ran under competing host load; quiet-host release
validation remains pending.

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

## Rejected persistent receive aggregation

Candidate `3e5bf25` against `834075d` validates **100/100 many-file hybrid trials**:
four warm-ups and 24 predeclared balanced source pairs, with counters disabled,
production windows, independent SHA256 checks, strict checkpoint reopening and
unchanged fingerprints. No samples were repeated or discarded.

| Candidate/baseline | Median ratio | Paired 95% interval |
| --- | ---: | ---: |
| CPU/GiB | 1.234 | 1.175–1.271 |
| Verified throughput | 1.009 | 0.978–1.062 |
| Peak RSS | 1.074 | 1.055–1.084 |
| Counterpart CPU/GiB | 1.107 | 1.034–1.166 |

Native-control CPU and throughput intervals include one. Memory passes against the
matching original baseline: median RSS ratio 0.278 (95% interval 0.272–0.283),
maximum ratio 0.297. The host was checked before launch; browser activity and later
external compiler work appeared during traffic. These are **contended-host results**.

A separate four-trial counts comparison increases write jobs/GiB from 9,401 to
10,235 and reduces mean blocks/dispatch from 6.97 to 6.40. The candidate performs
33,573 stream reads and 13,430 aggregation drains; the baseline has 9,153 positive
read cycles. Read calls and consumer drains are separate counts. This diagnostic
transfer does not establish timing acceptance.

The bounded persistent producer/consumer passes 433 package tests, focused checks
under both sanitizers, 312 native peer fixtures and the remaining native session,
discovery, tracker, DHT, PEX and web-seed checks. The implementation and its buffer
tests remain on `experiment/bounded-receive-aggregation`; main retains the independent
blocked-storage shutdown regression. Conditional guard comparisons were not triggered
because CPU did not improve. More RAM remains an option for future CPU-saving work;
this candidate already raises memory without reducing CPU. This result applies to
the tested implementation.

[Compact results](receive-aggregation-20261115.json) retain intervals and qualifications.
Raw evidence remains under ignored `.build/benchmarks/receive-aggregation-*`.

## Receive fragmentation diagnostics

Separate running-thread profiles and counts comparisons validate **8/8 diagnostic
transfers**, with independent SHA256 checks, strict checkpoint reopening and unchanged
fingerprints. Each source/engine has one 1 GiB many-file hybrid transfer per diagnostic.
The instrumented baseline and pump use matching counters.

| Counts-only measurement | Baseline | Persistent pump |
| --- | ---: | ---: |
| TCP receive calls | 9,516 | 29,660 |
| Exact 13-byte piece-header shapes | 175 | 11,006 |
| Shared deadline timers started | 1 | 1 |
| Deadline registrations, including writes | 23,325 | 43,812 |
| Waiter suspensions, including writes | 23,324 | 43,808 |

Every matched header-only receive has at least 64 KiB of read allowance. Each source
receives the same 1,074,594,138 wire bytes. This supports early receives exposing
headers separately from payload. These tiny reads are not forced by 13-byte read
allowances; a larger raw-buffer cap has no established benefit here. There is no
timer task per read in these transfers.

The profiles retain 5,003 baseline and 5,844 pump running samples. Directly attributed
connection-deadline ancestry accounts for 0.24%/0.36%; wire/transport ancestry accounts
for 24.83%/30.25%. These are sampled ancestry weights, not measured CPU durations or
savings. Inlining and unresolved runtime work prevent treating the deadline share as
an upper bound. The counters and profiles are separate intrusive diagnostics, with
no timing acceptance inference.

Instrumentation remains isolated on `experiment/tcp-receive-diagnostics` and
`experiment/tcp-receive-pump-diagnostics`; its 12 focused tests pass with diagnostics
off, on and under ThreadSanitizer. [Compact results](receive-transport-20261115.json)
retain source identities and measurements. Raw evidence remains under ignored
`.build/benchmarks/receive-{transport-profile,header-counts}-20261115`.

## Direct TCP read completion

Candidate `e1809ac` removes a per-read waiter object and callback-dictionary entry,
using one owned continuation instead. Read sizes, deadlines, request windows,
hashing, filesystem checks and GUI behaviour remain unchanged.

The comparison against `5bdb5d2` validates **100/100 many-file hybrid trials**:
four warm-ups and 24 predeclared balanced source pairs, counters disabled,
independent SHA256 checks, strict checkpoint reopening and unchanged fingerprints.
No samples were repeated or discarded. Ratios are candidate/baseline with paired
95% bootstrap intervals.

| Measurement | Median ratio | 95% interval |
| --- | ---: | ---: |
| CPU/GiB | 1.002 | 0.986–1.023 |
| Verified throughput | 0.987 | 0.973–1.016 |
| Peak RSS | 1.000 | 0.991–1.004 |
| Counterpart CPU/GiB | 0.994 | 0.977–1.040 |

Native-control CPU and throughput intervals include one. Memory passes against the
matching complete original baseline: median ratio 0.261 (95% interval 0.256–0.263),
maximum ratio 0.275. The user explicitly authorised this **contended comparison**;
compiler/test and indexing activity is retained in load snapshots. No quiet-host
release qualification is claimed.

The CPU criterion fails to establish an improvement; the throughput median is also
lower. The implementation remains on `experiment/tcp-direct-read-continuation`.
Conditional concurrent-v2, single-v1 and concurrent-hybrid comparisons were not
triggered. Main retains the independent overlapping-read ownership regression and
64 iterations of completion/cancellation/close races.

The candidate passes 428 package tests, 37 focused tests under each sanitizer,
312 native peer fixtures and the remaining native session, discovery, tracker,
DHT, PEX and web-seed comparisons. The retained transport/deadline subset passes
11 tests on main. [Compact results](tcp-direct-read-20261115.json) retain the
intervals, qualifications and conditional guard statuses. Raw evidence remains under
ignored `.build/benchmarks/tcp-direct-read-*`.

## Sixteen-block request window

The default download request window was raised from eight to sixteen. Measured
candidate `db0cd52` was retained on main as `3415037`; the further increase to
thirty-two is documented below. The existing receive coordinator,
sixteen-block/256 KiB dispatch limit, disk limits, hashing and fresh filesystem checks
are unchanged. Explicit
pipeline settings and lower peer-advertised queue limits remain honoured.

Against `1363710`, all **208/208 fixed comparison trials** validate: four warm-ups per
workload, then 24 many-file hybrid, twelve concurrent-v2 and six each single-file v1
and concurrent-hybrid source pairs. Counters are disabled; independent SHA256 checks,
strict checkpoint reopening, unchanged fingerprints and matching original memory
baselines apply throughout. No samples were repeated, discarded or extended.
Candidate/baseline ratios with paired 95% bootstrap intervals:

| Download workload | CPU/GiB | Verified throughput | Peak RSS |
| --- | ---: | ---: | ---: |
| Many hybrid | 0.789 (0.784–0.801) | 1.222 (1.206–1.237) | 1.039 (1.025–1.055) |
| Concurrent v2 | 0.892 (0.877–0.927) | 1.120 (1.035–1.221) | 1.134 (1.074–1.171) |
| Single v1 | 0.842 (0.816–0.884) | 1.151 (1.094–1.195) | 1.040 (0.989–1.061) |
| Concurrent hybrid | 0.869 (0.812–0.883) | 1.265 (1.160–1.407) | 1.125 (1.040–1.199) |

The comparisons establish CPU reductions of 10.8–21.1% and throughput increases of
12.0–26.5% in these workloads under the authorised contended-run policy. Every native
control CPU/throughput interval includes one. Etemmu, compiler/test and indexing
activity was observed; these results do not qualify a quiet-host release.

Median peak RSS rises from 17.48 to 18.14 MiB for many-file hybrid, 22.67 to 25.88 MiB
for concurrent v2, 15.26 to 15.92 MiB for single v1, and 22.63 to 25.48 MiB for
concurrent hybrid. All four memory budgets pass against the matching complete
original baseline: median ratios 0.216–0.331 and observed maximum ratios 0.216–0.357.

A separate four-trial counts comparison reduces write jobs/GiB from 9,392 to 4,980,
total disk jobs from 9,405 to 5,505, directory/file opens from 57,164 to 42,103 and
positive read cycles from 9,159 to 4,509. Mean blocks/dispatch rise from 6.98 to 13.16,
with the same wire bytes and counted hash work. These are diagnostic counts,
excluded from timing acceptance.

The candidate passes 429 package tests and 55 focused tests under each sanitizer.
Native preflight exposed a test-fixture observation race: concurrent UI snapshots
can retain an old peer row after the live connection budget reaches zero. The fixture
now checks the live budget and first proves it observes the connected old peer.
All four corrected cases pass on the eight-block baseline. Production tracker and
disconnect code and all measured production-source fingerprints are unchanged.
The initial failure and diagnostic reproduction remain preserved with the results.
The corrected native run passes all 201 engine preflight tests, 312 peer fixtures and
the remaining session, discovery, tracker, DHT, PEX and web-seed comparisons. The final
24-test focused subset passes on main, whose production-source fingerprints match
the measured candidate exactly.

[Compact measurements](window-sixteen-20261115.json) retain all comparison outcomes,
absolute memory medians and validation status. Raw evidence remains under ignored
`.build/benchmarks/window-sixteen-*`.

## Thirty-two-block request window

Measured candidate `50b3c87` is retained on main as `44a809d`, raising the default
from sixteen to thirty-two blocks. Dispatches remain capped at sixteen blocks/256 KiB;
peer queue limits, hashing, filesystem checks and other hard limits are unchanged.
Explicit configurations and lower remote queues remain honoured.

Against `6e67dfc`, the fixed 24-pair many-file hybrid comparison validates **100/100
trials**, including four warm-ups. CPU/GiB ratio is **0.935 (0.906–0.961)**,
verified throughput **1.075 (1.028–1.101)** and peak RSS **1.014 (0.999–1.043)**
(paired 95% bootstrap intervals). Median RSS rises from 17.96 to 18.28 MiB, and the
memory budget passes against matching fixtures from the complete original baseline.
Both primary native-control intervals include one. Compiler/test and application contention
was recorded under the authorised contended-run policy; this is not quiet-host
release validation. Counters are disabled, source/binary fingerprints are unchanged,
and every payload and strict checkpoint reopen validates. No samples were repeated,
discarded or added after inspecting results.

The three original guards also validate, giving **208/208 trials** in total:

| Download guard | CPU/GiB ratio (95%) | Throughput ratio (95%) | Memory vs original |
| --- | ---: | ---: | --- |
| Concurrent v2, twelve pairs | 0.971 (0.947–0.991) | 1.030 (0.969–1.073) | Pass |
| Single v1, six pairs | 0.973 (0.946–1.025) | 1.021 (0.896–1.045) | Pass |
| Concurrent hybrid, six pairs | 0.967 (0.950–0.988) | 1.006 (0.968–1.083) | Pass |

Both concurrent guards establish CPU gains; single-file CPU and all three guard
throughput outcomes remain inconclusive. No throughput median is lower. All native
control CPU/throughput intervals include one; all original-baseline memory budgets
pass. The additional 1 MiB piece-size comparison below uses fresh matched sources.

The additional twelve-pair **1 MiB piece-size** comparison validates **52/52 trials**,
bringing this candidate to **260/260** across five comparisons. CPU/GiB is
**0.923 (0.880–0.962)** and verified throughput **1.058 (1.031–1.125)**; median
RSS is 16.59 → 16.69 MiB, with a paired RSS ratio of 0.994 (0.984–1.023).
Both native-control intervals include one. Payload hashes match the original data,
but torrent metadata changes with piece size: its fresh matched memory check passes,
and no original-baseline memory acceptance is inferred for that additional fixture.

A separate four-trial counts comparison reduces disk jobs/GiB from 5,439 to 4,688,
write jobs from 4,902 to 4,655 and descriptor opens from 41,499 to 37,673, with
identical wire bytes and hash work. The measured source passes 429 package tests and
55 focused tests under each sanitizer. Main retains additional configuration/queue
bounds and piece-size coverage through 1 MiB. Its three affected tests pass under
both sanitizers; all 203 engine preflight tests pass, followed by all 312 native peer
fixtures and the complete legacy-hybrid, local-discovery, session, tracker, DHT,
PEX/PORT and web-seed sequence (466 native pass lines). Production-source and package
fingerprints on main exactly match the measured candidate. Initial parallel native
preflight hit large-piece deadlines; unchanged cases and the final complete sequence
pass serially without deadline or production-code changes.

[Compact results](window-thirty-two-20261115.json) retain the protocol and validation;
ignored `.build/benchmarks/window-thirty-two-*` retain the raw evidence. The larger-window
calibration below finds an additional 1 MiB-piece benefit at 48 and no established
benefit from 64. Both larger defaults remain isolated.

## Larger-window piece-size calibration

The fixed calibration compares 48 versus 32, then 64 versus 48 after 48 establishes
a CPU gain. Candidate `74938ad` allows explicit pipelines up to 64 and honours explicit
remote queues up to that ceiling, retaining the 32-request fallback when `reqq` is
absent. Larger windows are sent as wire batches of at most 32 requests; the writer's
existing batch, output-byte/message, upload and payload-dispatch limits are retained.
New tests cover lower remote queues and piece sizes from 16 KiB to 1 MiB. The
corrected candidate passes 431 package tests and 57 focused tests under each sanitizer.

Separate four-trial diagnostic comparisons validate for both piece sizes:

| Piece size | Disk jobs/GiB, 32 → 48 | Descriptor opens, 32 → 48 |
| --- | ---: | ---: |
| 256 KiB | 4,696 → 4,734 | 37,764 → 38,167 |
| 1 MiB | 4,925 → 4,776 | 33,457 → 32,336 |

Wire bytes and counted hash work are identical within each comparison. These are
counts, not CPU acceptance evidence. Timing uses 24 fixed source pairs for
256 KiB pieces and twelve for 1 MiB; all outcomes are retained. A CPU gain in
either size justifies trying 64; lower-throughput candidates remain isolated for
user decision. The final larger-window candidate also requires the original guard
workloads and native validation before adoption.

Both timings validate **152/152 trials** in total. Paired candidate/previous ratios
with 95% bootstrap intervals:

| Piece size | CPU/GiB | Verified throughput | Peak RSS |
| --- | ---: | ---: | ---: |
| 256 KiB, 24 pairs | 1.006 (0.994–1.019) | 0.997 (0.982–1.005) | 1.006 (0.997–1.013) |
| 1 MiB, twelve pairs | 0.980 (0.975–0.987) | 1.019 (1.006–1.031) | 1.006 (1.001–1.015) |

The 1 MiB fixture establishes a 2.0% CPU reduction and 1.9% throughput increase,
with median RSS 16.07 → 16.15 MiB. Its matched previous/current memory check passes;
no original-baseline memory acceptance is inferred for this new fixture. The 256 KiB
fixture establishes no improvement, passes original-baseline memory, and has a lower
throughput median. Both native-control intervals include one in both sizes. No
samples were repeated, discarded or added. Compiler/test and application activity
was recorded under the authorised contended-run policy; no quiet-host claim applies.

The CPU gain triggers the isolated 64-versus-48 experiment below, using the same
fixed pair counts at both piece sizes. Forty-eight remains
isolated; its lower 256 KiB throughput median is not automatically accepted. Final guards
are not run for this isolated candidate because the common-case throughput median
is lower; 32 remains the general default. The conditional 64 adoption study below
requires a direct comparison against 32 before any further default increase.

`BUTTER_BENCHMARK_PIECE_LENGTH=1048576` selects the additional fixture, records its
piece length and changes torrent metadata while retaining the same payload hashes.
The 1 MiB fixture uses a fresh matched memory comparison; no original-baseline memory
pass is inferred from the original 256 KiB fixture. [Compact results and protocol](window-forty-eight-20261115.json)
retain both diagnostics and the corrected preflight history; raw evidence is under
ignored `.build/benchmarks/window-forty-eight-*`. The initial diagnostic was stopped
after the larger-window tests exposed the writer's 32-request batch limit; its two
completed previous-source trials and incomplete current-source transfer are preserved.
Parallel preflight also hit large-piece test deadlines; the unchanged 32-block cases
and corrected full 48-block suite subsequently pass serially without deadline changes.

## Sixty-four-block request-window candidate

After 48 establishes a CPU gain with 1 MiB pieces, candidate `02cbc31` raises its
default to 64. The measured production change is one constant against `be45572`;
configuration/remote queue ceilings of 64, 32-message wire batches and other limits
are inherited. It passes 431 package tests and 57 focused tests under each sanitizer.
The candidate remains isolated after the fixed 24-pair 256 KiB and twelve-pair
1 MiB comparisons. Any CPU-saving candidate with a lower throughput median remains
isolated; no throughput trade-off is automatically adopted.

Separate four-trial diagnostics validate for both sizes, with identical wire bytes
and counted hash work within each comparison:

| Piece size | Disk jobs/GiB, 48 → 64 | Mean blocks/dispatch, 48 → 64 |
| --- | ---: | ---: |
| 256 KiB | 4,643 → 4,672 | 14.22 → 14.19 |
| 1 MiB | 4,663 → 4,916 | 14.09 → 13.36 |

Both fixed comparisons validate **152/152 trials**, with paired candidate/previous
ratios and 95% bootstrap intervals:

| Piece size | CPU/GiB | Verified throughput | Peak RSS |
| --- | ---: | ---: | ---: |
| 256 KiB, 24 pairs | 1.011 (0.984–1.045) | 0.980 (0.961–1.003) | 0.997 (0.982–1.008) |
| 1 MiB, twelve pairs | 1.005 (0.972–1.028) | 1.004 (0.977–1.032) | 1.006 (0.952–1.017) |

Neither piece size establishes a CPU or throughput improvement. The 256 KiB
throughput median is 2.0% lower; its original-baseline memory budget passes. The
1 MiB matched memory check passes, with median RSS 16.48 → 16.50 MiB; no original
memory acceptance is inferred for that fixture. Both native-control intervals
include one in both sizes. Every payload, strict reopen and source/native fingerprint
validates. All samples are retained, with no repetitions or extensions. Host compiler,
test and application activity qualifies these as authorised contended comparisons,
not quiet-host release validation.

The candidate remains isolated and window increases stop. Final guard/adoption
comparisons are not run because the gain gate fails and the common-case throughput
median is lower. Across the three window stages, all **564/564 fixed comparison
trials** validate: 260 for 32 versus 16, 152 for 48 versus 32, and 152 for 64 versus
48. The useful measured choices are 32 for the general default and 48 for the tested
1 MiB-piece workload; a piece-aware policy still needs separate validation before
adoption. Sixty-four supplies no established additional benefit in these fixtures.

[Compact protocol, counts and validation](window-sixty-four-20261115.json) retain
both outcomes; raw evidence is under ignored `.build/benchmarks/window-sixty-four-*`.

## Isolated fairness-batch experiment

Candidate `99afd53`, isolated on `experiment/fairness-batch-retention`, retains the
bounded pending payload across the existing 128-frame `Task.yield()`. It removes
only the forced yield flush and its unused diagnostic enum case. Control, read-end,
error and size-budget flushes remain; the request window stays 32 and dispatches
remain bounded to sixteen blocks/256 KiB. No network wait or batching delay is added.

A deterministic plaintext/RC4 fixture crosses frame 128 halfway through six available
payload blocks while storage is blocked. The baseline admits three blocks and fails
the six-block expectation in both modes; the candidate admits all six in one batch
and processes the following choke only afterwards. It verifies all bytes and drains
readers and permits on shutdown. An extended existing test puts its only payload at
frame 128 and proves that read-end flushing still writes it without another frame.
The source passes 432 package tests and 64 focused tests under each sanitizer; the
additional read-end case also passes normally and under both sanitizers.

Separate four-trial counts comparisons validate at both piece sizes:

| Piece size | Write jobs/GiB, baseline → candidate | Mean blocks/dispatch | Physical reads |
| --- | ---: | ---: | ---: |
| 256 KiB | 4,600 → 4,263 | 14.25 → 15.37 | 4,133 → 4,271 |
| 1 MiB | 4,835 → 4,456 | 13.55 → 14.71 | 4,366 → 4,460 |

Both retain exactly 512 scheduler yields/GiB, with yield-triggered flushes 512 → 0
and identical wire bytes and counted hash work. Disk jobs fall 4,627 → 4,298 and
4,846 → 4,467 respectively. The increased read counts mean these diagnostics alone
cannot establish a CPU saving.

The fixed 24-pair many-file hybrid comparison against `3d284a6` validates **100/100
trials**, including four warm-ups, with counters disabled. Candidate/baseline ratios
with paired 95% bootstrap intervals are:

| Measurement | Ratio (95%) |
| --- | ---: |
| CPU/GiB | 0.976 (0.942–1.002) |
| Verified throughput | 1.017 (1.004–1.068) |
| Peak RSS | 1.000 (0.995–1.026) |

Throughput establishes a 1.7% improvement. Median CPU is 2.4% lower, but its upper
bound is **1.0016**, narrowly missing the predeclared requirement that it be below
one. CPU improvement remains inconclusive. Median RSS is 18.08 → 18.20 MiB; the
matching original-baseline memory budget passes. Both native-control CPU/throughput
intervals include one. Every payload, strict reopen and source/binary fingerprint
validates. Compiler, installer and application activity was recorded under the
authorised contended-run policy; no quiet-host qualification is inferred.

The candidate stays isolated on `experiment/fairness-batch-retention`. The fixed run
is not extended or repeated. Conditional concurrent, single-file and 1 MiB timing
guards are not run because the CPU gate fails; complete native validation is also
not run for this unretained production change. Main keeps only independently useful
wire-ordering and short read-end tests at frame 128, without imposing batch geometry.
All 32 relevant tests pass there, and all production-source/package fingerprints
match the unchanged 32-block baseline exactly. Test coverage is retained in `1fbb59c`.

[Protocol, counts and validation](fairness-batch-20261115.json) retain every outcome
and the baseline test failure. Raw evidence remains under ignored
`.build/benchmarks/fairness-batch-*`.

## Isolated decoder buffer-reuse experiment

Candidate `e3b33b5`, isolated on `experiment/decoder-buffer-reuse`, defers decoder
compaction until append space is exhausted. It moves the unread tail in unique
`Data` storage and requests retained capacity after draining. The 131,076-byte
logical storage bound, 65,536-byte feed limit, owned payloads and decoder value
semantics remain intact. Request windows, receive timing, dispatches, hashing and
filesystem checks are unchanged. Tests cover independent copied fragments, retained
payloads, maximum frames and a four-byte overlapping move in shared storage.

The source passes 434 package tests and 82 focused tests under each sanitizer. The
strengthened overlapping/shared-storage cases also pass normally and under both
sanitizers. Separate four-trial diagnostics validate at both piece sizes:

| Piece size | Write jobs/GiB, baseline → candidate | Physical reads |
| --- | ---: | ---: |
| 256 KiB | 4,631 → 4,646 | 4,145 → 4,166 |
| 1 MiB | 4,991 → 4,899 | 4,525 → 4,442 |

Wire bytes and counted hash work are identical within each comparison. These are
transfer-work diagnostics, not allocation counts or CPU acceptance evidence. The
fixed primary timing uses 24 many-file hybrid source pairs against `3d4107d`, with
counters disabled. Only a primary upper paired 95% CPU/GiB ratio below one triggers
concurrent-v2 (twelve), single-v1/concurrent-hybrid (six each) and 1 MiB-piece (twelve)
guards. Original-baseline memory checks and throughput-preserving retention apply.
[Protocol, diagnostics and validation](decoder-reuse-20261115.json) retain every
outcome; raw evidence is under ignored `.build/benchmarks/decoder-reuse-*`.
The fixed primary comparison validates **100/100 trials**. CPU/GiB ratio is
**0.981 (0.967–0.997)**, verified throughput **1.016 (1.006–1.028)** and peak
RSS **0.987 (0.979–0.997)**, with paired 95% bootstrap intervals. This establishes
1.9% lower CPU and 1.6% higher throughput. Median RSS is 18.03 → 17.80 MiB and
original-baseline memory passes. Both native-control intervals include one. Payloads,
strict reopens and source/binary fingerprints validate; no samples are repeated,
discarded or added. The predeclared guards are now running. Results remain qualified
by recorded compiler/application contention, with no quiet-host release claim.

All four predeclared guards also complete, giving **260/260 validated trials**:

| Download guard | CPU/GiB ratio (95%) | Throughput ratio (95%) | Memory check |
| --- | ---: | ---: | --- |
| Concurrent v2, twelve pairs | 1.009 (0.935–1.097) | 1.030 (0.995–1.081) | Original baseline pass |
| Single v1, six pairs | 1.012 (0.984–1.035) | 0.989 (0.967–1.016) | Original baseline pass |
| Concurrent hybrid, six pairs | 1.021 (0.995–1.045) | 1.003 (0.943–1.042) | Original baseline pass |
| Many hybrid, 1 MiB pieces, twelve pairs | 0.989 (0.967–1.005) | 1.019 (0.994–1.038) | Matched previous/current pass |

All guard CPU and throughput intervals include one. The concurrent-v2 native CPU
control is 0.992320 (0.989590–0.999143), while the concurrent-hybrid control is
1.019347 (1.000050–1.038082); these small control shifts further qualify the
contended guard results. Single-file median throughput is 1.1% lower, so the candidate
remains isolated under the throughput-preserving rule. No samples are repeated,
discarded or extended. The 1 MiB fixture has no inferred original-baseline memory
acceptance; its new metadata and matched previous/current memory check are retained.

Main keeps only independent-copy, payload-ownership and partial-frame boundary tests
in `35f3f3d`. All 18 relevant tests pass against the unchanged production decoder,
whose source/package fingerprints match `3d4107d` exactly. The tests impose no buffer
allocation or compaction policy. Complete native validation is not run for this
unretained production change. The branch and all raw results remain preserved.

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
