# Swift/libtorrent transfer comparison

[Per-job autorelease scope](disk-autorelease-results-2026-11-13.md) is rejected
and reverted: six balanced source pairs establish no CPU, throughput or RSS
benefit. All 28 trials validate; current production still matches the full matrix.

[Isolated UTF-8 separator lookup](byte-split-results-2026-11-13.md) is rejected
and reverted: six balanced source pairs show CPU −6.0% and throughput +6.3%,
but RSS +1.9% [0.8–5.2%]. All 28 trials validate. Lookup alone still has a memory
cost in this download case; the earlier C-string candidate used v1 seeding,
so its memory cause remains unproven. Restored source matches the full matrix below.

[Current write-refill full matrix](write-prefill-full-results-2026-11-13.md)
validates all 252 trials: throughput passes 9/18, CPU 0/18 and memory 18/18.
CPU/native ranges from 1.55× to 3.97×; many-file downloads remain the largest
gap. Earlier matrices below describe preceding production sources.
[Fresh profiles](write-prefill-profiles-2026-11-13.md) validate all eight captures
and two filesystem diagnostics. The syscall traces are consistent with fuller
write batches; repeated filesystem inspection/opening remains the largest gap.

[Refilling during admitted writes](write-prefill-results-2026-11-13.md) improves
CPU/throughput versus the preceding refill candidate: many-file hybrid
10.9%/16.7%, concurrent hybrid 4.1%/12.3%, single-file v1 10.4%/19.4%.
All 84 source trials validate. Single-file RSS falls 1.1%; other RSS changes
remain inconclusive. Native validation passes (466 PASS records), as do
application, recovery, sanitizer and Debug/Release build checks. The refreshed
full matrix is recorded above; CPU parity and source memory uncertainty remain open.

[Refilling the existing window before verification](verification-prefill-results-2026-11-13.md)
reduces many-file hybrid download CPU by 9.9% [5.1–14.8%] and concurrent
hybrid download CPU by 8.5% [5.3–12.5%]. Three fixed six-pair source cases
validate all 84 trials; single-file v1 CPU, throughput and RSS changes remain
inconclusive. The native suite passes with 466 PASS records. Broader format
coverage is supplied by the newer full matrix above, which includes the subsequent
write-time refill change. Source throughput/memory uncertainty remains open.
[Fresh candidate profiles](verification-prefill-profile-2026-11-13.md) validate
both engines and still identify filesystem inspection/opening as the largest gap.

[Historical revised-buffer full matrix](wire-raw-full-results-2026-11-13.md) validates
252/252 trials: throughput passes 9/18, CPU 0/18 and memory 18/18. CPU/native
ranges from 1.53× to 5.19×. Many-file downloads remain the largest gap; parity
is unmet. Historical matrices below describe different candidates.

[Owned upload wire buffers](wire-groups-results-2026-11-12.md) now retain ordinary
frames as Data. Seven revised source comparisons validate 196 trials: seeding
CPU falls 2.3–4.3%; single/concurrent hybrid RSS falls 4.3%/7.7%. No measured
cost is established, but several throughput/download intervals remain wide
and inconclusive. Full native validation passes (466 PASS records). The full
matrix is recorded above; CPU parity remains unmet.
The first version's measured download memory cost remains disqualifying.

[Write-parent retention experiment](write-parent-results-2026-11-13.md) is rejected
and reverted: six balanced source pairs do not establish CPU or throughput
benefit. New parent-replacement/access contracts remain; restored production
before the refill changes matches the historical revised-buffer matrix.

[Fresh revised-source many-file CPU profiles](wire-raw-many-hybrid-profile-2026-11-13.md)
validate both engines after the full matrix. Swift stat/open/close account for
46.5% of flat Running samples; stored-byte hash sample weights are comparable
to native. Filesystem work remains the next optimisation target.

