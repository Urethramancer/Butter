# Group pending upload payload workers

Six balanced single-file v1 seeding source pairs reduce CPU by 16.5% and raise
verified throughput by 11.6%. Current/previous CPU is 0.835 [0.826–0.848],
throughput 1.116 [1.104–1.138], and whole-process peak RSS 1.008 [0.989–1.028].
Intervals are 95% paired median percentile bootstrap, 10,000 resamples.
Both original-baseline and incremental memory comparisons pass.

Pending requests for one peer and piece now share a payload worker. Each
block retains its independent token, output reservation and admission slot.
Cancelling one request leaves its neighbours running; cancellation of all
requests detaches and cancels that worker so replacement requests start fresh.
Unique worker IDs prevent a retiring worker from removing its replacement.
Peer disconnect and shutdown cancel/join each worker once. Workers flush
available work after the existing verified piece read; they never wait for a
full group. No disk, cache, request, output or admission cap is raised, and
stored-byte hashing and filesystem safeguards remain unchanged.

The [fresh baseline profile](upload-scheduling-profile-2026-11-12.md) identifies
upload tasks and scheduling as material costs. Production `1d414f9` is compared
with evidence revision `98eb213` plus the measured source hashes. Both Release
packages use identical driver source and the same pinned native binary in all
reference/counterpart roles. Builds finish before timing. The case is one 1 GiB
v1 seed, 256 KiB pieces, warm source files, and fresh processes/destinations.
Four warm-ups precede six balanced source pairs, each with one Swift/native
pair per source. All 28 trials pass independent payload digests and saved-state
reopening. Upload completion is receiver-verified. This fixed source diagnostic
does not replace full-matrix acceptance.

Swift medians are 3.178 → 2.658 CPU s/GiB through durable completion and
540.2 → 607.8 verified MB/s. Native control throughput is 1.005 [0.993–1.021],
CPU 1.013 [0.845–1.072], and counterpart CPU 0.993 [0.956–1.006]. Native
variation is retained explicitly, and native-relative CPU still misses the
unchanged 1.25× gate. The latest full matrix remains production `5b9ef12`.

All 344 serial package tests pass. All 46 focused transfer, admission, output,
cache and protocol tests pass under each of Address and Thread Sanitizer.
New gated tests cover independent cancellation/replacement, choke/re-unchoke,
disconnect of one peer sharing a read with another, and shutdown while disk
admission remains blocked. They verify exact payloads and complete work/cache
drain. The cancellation/replacement contract was proved first on unchanged
production. Native interoperability, many-file/concurrent performance and final
acceptance remain open at this step. Raw environment, source hashes, trials
and checks are in [`raw/upload-groups`](raw/upload-groups).
