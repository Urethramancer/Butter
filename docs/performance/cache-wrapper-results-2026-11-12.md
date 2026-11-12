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
including encryption, µTP and owner-close/cancellation coverage. Native
interoperability, broader comparisons and final release acceptance remain
open at this step. Raw evidence is in [`raw/cache-wrapper`](raw/cache-wrapper).
