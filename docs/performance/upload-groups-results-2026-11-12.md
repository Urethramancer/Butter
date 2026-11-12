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
production. Committed production `61584b7` subsequently passes all 466 pinned
native interoperability checks, including encrypted TCP/µTP, all 24 independent
session DHT transfers and ten HTTP-to-native-to-libtorrent web-seed comparisons.
Final acceptance remains open. Raw environment, source hashes, trials
and checks are in [`raw/upload-groups`](raw/upload-groups).

Committed production `61584b7` then completes 56 further trials against
`1d414f9`, six source pairs per case with identical sampling and validation.
All pass. CPU improves in both cases; many-file throughput remains inconclusive.

| Seeding case | Swift CPU s/GiB before → after | Verified MB/s before → after | Paired CPU ratio [95%] | Paired throughput ratio [95%] | Paired peak RSS [95%] |
| --- | ---: | ---: | --- | --- | --- |
| 128 files / v1 | 5.072 → 4.158 | 388.2 → 388.0 | 0.831 [0.813–0.838] | 0.999 [0.990–1.008] | 0.949 [0.926–0.997] |
| Four concurrent / v2 | 3.617 → 3.182 | 798.5 → 874.2 | 0.871 [0.863–0.895] | 1.096 [1.073–1.108] | 0.996 [0.951–1.008] |

Both original-baseline memory gates pass. Native control CPU/throughput
intervals cross one in each case. Many-file counterpart CPU is 1.018
[0.997–1.034], concurrent 0.980 [0.958–1.004]; neither excludes one. Every
phase measurement and diagnostic remains in
[`raw/upload-groups-broader`](raw/upload-groups-broader). These source comparisons
do not replace original full-run samples, resolve their sequence/environment
regressions, or establish full-matrix/native CPU parity. Final acceptance remains
open.