[Eight-request baseline Running CPU profiles](window8-current-profiles-2026-11-12.md)
validate all eight prescribed captures before the upload-buffer changes. They identify
filesystem work in downloads and stored-byte verification/output work in seeding.
These diagnostics do not establish performance acceptance.

The [descriptor-identity experiment](fd-identity-results-2026-11-12.md) completes
28 validated source trials but establishes no CPU or throughput benefit and is
reverted. Its raw median is 290.3 MB/s and 4.650 CPU s/GiB; the paired CPU
interval is 0.941–1.144 of the preceding source, so no improvement is claimed.

Acceptance requires Swift to reach at least 90% of libtorrent's verified TCP
throughput, at most 1.25 times its CPU seconds per GiB through durable completion,
and peak RSS within 10% of the fresh Swift baseline. Results are per workload;
there is no combined performance score. Encryption and µTP remain correctness
regressions, outside this throughput milestone.

The [eight/31 balanced recheck](window-results-2026-11-12.md) validates all 28
trials and establishes a 4.3% peak-RSS cost for the larger window. The original
eight-request default is restored under the user's no-trade-offs rule, giving
up the window-tuning gains. This moves CPU further from parity: the focused
single-file v1 download gives 4.815 CPU s/GiB and 281.3 MB/s, with CPU/native
2.970 [2.893–3.125] and throughput/native 0.632 [0.590–0.656]. The earlier
sixteen-request decision and complete matrices below are historical.

The user's subsequent requirement excludes gains with measured drawbacks.
Owned-piece-buffer returns and vector writes are therefore reverted: their
incremental memory or counterpart CPU increases disqualify them. Their reports
and the latest full matrix below are historical results, not measurements of
the restored candidate. The rollback passes 350 package tests and a Release
build. Grouped upload workers remain supported by the measured comparisons.

A subsequent [UTF-8 stamp-scan experiment](byte-stamp-results-2026-11-12.md)
reduces many-file v1 seeding CPU 5.6% but increases peak RSS 11.0% and reduces
throughput 0.9%, so it is reverted. All 28 trials validate. The unchanged
production control measures 4.150 CPU s/GiB and 396.8 MB/s, with a paired
CPU/native ratio of 2.136 [2.061–2.268]. This focused control is not a new full
matrix. The separately verified Unicode path ownership fix remains.

A [balanced request-window recheck](window31-results-2026-11-12.md) retains
28 validated trials. Sixteen requests instead of 31 increases Swift CPU 5.5%
and counterpart CPU 30.0%; memory and throughput differences are inconclusive.
The 31-request default was restored at that point. Equal memory is not established, and this
focused diagnostic does not replace full-matrix acceptance.

The [latest full comparison](piece-buffer-full-results-2026-11-12.md) retains
276 accepted trials and no failures for production source `b328472`. Memory
passes all eighteen cases, eleven meet throughput, and every case still fails
CPU. Many-file v1/v2 seeding extend to twelve pairs and establish throughput
passes; all other cases finish six pairs. Peak RSS spans 15.1–46.1 MiB.
CPU ratios range from 1.381 to 3.673× native. Twelve historical independent
CPU comparisons improve over the preceding complete `5b9ef12` matrix, while
six remain inconclusive; source-controlled comparisons provide causal evidence.
The earlier full-run seeding regressions and their unknown sequence/runtime
cause remain recorded in the [preceding matrix](window31-full-results-2026-11-12.md).

[Current source-matched CPU profiles](piece-buffer-profiles-2026-11-12.md)
cover both engines in the four standard cases plus many-file v1 seeding for
production `b328472`. All ten profile-only trials validate. Full-layout stamp
inspection remains 34.1% inclusive in many-file hybrid download and 40.0% in
many-file v1 seeding; opening, hashing, copying and scheduling also remain.
These profiles are separate from timing. The [preceding profiles](upload-groups-profiles-2026-11-12.md)
and original full-run seeding regressions remain recorded; their sequence/runtime
cause and CPU parity remain open.

