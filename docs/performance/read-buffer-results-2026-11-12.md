# Single-buffer stored-byte read experiment

Rejected and reverted. Six balanced source pairs show current/previous CPU
0.987 [0.968–1.021], verified throughput 1.022 [0.974–1.080] and whole-process
peak RSS 1.008 [0.993–1.029]. These 95% paired median percentile bootstrap
intervals use 10,000 resamples. No reproducible benefit is established.

The candidate allocates one bounded result buffer for an unverified payload
read, filling it with the original 64 KiB cancellable reads rather than
allocating/appending a temporary `Data` per chunk. Verification reads stored
bytes through this path. Padding remains zero; file checks, hashes, admission
and memory caps are unchanged. Production `5b9ef12` is compared with `5e355f5`
plus the archived patch, using identical driver source and one pinned native
binary for every reference/counterpart role. Builds precede timing.

All 28 trials pass streaming digests and saved-state reopening. The diagnostic
uses one warm-up per source/engine followed by six balanced source pairs for
one 1 GiB v1 download, 256 KiB pieces, warm sources and fresh processes and
destinations. Swift medians are 3.445 → 3.376 CPU s/GiB through durable
completion and 365.5 → 376.5 verified MB/s. Native control intervals cross one;
both original-baseline memory gates pass. The fixed diagnostic does not replace
full-matrix acceptance or hide the remaining CPU gap.

The candidate passes all 342 serial package tests and all 54 storage tests
under Address and Thread Sanitizer. One new parameterised test, proved first
on unchanged production, interrupts a read after its first 64 KiB by cancellation
or truncation and verifies subsequent exact read/hash recovery. It remains;
the production change is reverted. Raw measurements, source/driver hashes,
checks and rejected patch are in [`raw/read-buffer`](raw/read-buffer).
