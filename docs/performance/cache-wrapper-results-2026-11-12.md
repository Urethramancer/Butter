# Immutable upload-cache wrapper

Six balanced single-file v1 seeding source pairs show a small CPU and
throughput improvement. Current/previous CPU is 0.992 [0.977–0.997], verified
throughput 1.010 [1.007–1.029], and whole-process peak RSS 0.977 [0.911–1.035].
These are 95% paired median percentile bootstrap intervals, 10,000 resamples.
CPU falls 0.8% by the paired ratio; this does not establish native parity.

`VerifiedPieceCache` is now an immutable `Sendable` class. Its `piece` method
inherits the caller's actor through an isolation parameter, avoiding an extra
wrapper-actor hop for every upload block. Mutable cache state remains in
`SharedPieceCache`; owner closure remains lock-protected. Cache/disk budgets,
request windows, stored-byte hashing, eviction and cancellation are unchanged.
No benchmark-only path is introduced. The seeding profile identifies scheduling
costs; the measured total change does not isolate each executor's contribution.

The comparison builds production `5b9ef12` and evidence revision `642ccb8`
plus this source change, using the same driver source and one native binary
for all roles. Source hashes are archived and checked against the measured
worktree. Builds finish before timing. One 1 GiB v1 torrent, 256 KiB pieces,
warm sources and fresh processes/destinations are used. Four warm-ups precede
six balanced old/current source pairs, each containing a Swift/native pair.
All 28 trials pass independent digests and saved-state reopening; upload
completion is receiver-verified. This fixed source diagnostic does not replace
the full acceptance matrix or trigger uncertainty-driven sample extensions.

Swift medians are 3.163 → 3.136 CPU s/GiB through durable completion and
526.4 → 531.9 verified MB/s. Both variants pass original-baseline memory.
Native control throughput is 1.000 [0.999–1.010]; its CPU and counterpart CPU
intervals cross one. Full phase and counterpart measurements remain in every
raw trial. The latest full matrix remains production `5b9ef12` and fails CPU
in all eighteen cases.

All 342 serial package tests pass. All 42 focused transfer, resource,
admission and protocol tests pass under each of Address and Thread Sanitizer,
including encryption, µTP and owner-close/cancellation coverage. Committed
production `1d414f9` subsequently passes all 466 pinned native interoperability
checks, including bidirectional encrypted TCP/µTP, all 24 session DHT transfers
and HTTP-to-native-to-libtorrent web seeds. Broader performance comparisons and
final release acceptance remain open. Raw evidence is in
[`raw/cache-wrapper`](raw/cache-wrapper).

A subsequent source comparison at evidence revision `7911a61` tests four
simultaneous 256 MiB v2 seeds. All 28 trials pass. Paired current/previous CPU
is 1.004 [0.991–1.024], inconclusive; throughput is 1.008 [1.003–1.031], and
peak RSS 1.020 [0.976–1.067]. Swift medians are 3.602 → 3.618 CPU s/GiB and
795.2 → 799.5 verified MB/s. Both original-baseline memory gates pass. Native
control throughput is 0.999 [0.994–1.007], CPU 0.985 [0.922–1.103], and
counterpart CPU crosses one. No concurrent CPU gain is claimed or combined
with the single-file result. This also does not resolve the older full-run
seeding regressions. Identical measurement/sampling rules apply; raw evidence
is in [`raw/cache-wrapper-concurrent`](raw/cache-wrapper-concurrent).