A [balanced source comparison](seeding-source-comparison-2026-11-12.md) retains
56 further diagnostic trials. Neither large seeding loss reproduces as a source
effect when the old and current engines are interleaved with one native binary.
CPU/throughput intervals cross one in both cases. Original full-run regressions
remain recorded; their sequence/environment cause and CPU parity remain open.

A [parent descriptor experiment](parent-anchor-results-2026-11-12.md) retains
28 further trials. Borrowing the root descriptor produces no reproducible CPU
benefit and is reverted; its callback lifetime/error tests remain.

A [single-buffer read experiment](read-buffer-results-2026-11-12.md) retains
28 further trials. CPU and throughput intervals cross one, so it is reverted.
Its multi-chunk cancellation/truncation contracts remain.

A [Merkle leaf buffer experiment](leaf-buffer-results-2026-11-12.md) retains
28 hybrid download trials. Removing per-leaf copies does not establish a CPU
benefit and is reverted. Existing hash and filesystem protections remain.

An [immutable upload-cache wrapper](cache-wrapper-results-2026-11-12.md)
avoids an actor hop for each block. Six controlled single-file v1 seeding pairs
show 0.8% lower CPU and 1.0% higher throughput, with both memory checks passing.
This small step passes all 466 native interoperability checks. A separate
four-transfer v2 seeding source comparison finds 0.8% higher throughput and
inconclusive CPU, with memory passing. Final acceptance remains open and the
latest full-matrix CPU gap is unchanged as an acceptance finding.

[Grouped pending upload workers](upload-groups-results-2026-11-12.md) retain
independent block tokens while sharing one verified piece-read worker. Six
balanced single-file v1 seeding source pairs reduce CPU 16.5% and raise
throughput 11.6%, with memory passing. All 344 package tests and 46 focused
tests under each sanitizer pass. Separate source comparisons reduce many-file
seeding CPU 16.9% (throughput inconclusive) and concurrent seeding CPU 12.9%
(throughput up 9.6%), with memory passing. All 466 pinned native interoperability
checks pass. Final acceptance remains open; these focused results do not
establish CPU parity.

A [queued verified-read experiment](verified-read-batches-results-2026-11-12.md)
shares full-layout guards across bounded queued reads while retaining per-read
admission and cancellation. It shows no reproducible benefit and is reverted.
Public ordering/cancellation/admission regressions remain; all measurements and
an unresolved initial network-bind test failure are retained.

A separate [available request dispatch experiment](request-groups-results-2026-11-12.md)
over the retained grouped workers also shows no reproducible benefit. Its 28
trials and rejected patch remain; production dispatch is restored.

[Returning an owned verified-piece buffer](piece-buffer-results-2026-11-12.md)
avoids another full-piece copy. Six source pairs per case reduce seeding CPU
6.2% (single v1), 5.5% (many v1) and 12.2% (concurrent v2). All 84 trials
validate; original-baseline memory passes, although incremental memory rises
in the many-file and concurrent cases. CPU parity and final acceptance remain open.

[Bounded vector writes](vector-write-results-2026-11-12.md) reduce focused
many-file hybrid download CPU 1.9% and raise throughput 2.4%. Single-file v1
CPU is inconclusive and throughput rises 1.2%; counterpart CPU and incremental
RSS increases are retained explicitly. All 56 trials validate and original-baseline
memory passes. The candidate passes 351 package tests, 113 focused tests under
each sanitizer and 52 real-volume/recovery checks. The combined vector/binding candidate passes 466 native checks;
the final-candidate matrix remains pending, and the latest complete matrix stays `b328472`.

The earlier focused [hash-readiness optimisation](hash-readiness-results-2026-11-12.md)
reduces focused single-file hybrid download CPU from 6.950 to 6.019 s/GiB
(13.4%) and raises throughput from 182.4 to 213.1 MB/s. Fourteen trials and both
memory gates pass; native-relative CPU and throughput still miss their targets.
This step is included in the latest full matrix.

