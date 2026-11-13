# Revised ready TCP request bursts

Candidate `93a41c8` restores original scalar output admission while retaining
bounded ready-request bursts. Baseline is `ec966eb`. These measurements belong
to the revised source; the first form's seeding RSS regression remains recorded.

Each case uses four warm-ups and six balanced source/engine pairs, production
windows, fresh processes/destinations and explicitly warm source files. All
112 trials pass independent payload digests and saved-state reopening; none is
retried or replaced. Ratios below are revised/previous, with 95% paired median
bootstrap intervals.

| Case | CPU/GiB | Verified throughput | Peak RSS | Counterpart CPU/GiB |
| --- | ---: | ---: | ---: | ---: |
| Single-file v1 download | 0.917 [0.907–0.927] | 1.037 [1.024–1.055] | 0.996 [0.984–1.006] | 0.914 [0.857–0.960] |
| Many-file hybrid download | 0.955 [0.938–0.969] | 1.020 [1.004–1.042] | 1.005 [0.980–1.051] | 0.829 [0.795–0.841] |
| Concurrent hybrid download | 0.942 [0.925–0.954] | 1.036 [1.014–1.094] | 1.037 [0.975–1.073] | 0.905 [0.860–1.073] |
| Many-file v1 seeding | 1.002 [0.991–1.051] | 0.959 [0.831–1.052] | 1.029 [0.966–1.079] | 0.995 [0.985–1.040] |

Single-file download CPU falls 8.3% and throughput rises 3.7%; counterpart CPU
falls 8.6%. RSS remains inconclusive. Raw Swift medians are 4.042 → 3.716 CPU
seconds/GiB and 322.5 → 333.7 MB/s. Revised/native paired CPU is 1.988
[1.959–2.205] and throughput 0.748 [0.738–0.757]. Native controls cross one.

Many-file hybrid download CPU falls 4.5% and throughput rises 2.0%, with
counterpart CPU falling 17.1%. RSS remains inconclusive. Revised medians are
8.192 CPU seconds/GiB and 137.3 MB/s. Revised/native paired CPU is 2.985
[2.972–3.042] and throughput 0.303 [0.300–0.308]. Native control CPU crosses
one; control throughput rises 0.7% [0.3–1.5%], retained separately. Measured
revision `b552f76` has identical production source and package hashes to
`93a41c8`; the intervening commit only records results.

Concurrent hybrid download CPU falls 5.8% and throughput rises 3.6%; RSS and
counterpart CPU remain inconclusive. Swift medians are 6.877 → 6.466 CPU
seconds/GiB and 620.3 → 638.3 MB/s. Revised/native paired CPU is 1.941
[1.935–2.388] and throughput 1.226 [1.186–1.288]. Native controls cross one.
Measured revision `80a0c9a` has matching production source/package hashes.

Seeding establishes neither improvement nor regression. Its wide intervals
do not prove the first form's RSS cost is resolved. Revised/native paired CPU
is 2.301 [2.223–2.602] and throughput 0.810 [0.656–0.915]. Native controls also
cross one. No cost-free or parity claim is made. The
[full matrix](request-burst-revised-full-results-2026-11-13.md) validates all 252
trials but still misses CPU acceptance in every case.

Correctness validation passes 362 package tests, 25 focused ownership tests under
each of AddressSanitizer and ThreadSanitizer, Release build and the complete
native bidirectional suite (466 PASS records, including encryption and µTP).
Application contracts/lifecycle, 63 storage unit tests and 52 native real-volume
failure/interruption checks pass. Unsigned Debug/Release app builds, linkage,
retained licences and unchanged repeat build also pass. Production source hashes
still match `93a41c8`; user Xcode edits remain untouched.
[Validation evidence](request-burst-revised-validation-2026-11-13.json) retains
counts and log hashes. These checks do not resolve performance uncertainty.

The seeding wrapper's tool handle was lost before observation of finalisation.
Subsequent inspection finds its normal summary, final success log message and
no remaining worktree. This supersedes the earlier interruption diagnosis;
the reconstructed statistics match the normal summary. No wrapper exit status
was observed for that run. The single-file wrapper exits successfully.

[Summaries and raw artifact hashes](request-burst-revised-comparison-2026-11-13.json)
preserve all four cases under `.build/benchmarks/request-burst-scalar-*`.
