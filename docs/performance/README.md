# Swift/libtorrent transfer comparison

Acceptance requires Swift to reach at least 90% of libtorrent's verified TCP
throughput, at most 1.25 times its CPU seconds per GiB through durable completion,
and peak RSS within 10% of the fresh Swift baseline. Results are per workload;
there is no combined performance score. Encryption and µTP remain correctness
regressions, outside this throughput milestone.

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

Inspection of the pinned source shows that `pread_disk_io::async_release_files`
creates a fence job; `pread_storage::release_files` releases the file pool and
flushes part-file metadata. The equivalent mmap path also releases its pool.
Neither release operation establishes the complete payload/state fsync contract.
Consequently `cache_flushed_alert` alone is insufficient. Native persistence
formats and Swift's immediate per-piece checkpoints differ; setup, persistence
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