Subsequent [request-window tuning](window-results-2026-11-12.md) raises the
production Swift default from eight to sixteen within the existing caps. Against
a fresh eight-request baseline, single-file v1 download CPU falls 18.9%
(5.188 to 4.206 s/GiB), throughput rises 17.3% and both memory gates pass.
The change is included in the latest full matrix; native parity remains unmet.

A subsequent [picker refill change](picker-results-2026-11-12.md) reduces
single-file v1 download CPU another 14.5%, from 4.206 to 3.597 s/GiB, and raises
throughput from 297.3 to 363.0 MB/s. Both memory gates pass. This focused result
still misses native-relative CPU and throughput targets.

The [31-request follow-up](window31-results-2026-11-12.md) sets the production
default within the existing maximum of 32. Focused single-file v1 CPU falls
another 9.0% to 3.274 s/GiB and throughput rises 4.6% to 379.8 MB/s. Incremental
RSS rises 3.2%; both memory gates pass. Native parity remains unmet.

The [focused steps and validation](outbound-batching-results-2026-11-12.md)
record the isolated experiments and exact source revisions for correctness
checks. No combined workload average substitutes for per-case acceptance.

The earlier [filesystem inspection steps](filesystem-results-2026-11-12.md)
reduces many-file v2 seeding CPU from 9.00 to 7.92 s/GiB through parent-path
validation reuse and computing only metadata-defined digests. A regressing bulk
inspection prototype was reverted and retained as negative evidence. The
retained parent-path and digest changes are included in the latest full matrix.

The [available TCP input experiment](input-batching-results-2026-11-12.md)
reduces focused many-file v2 download CPU by about 4%. Its incremental RSS
uncertainty and seeding checks are reported explicitly.

The earlier [partial cache-admission matrix](cache-admission-partial-results-2026-11-12.md)
completed eight cases before a repeated many-file v1 seeding stall stopped the
run for investigation. All 117 records, including the interrupted next trial,
remain. Single-file seeding exceeds native throughput but CPU remains above
the target. The interrupted and slow trials remain alongside the corrected run.

The [corrected upload advertisement](advertised-window-results-2026-11-12.md)
fits full-sized framed payloads within the existing output budget. Six fresh
many-file v1 seeding pairs remove the disconnect/reconnect stall, reduce CPU
13.4% and reach 393.9 MB/s. Native-relative CPU remains 2.57× and throughput
87.8%, outside both targets. Original and incremental memory checks pass.

Run `Scripts/test-benchmark.sh --full [OUTPUT]` on an otherwise idle Mac.
`--smoke` checks the harness using 32 MiB and one pair per case; its intervals
are not acceptance evidence. The optional reference dependency stays pinned to
`6da363d2994f17c0b3c0450d124cf73a31a73847`. Both engines use the same reference
counterpart, with production request-window defaults and plaintext loopback TCP.

The full matrix uses deterministic generated data, 256 KiB pieces, v1/v2/hybrid
metadata, downloads and seeding: a 1 GiB single file, 128 equal files totalling
1 GiB, and four simultaneous 256 MiB torrents in one process. Every trial starts
fresh processes and state/destination directories. Sources are streamed and
independently SHA256 checked immediately before each trial: these are explicitly
warm-source measurements, with no cold-cache claim.

Each case has one declared warm-up per engine, then six pairs in balanced,
deterministically shuffled order. Raw results include warm-ups and failures.
Per-case summaries contain medians and paired Swift/reference ratios with 95%
percentile-bootstrap intervals (10,000 resamples). Cases whose intervals cross
the throughput or CPU thresholds extend to twelve pairs, retaining the first
six. Unresolved intervals are inconclusive. Failed trials are never retried or
excluded to produce a passing case.

