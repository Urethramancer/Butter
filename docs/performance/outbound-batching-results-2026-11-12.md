# Available TCP output batching — 12 November 2026

The focused single-file v1 seeding comparison accepted all fourteen trials:
one warm-up per engine and six balanced measured pairs. Swift CPU fell from
7.99 to 4.98 seconds/GiB through durable completion, and verified-transfer
throughput rose from 274.0 to 393.4 MB/s. This is one case, not a full-matrix
acceptance result. The [latest full matrix](snapshot-reuse-results-2026-11-12.md)
remains the preceding snapshot-reuse candidate.

| Metric | Previous full candidate | TCP output batching |
| --- | ---: | ---: |
| Swift CPU seconds/GiB | 7.990 | 4.978 |
| Swift verified throughput, MB/s | 274.0 | 393.4 |
| Paired CPU ratio to libtorrent, 95% interval | 4.657 [4.507–4.765] | 3.216 [3.063–3.500] |
| Paired throughput ratio to libtorrent, 95% interval | 0.615 [0.611–0.626] | 0.870 [0.864–0.871] |
| Median peak RSS / original Swift baseline | 0.213 | 0.215 |

The independent before/after CPU ratio is 0.623 [0.614–0.628], a reduction of
37–39%. Cross-commit samples are not paired; the paired native ratios above
come from each run's balanced engine pairs. Native CPU also changed between
runs, so the absolute Swift reduction and native-relative ratios are reported
separately. CPU and throughput both remain outside the unchanged targets.

## Implementation and bounds

Commit `148d71c` drains only frames already available, up to sixteen frames and
256 KiB per TCP write. It never waits to fill a batch. FIFO order is retained;
cancelled payload is filtered before claiming a write, and upload accounting
occurs after the complete write succeeds. The wake-up signal is coalesced while
the bounded queue owns the frames. Existing 128-message/512 KiB queued-plus-
reserved output caps, 32 per-peer upload requests and 64 transfer jobs remain.
Rate-limited traffic and µTP retain single-frame writes.

The measured environment records parent commit `4e6d125` plus the uncommitted
experiment; its complete Swift source hashes match the subsequently committed
`148d71c`. Production windows, fixture, pinned native counterpart, warm-source
cache policy and independent post-measurement digest/state reopening are the
[same comparison method](README.md). No benchmark-only production path was added.

## Evidence

- [Every trial](raw/outbound-batch-single-v1/trials.jsonl), [summary](raw/outbound-batch-single-v1/summary.json), [environment/source hashes](raw/outbound-batch-single-v1/environment.json) and [fixtures](raw/outbound-batch-single-v1/fixtures.json).
- [Before/after CPU calculation](raw/outbound-batch-single-v1/before-after-cpu.json), using 10,000 independent median bootstrap resamples and seed 11011.
- [Focused checks](raw/outbound-batch-single-v1/checks.json): final output tests and 24 tests under each sanitizer.
- [Initial parallel package failure](raw/outbound-batch-single-v1/initial-package-failure.log): concurrent fixtures exhausted shared disk-command admission; a stream test also assumed a complete payload in one TCP read. The stream assertion was corrected in `4e6d125`, production limits were retained, and serial tests passed.

All 324 package tests passed serially. The nine contract, lifecycle, native
storage/failure, interruption, disk/peer/engine reference and application
build/linkage checks passed: [validation records](raw/outbound-batch-validation/results.jsonl).
Both engines were separately profiled after validation: [profile artifacts](raw/outbound-batch-profile/summary.json).
The fresh Swift sample still contains stored-byte hashing, anchored file opens,
Network.framework work, per-block admission and a repeated wanted-set scan in
`PiecePicker.interested` while seeding. Sampling includes idle waits and is not
a CPU-percentage accounting method. Full-matrix candidate measurements remain outstanding.
No parity or release claim is made, and no tag was created.
