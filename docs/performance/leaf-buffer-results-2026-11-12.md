# Merkle leaf buffer experiment

Rejected and reverted. For a single 1 GiB hybrid download, six balanced source
pairs give current/previous CPU 1.015 [0.991–1.036], verified throughput 0.977
[0.958–1.020] and peak RSS 0.999 [0.967–1.017]. Intervals are 95% paired median
percentile bootstrap with 10,000 resamples. There is no reproducible benefit.

The candidate hashes each 16 KiB Merkle leaf directly from a scoped raw-buffer
view of bytes read from storage, instead of first making `Data.subdata`.
Stored-byte reads, SHA1, leaf boundaries, SHA256, Merkle validation, file checks
and all admission/cache limits remain unchanged. The tested source is
`efe8f2d` plus the archived patch, compared with production `5b9ef12`, using
identical driver source and one pinned native binary for all roles. Builds
finish before timing. Fresh processes/destinations use explicitly warm sources
and 256 KiB pieces. One warm-up per engine/source precedes six balanced pairs.

All 28 trials pass independent payload digests and saved-state reopening.
Swift medians are 3.532 → 3.594 CPU s/GiB through durable completion and
343.0 → 337.0 verified MB/s. Native control CPU crosses one; native throughput
is 1.004 [1.002–1.016], so environmental/reference variation remains explicit.
Both variants pass original-baseline memory. This fixed source diagnostic does
not replace the full acceptance matrix.

All 342 serial package tests pass, as do all 54 storage tests under each of
Address and Thread Sanitizer, including large v2/hybrid reads, partial leaves,
corruption and authenticated restart. No production change survives. Raw
source/build hashes, environment, trials, checks and rejected patch are in
[`raw/leaf-buffer`](raw/leaf-buffer).