The drivers exchange bounded JSON lines over OS pipes: prepare, ready, start,
verified, persistence, durable, shutdown and stopped. Only phase boundaries
produce output. The controller monitors both children during each deadline and
terminates and reaps their process groups on failure. Swift waits for picker
completion without allocating snapshots; libtorrent uses finished alerts.
Seeding finishes when the receiving engine verifies the payload, rather than
when a sender reports a byte count.

Wall, user and system CPU deltas are reported for setup, verified transfer,
persistence and shutdown, along with throughput through durable completion.
CPU/GiB includes persistence, so deferred work cannot improve that metric.
`/usr/bin/time -l` independently measures whole-process wall/CPU and peak RSS,
including startup and destruction. The counterpart has separate phase/CPU/RSS
measurements. After timing, independent streaming file sizes/SHA256 and reopening
both engines' saved state must confirm completion before a trial is accepted.

## Persistence contract

Swift retains its native checkpoint format and flushes payload files and their
parents before atomic checkpoint publication (file fsync, rename, directory
fsync). The reference saves native resume data, including metadata, after
awaiting pause and explicit cache-flush alerts. The harness additionally fsyncs every non-padding payload
file, its parent directories, and the destination's parent; it then fsyncs and
atomically publishes resume data and fsyncs its directory and parent. These are
POSIX fsync barriers, not claims about device power-loss guarantees.

Swift's native completion API waits for its forced completion checkpoint before
returning success, so that barrier lies inside its verified-transfer interval.
The reference finished alert precedes its persistence barrier. Through-durable
CPU and throughput include both placements; the raw persistence/whole-process
measurements expose the difference. Completion errors continue to propagate
through the production API.

Inspection of the pinned source shows that `pread_disk_io::async_release_files`
creates a fence job; `pread_storage::release_files` releases the file pool and
flushes part-file metadata. The equivalent mmap path also releases its pool.
Neither release operation establishes the complete payload/state fsync contract.
Consequently `cache_flushed_alert` alone is insufficient. Native persistence
formats and checkpoint schedules differ; setup, persistence
and whole-process measurements expose these differences.

In this revision, `torrent::save_resume_data(flush_disk_cache)` submits the
release fence but publishes `save_resume_data_alert` immediately, before its
completion. The reference therefore waits for `torrent_paused_alert`, explicitly
flushes and awaits `cache_flushed_alert`, fsyncs the payload, and only then asks
for and durably publishes resume data. Development failures exercising the
earlier incomplete barrier remain in the raw smoke artifacts.

## Artifacts

The default output is `.build/benchmarks/<UTC timestamp>/`. `environment.json`
records revisions, source hashes, compiler/build flags, machine/OS, filesystem,
resource limits, transport and cache conditions. `fixtures.json` records payload
and torrent SHA256 hashes. `trials.jsonl` retains every trial's phase events,
engine/counterpart measurements and errors. `summary.json` contains per-case
statistics. Failure and reopen logs remain in trial subdirectories. Successful
routine logs, temporary binaries and payloads are removed. Failed builds retain
`build.log`.

Earlier measurements in `docs/swift-engine.md`, `docs/audit.md` and the
11 November audit are historical and methodologically different. They are not
a baseline for this harness or evidence that these acceptance thresholds pass.

`BUTTER_BENCHMARK_CASE=single|many|concurrent`,
`BUTTER_BENCHMARK_FORMAT=v1|v2|hybrid` and
`BUTTER_BENCHMARK_DIRECTION=download|seed` select focused cases while iterating;
filters are recorded and do not constitute a full-matrix run.
`BUTTER_BENCHMARK_BASELINE=OUTPUT` compares candidate whole-process Swift peak
RSS against a full baseline with identical fixture hashes. It reports independent
bootstrap intervals for the median peak ratio and the observed maximum ratio;
both must remain within 1.10. A crossing interval extends the candidate case to
twelve pairs just like the throughput/CPU thresholds.

