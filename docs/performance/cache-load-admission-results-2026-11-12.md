# Admit disk work on cache loads — 12 November 2026

Moving disk admission from every upload block to the actual verified cache load
reduces many-file v2 seeding CPU from 7.642 to 6.128 seconds/GiB through durable
completion. The independent before/after median ratio is 0.802 [0.713–0.914]
at 95% (10,000 bootstrap resamples). Verified throughput changes from 251.5 to
264.6 MB/s, ratio 1.052 [0.925–1.334]; that gain remains inconclusive.

Both runs retain fourteen accepted trials: one warm-up per engine, followed by
six balanced measured pairs. The workload is 1 GiB across 128 files, v2 metadata
with 256 KiB pieces, plaintext TCP, production request windows and explicitly
warm sources. Processes and destinations are fresh. Every trial includes
independent digest and saved-state checks. Cross-commit samples are not paired.

## Behaviour and bounds

A cache hit or another request joining an existing load no longer acquires and
releases disk permits. Each actual cache load acquires the same transfer-local
and session-wide disk scope as before. Reads still hash stored bytes and check
filesystem ownership and external modifications. The four-load owner limit,
64-load global limit, cache byte limits, upload request/job caps and output
reservations remain unchanged. No new cache or request-window allowance is added.

The regression test fails on the preceding implementation: a cached upload
times out while another disk scope occupies the sole global permit. The new
implementation serves that hit, queues a cold piece until capacity is available,
and cancels a further queued load on cache close without releasing the blocking
scope's permit or retaining cache bytes.

All 332 package tests passed serially. The 25 focused upload/resource/completion
tests passed, and all 32 resource, upload, completion, encryption and µTP tests
passed under each sanitizer. Address Sanitizer's encryption cases ran separately
from its other 29 cases. Committed source `9c90973` subsequently passed all nine
native contract, lifecycle, storage/failure, interruption, disk/peer/engine
reference and Debug/Release application/linkage suites. A new full matrix is
still outstanding.

## Separate profile

A fresh Release profile captures both engines and their counterparts in this
same seeding workload. These two profiled trials are labelled `profile-only`
and excluded from timing acceptance. Swift's sample still contains whole-layout
file-stamp scans (`fstatat` and path handling), stored-byte SHA-256/Merkle hashing,
allocations, scheduling and Network.framework calls. The native sample contains
file reads and socket work. Samples include idle waits and do not establish CPU
percentages. The previous bulk-attribute experiment remains rejected; these
samples do not justify bypassing verification or caching file identities across
operations.

Separately, the six timing samples give median user/system CPU seconds through
durable completion of 3.071/3.059 for Swift and 0.421/1.517 for native. These are
independent medians of each component, rather than a decomposition of a selected
median trial.

## Memory and remaining gap

Whole-process peak RSS is 25.58 MiB median and 26.03 MiB maximum, compared with
22.41/23.50 MiB immediately before this change. The incremental median ratio is
1.142 [1.080–1.172], with observed maximum ratio 1.108. This stricter comparison
remains inconclusive at the 10% boundary and is not labelled as a pass.

The unchanged original fresh-baseline gate passes: median ratio 0.229
[0.225–0.233], maximum ratio 0.232. Its corresponding baseline median/maximum
are 111.62/112.08 MiB. The incremental increase is retained explicitly alongside
the CPU benefit; the original baseline has not been replaced.

Native medians in this run are 1.938 CPU seconds/GiB and 427.0 MB/s. Paired
Swift/native CPU is 3.257 [3.051–3.535], verified throughput is 0.653
[0.542–0.767], and durable throughput is 0.656 [0.547–0.772]. The 1.25× CPU
and 90% throughput targets remain unmet. This focused result does not establish
other workloads; the latest complete matrix remains the earlier
[TCP batching matrix](tcp-batching-results-2026-11-12.md).

## Evidence

- [Every trial](raw/cache-load-admission-many-v2/trials.jsonl), [summary](raw/cache-load-admission-many-v2/summary.json), [environment and measured source hashes](raw/cache-load-admission-many-v2/environment.json), [fixtures](raw/cache-load-admission-many-v2/fixtures.json).
- [Before/after intervals](raw/cache-load-admission-many-v2/before-after.json), [incremental memory and individual measurements](raw/cache-load-admission-many-v2/memory-versus-immediate-before.json), [preceding run](raw/available-input-seeding/summary.json).
- [Original failing regression](raw/cache-load-admission-many-v2/test-before-failure.log).
- [Package and sanitizer checks](raw/cache-load-admission-many-v2/checks.json).
- [All nine native integration checks](raw/cache-load-admission-integration/results.jsonl).
- [Separate profile trials](raw/cache-load-admission-profile/trials.jsonl), [Swift seeding sample](raw/cache-load-admission-profile/many-v2-seed-0-Swift-measured-seed.sample.txt), [native seeding sample](raw/cache-load-admission-profile/many-v2-seed-0-libtorrent-measured-seed.sample.txt), [profile environment](raw/cache-load-admission-profile/environment.json).

Production and harness hashes were checked against the timed run before saving
these artifacts. Later test-only coverage adds queued-load closure. No trial
was retried or discarded and no tag was created.
