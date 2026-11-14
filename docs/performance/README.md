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
Instrumented runs supply no timing acceptance evidence. Raw traces/XML are deleted
after compact extraction unless `BUTTER_PROFILE_KEEP_RAW=1` is explicitly set.
Fixtures, drivers and temporary compiler caches are removed after each run.

The pinned libtorrent reference is `6da363d2994f17c0b3c0450d124cf73a31a73847`.
Archive ABI indicates Boost 1.92 while cached flags name 1.88; compiler/header
provenance remains unresolved. Recorded archive hashes anchor the comparisons.