`Scripts/test-benchmark.sh --profile [OUTPUT]` runs separate Release profiling
trials for single-file v1/hybrid downloads, many-file hybrid downloads, and v1
seeding, for both engines. It samples both tested engine and counterpart for
two seconds using the system sampler. Sample stacks and raw CPU accounting are
retained; these instrumented results are labelled profile-only and never used
as timing acceptance evidence. Sampling attributes stacks and waits; allocation
counts require additional Instruments Allocations recordings when indicated.

Set `BUTTER_BENCHMARK_PROFILER=time-profiler` with `--profile` to capture
Instruments Time Profiler instead. Each engine is attached separately while
both drivers wait at ready; an Instruments start notification gates transfer
start. Recording stops after durable completion. The counterpart retains phase
CPU accounting but is not instrumented. Bounded startup, finish and export
deadlines retain failures and clean up children. Text TOC/sample XML exports
and `.cpu.json` summaries resolve references and include only Running samples
from the tested process. Sample weights are statistical attribution, not exact
CPU durations; inclusive percentages overlap. Binary `.trace` bundles stay
in the disposable build output and are not committed. Profile-only measurements
never replace the separate full timing matrix.

Set `BUTTER_BENCHMARK_PROFILER=file-activity` with `--profile` for filesystem
syscall events plus CPU sampling. It requests a trailing one-second recording
window to keep traces bounded; tables may include overlapping event spans. TOC,
sample and `FsSyscall` XML exports are saved automatically. This mode is only
for operation-size/frequency diagnostics, not whole-transfer CPU or syscall
counts. The installed File Activity model omits some operations visible in CPU
samples, including vector writes and `openat`; do not infer absent operations.
The [first observations](filesystem-write-observations-2026-11-12.json) retain
both validated bounded trials and the failed unbounded recording. Swift's
observed payload writes remain 16 KiB even inside admitted write batches.

The [source-matched CPU profiles](cpu-profiles-2026-11-12.md) retain all eight
four-case trials and a preceding two-trial capability run. They identify
whole-layout stamp scans and repeated hash-request set subtraction as separate
costs; CPU parity remains open.

Setting all three case/format/direction filters with `--profile` selects that
exact workload, including cases outside the default four-profile set.

`Scripts/test-benchmark.sh --compare-source [OUTPUT]` diagnoses source changes
using the same controller and pinned native binary. Set
`BUTTER_BENCHMARK_PREVIOUS_REVISION` to a compatible commit (default `1931e70`).
The script creates a disposable detached worktree, builds both Release engines
before timing, and links the same current driver source against each. It records
both source/package fingerprints and driver hashes, then removes the old
worktree and temporary builds on exit; cleanup failures retain their log.

By default this mode selects many-file v1 seeding and concurrent v2 seeding,
the two measured regressions. All three case/format/direction filters select an
explicit alternative. Each case has one warm-up per engine per source and a
fixed six balanced, reproducibly shuffled source-order pairs. Within each source
block, Swift/native order is also balanced. Native-to-native control trials use
the identical native binary under both labels. All processes and destinations
are fresh; sources are streamed warm, payloads independently digested and state
reopened. Source-prefixed trial IDs preserve every sample/failure separately.

The diagnostic reports paired current/previous Swift CPU, verified throughput,
whole-process RSS and native-counterpart CPU, plus native control ratios and
each source's normal native comparison. It never substitutes for the full
acceptance matrix, never retries to remove a loss, and leaves intervals crossing
one inconclusive. Its source pairs are fixed at six; the ordinary `--full`
acceptance extension policy remains unchanged.

## Checkpoint policy

Direct `TorrentStorage` callers retain `.immediate`. Managed transfers use a
one-second or 16 MiB newly verified payload budget, whichever arrives first.
Padding and repeated verification do not count towards that budget. A piece
which would exceed the remaining byte budget first commits existing progress;
verification and checkpoint work remain subject to the bounded disk worker.
The clock is injectable. A single owned task schedules expiry work; it does not
promise that a blocked filesystem call will finish within one second.

