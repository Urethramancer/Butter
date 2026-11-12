# CPU profiles after owned-buffer returns

Production `b328472` passes ten profile-only trials: both engines in single v1
download, single hybrid download, many hybrid download, single v1 seeding and
many v1 seeding. All recorded production source hashes match. Payload digests
and saved-state reopening pass. These instrumented trials are separate from
the [full timing matrix](piece-buffer-full-results-2026-11-12.md).

Time Profiler attaches to the tested process before start and stops after durable
completion. Analysis includes only Running samples for that PID. Inclusive
fractions overlap and cannot be added. Sample weights are statistical, not
measured CPU durations; kernel/trampoline leaf symbols do not establish thread
creation cost. Counterparts are uninstrumented with phase measurements retained.

| Case | Remaining Swift costs |
| --- | --- |
| Single v1 download | Flat SHA1 16.5%, write 10.6%, copy 8.3%, open 5.6%, close 4.5%; write operation 26.1% inclusive |
| Single hybrid download | Flat SHA1 13.3%, SHA256 13.0%, write 9.9%, copy 7.2%; write operation 23.5% inclusive |
| Many hybrid download | Stamps 34.1% and write operation 40.0% inclusive; flat stat 21.3%, open 17.4%, write 6.0% |
| Single v1 seed | Flat SHA1 18.3%, copy 5.3%, send 5.2%, read 3.9%; global enqueue 2.3% inclusive |
| Many v1 seed | Stamps 40.0% inclusive; flat stat 26.0%, SHA1 11.1%, open 5.2%, copy 3.1% |

| Case | Swift/native Running samples | Swift user/system s | Native user/system s |
| --- | ---: | ---: | ---: |
| Single v1 download | 2,828 / 1,528 | 1.450 / 1.408 | 0.860 / 0.685 |
| Single hybrid download | 3,431 / 2,148 | 2.046 / 1.449 | 1.411 / 0.791 |
| Many hybrid download | 6,647 / 2,343 | 2.976 / 3.757 | 1.552 / 0.844 |
| Single v1 seed | 2,435 / 1,577 | 1.492 / 0.974 | 0.368 / 1.373 |
| Many v1 seed | 4,029 / 1,866 | 1.957 / 2.172 | 0.401 / 1.594 |

These are one instrumented trial per engine/case, not timing medians. Native
profiles primarily show accelerated hashes, receive/vector writes and memory
copying for downloads, and read/send/pthread coordination for seeding. Missing
native backtraces reach 3.5% (single v1 download); all Swift backtraces are
available. Attribution remains statistical and instrumentation overhead applies.

The many-file filesystem cost remains substantial. Inspect actual write-batch
sizes and file-open frequency before changing scheduling or storage. Earlier
queued and explicit multi-piece read batching did not establish benefit. Any
next change must retain full-layout guards, stored-byte hashes, independent
cancellation and existing queue limits. Neither profiles nor focused timing
establish native parity; the complete matrix still fails CPU in all cases.

[Compact machine-readable results](piece-buffer-profile-summary-2026-11-12.json)
retain both engines' leading symbols, phase CPU, missing-backtrace counts and
raw-export hashes. XML, complete rankings, counterpart phases and metadata remain
locally under `.build/benchmarks/piece-buffer-standard-profiles` and
`.build/benchmarks/piece-buffer-many-seed-profile`. Successful trace bundles and
routine profiler logs are removed after exports; no large traces enter the repo.
