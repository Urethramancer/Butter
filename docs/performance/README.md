# Swift/libtorrent transfer comparison

Acceptance requires Swift to reach at least 90% of libtorrent's verified TCP
throughput, at most 1.25 times its CPU seconds per GiB through durable completion,
and peak RSS within 10% of the fresh Swift baseline. Results are per workload;
there is no combined performance score. Encryption and µTP remain correctness
regressions, outside this throughput milestone.

The [latest full comparison](framed-window-results-2026-11-12.md) retains 252
accepted trials and no failures for production source `1931e70`. Memory passes
all eighteen cases, nine meet throughput, and every case still fails CPU. All
cases finish six measured pairs without an acceptance interval crossing a
threshold. Against the [preceding full candidate](tcp-batching-results-2026-11-12.md),
fourteen independent CPU intervals improve, single-file hybrid download uses
2.8% more CPU and three comparisons remain inconclusive. Per-case measured peak
RSS spans 15–48 MiB. Every case, uncertainty interval and raw artifact is retained.

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

The [source-matched CPU profiles](cpu-profiles-2026-11-12.md) retain all eight
four-case trials and a preceding two-trial capability run. They identify
whole-layout stamp scans and repeated hash-request set subtraction as separate
costs; CPU parity remains open.

Setting all three case/format/direction filters with `--profile` selects that
exact workload, including cases outside the default four-profile set.

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
disk-admission actor crossings and Network.framework sends. Request-window
defaults remain unchanged; Swift records its download pipeline and incoming
upload quotas, and the reference records its native request-queue defaults.