In-memory verified bits and the last committed bits are separate. Payload is
fsynced before publishing claims, and previously committed progress is durably
invalidated before overwriting its bytes. Failed flushes/publications retain
pending work and surface errors; explicit flush/save/shutdown can retry.
Completion, pause, save/export, shutdown and filesystem changes force a barrier.
Shutdown cancels and drains scheduled checkpoint work.

A restart retains uncheckpointed bytes. Before requesting an existing unverified
piece, the picker performs one bounded local check for that piece, lazily and
under existing disk admission limits. Only fully verified data is advertised;
missing or corrupt data falls back to normal requests. Recovery bookkeeping uses
bounded bitsets and introduces no eager payload scan or legacy resume importer.

## Recorded checkpoint experiment

The [complete pre-batching baseline](raw/baseline-seeding-fixed/summary.json)
contains 264 accepted trials and no failures. Its isolated commit `40e4347` has
the same tree as public commit `3a4df88`; the environment addendum records the
tree and build evidence. The [checkpoint-only comparison](raw/checkpoint-only/summary.json)
uses six pairs per direction for the single-file v1 case. These focused results
do not replace a final full-matrix comparison.

| Single-file v1 | Baseline Swift CPU s/GiB | Batched checkpoint CPU s/GiB | Swift/reference throughput ratio | Swift/reference CPU ratio | Peak RSS median / baseline |
| --- | ---: | ---: | ---: | ---: | ---: |
| Download | 13.83 | 12.67 | 0.277 (0.270–0.288) | 7.81 (7.38–7.90) | 0.987 |
| Seed | 10.24 | 10.49 | 0.276 (0.016–0.524) | 6.02 (5.87–6.27) | 0.989 |

Intervals are paired 95% bootstrap intervals against libtorrent. Both memory
checks pass, including the observed maxima. Both CPU/throughput targets fail.
Seeding includes very slow samples; all samples remain in the raw records.

Separate [Release profiles](raw/checkpoint-profiles/summary.json) cover both
engines and all four prescribed profiling workloads. Swift download stacks
show repeated piece-candidate sorting, disk-worker scheduling and file opens.
In the many-file hybrid sample, 183 of 213 sampled write-job stacks were inside
whole-layout stamp invalidation, largely `fstatat`. Seeding also shows per-wait
task/timer creation. These are sampled stacks, including waits, rather than
CPU percentages or allocation counts. Raw phase user/system accounting and
counterpart samples accompany them. No instrumented result enters acceptance.

Subsequent trials also retain Swift's most recent peer failure per transfer,
read through a bounded actor property without constructing snapshots. Both
engine and counterpart metrics expose `peer_errors`; the native driver retains
its bounded alert history. New environment records include production Swift
source hashes, both driver hashes and the reference CMake compiler/flag values.

The [raw directory](raw) also retains earlier harness failures and incomplete
diagnostic runs. They are historical development evidence, not pooled samples.

The [bounded-write experiment](raw/write-batching/summary.json) retains 66
accepted full-size v1 download trials. Each disk job accepts at most sixteen
blocks / 256 KiB, with at most eight temporary descriptors and unchanged queue
admission. Available frames flush before controls, yields and network waits.
Single-file CPU/GiB fell to 10.70, many-file to 18.21 and concurrent to 11.11.
Single/concurrent memory checks pass; the many-file memory interval remains
inconclusive after twelve pairs (median ratio 1.072, interval 1.051–1.106).
Parity remains unmet. A subsequent safeguard also validates the first opened
descriptor against its anchored pathname and recorded stamp, covering a
replacement between invalidation and open; final-candidate measurements must
include that check.

The [allocation experiment](raw/allocations/summary.json) completed six
single-file v1 download pairs: Swift 184.1 MB/s and 10.01 CPU s/GiB, versus
161.7 MB/s and 10.70 CPU s/GiB in the write-batching experiment. Peak memory
passes (median baseline ratio 1.011, interval 1.006–1.037). Fresh candidates are
kept in a bounded ordered prefix rather than sorting the entire remaining
torrent; payload frames use one allocation and storage/upload paths retain Data
slices instead of copying them. Selection order, restrictions, exact framing
and sliced payloads have focused regression coverage.

That development run was stopped during a seeding trial after reproducing
disconnect/reconnect stalls. Its failed interrupted trial, successful warm-ups
and complete download case remain in raw evidence. The seeding samples are
incomplete and cannot support an acceptance claim. Cleanup also masked the
original disconnect reason; correcting that diagnostic is required before the
final matrix.

The [seeding diagnostic](raw/seeding-diagnosis/summary.json) retained an output
byte-limit disconnect at 64.8 seconds. Admission now reserves the complete
encoded frame and message slot before disk work, within the existing 512 KiB /
128-message queue, 32-request and 64-job bounds. The [complete output-credit
comparison](raw/output-credits/summary.json) passed all fourteen full-size
trials. Its seven Swift transfers took 4.44–4.62 seconds without peer errors;
there were no reconnect outliers in that run. CPU parity remains unmet.

The [connection-deadline comparison](raw/connection-deadlines/summary.json)
completed 28 accepted trials. One clock task per connection now serves bounded
open/read/write entries; ordinary completions remove entries without creating
and cancelling another task. Earlier deadlines supersede the current timer,
with generation checks preventing a stale timer from failing new operations.
Close/cancellation still settle each operation through its original waiter.
Injected-clock tests exercise 1,000 completed operations under one timer,
earlier deadlines, clock failures and completion/cancellation/close races.

| Single-file v1 | Swift CPU s/GiB | Swift throughput MB/s | Peak RSS median / baseline |
| --- | ---: | ---: | ---: |
| Download | 7.93 | 192.5 | 0.190 |
| Seed | 8.23 | 267.4 | 0.217 |

Both memory checks pass; phase and independent whole-process RSS agree on the
large reduction in transient task-related memory pressure. All 319 package
tests pass, including encryption and µTP regressions. These focused experiments
still fail the CPU/throughput target and require the final full matrix.

## Final candidate verification and profiles

The [validation record](raw/validation/results.jsonl) retains all attempts,
including the early combined-contract deadline failure. The subsequent serial
run passed native/reference contracts, lifecycle, native process-crash and
volume-failure tests, bidirectional libtorrent TCP/MSE/µTP tests, the reference
engine suite, and unsigned Debug/Release builds with linkage checks. Separate
[package/sanitizer results](raw/validation/package-and-sanitizers.json) record
319 package tests and 47 focused tests under each sanitizer. Controller tests
pass eight cases / 40 assertions. No contract deadline or assertion was relaxed.

Final [Release samples](raw/final-profiles/summary.json) use the same native
dependency archives as the baseline. They remain separate from timing trials.

| Profile workload | Swift user / system CPU s | Reference user / system CPU s |
| --- | ---: | ---: |
| Single v1 download | 3.59 / 4.32 | 0.87 / 0.68 |
| Single hybrid download | 5.24 / 4.03 | 1.45 / 0.82 |
| Many-file hybrid download | 9.00 / 8.87 | 1.56 / 0.91 |
| Single v1 seed | 4.01 / 3.79 | 0.35 / 1.13 |

These single instrumented pairs attribute work, rather than estimate acceptance
intervals. Whole-layout stamp invalidation and anchored path inspections remain
prominent in the many-file stacks. Seeding retains per-block upload tasks,
disk-admission actor crossings and Network.framework sends. Those historical
profiles use the eight-request Swift default; the subsequent window experiment
above uses sixteen. Swift records its download pipeline and incoming upload
quotas, and the reference records its native request-queue defaults.
