# Revised request bursts: full matrix

Candidate `93a41c8`, measured at `6b5d1c0`: all 252 trials validate with zero
failures across eighteen cases. Throughput passes 9/18, CPU 0/18 and original
Swift-baseline memory 18/18. CPU/native paired medians range from 1.510 to
3.845. CPU parity remains unmet; no combined workload score is reported.

Each case uses one declared warm-up per engine and six balanced, reproducibly
shuffled measured pairs. No acceptance interval crosses a threshold, so none
extends to twelve pairs. Fresh processes/destinations and explicitly warm sources
are used; no cold-cache claim is made. Fixtures are one 1 GiB file, 128 equal
files totalling 1 GiB, and four simultaneous 256 MiB files, with 256 KiB pieces
and v1/v2/hybrid metadata. Fixture hashes match the preceding full matrix.
Both engines use the same pinned native counterpart. Independent streaming
digests and saved-state reopening validate every trial. Upload trials finish
when the receiver verifies the payload.

Ratios are Swift/native paired medians with 95% bootstrap intervals. Verified
and durable throughput remain separate; CPU is seconds/GiB through durable
completion. Raw records retain setup, transfer, persistence, shutdown,
whole-process wall/user/system/RSS and counterpart metrics. Native persistence
placement differences and equivalent payload/state fsync barriers are labelled
in the environment. Peak Swift RSS is 14,991,360–43,253,760 bytes across measured
trials. Passing the original baseline memory target does not prove absence of
a source memory cost.

| Workload | Format | Direction | Verified throughput ratio [95%] | Durable throughput ratio [95%] | CPU ratio [95%] |
| --- | --- | --- | --- | --- | --- |
| single | v1 | download | 0.739 [0.728–0.772] | 0.897 [0.797–0.929] | 2.004 [1.975–2.052] |
| single | v1 | seed | 1.271 [1.210–1.313] | 1.271 [1.210–1.313] | 1.510 [1.451–1.534] |
| single | v2 | download | 0.697 [0.688–0.723] | 0.862 [0.757–0.899] | 2.112 [2.036–2.175] |
| single | v2 | seed | 1.260 [1.155–1.313] | 1.263 [1.159–1.316] | 1.526 [1.504–1.643] |
| single | hybrid | download | 0.634 [0.618–0.649] | 0.711 [0.665–0.786] | 1.692 [1.637–1.761] |
| single | hybrid | seed | 1.394 [1.378–1.419] | 1.401 [1.383–1.424] | 1.686 [1.576–1.731] |
| many | v1 | download | 0.338 [0.336–0.350] | 0.342 [0.337–0.352] | 3.845 [3.747–4.078] |
| many | v1 | seed | 0.867 [0.819–0.882] | 0.867 [0.820–0.882] | 2.109 [1.995–2.217] |
| many | v2 | download | 0.342 [0.328–0.366] | 0.346 [0.331–0.372] | 3.843 [3.703–3.991] |
| many | v2 | seed | 0.776 [0.601–0.807] | 0.779 [0.604–0.809] | 2.018 [1.946–2.093] |
| many | hybrid | download | 0.311 [0.308–0.336] | 0.312 [0.310–0.339] | 3.006 [2.956–3.230] |
| many | hybrid | seed | 0.625 [0.621–0.639] | 0.628 [0.623–0.642] | 2.363 [2.309–2.439] |
| concurrent | v1 | download | 1.295 [1.213–1.353] | 1.645 [1.460–1.742] | 2.480 [2.409–2.559] |
| concurrent | v1 | seed | 1.721 [1.649–1.731] | 1.712 [1.650–1.725] | 1.521 [1.344–1.585] |
| concurrent | v2 | download | 1.299 [1.252–1.331] | 1.583 [1.521–1.790] | 2.469 [2.360–2.547] |
| concurrent | v2 | seed | 1.869 [1.858–1.899] | 1.878 [1.858–1.910] | 1.558 [1.489–1.611] |
| concurrent | hybrid | download | 1.249 [1.148–1.311] | 1.507 [1.349–1.700] | 2.056 [1.968–2.481] |
| concurrent | hybrid | seed | 1.606 [1.590–1.676] | 1.610 [1.600–1.691] | 1.797 [1.708–1.869] |

Single-file v1 medians are 331.3 versus 447.7 MB/s, using 3.697 versus 1.835
CPU seconds/GiB. Many-file hybrid reaches 139.0 versus 447.8 MB/s, using
7.926 versus 2.636 CPU seconds/GiB. Many-file downloads remain the largest gap:
31.1–34.2% native throughput and 3.01–3.84 times CPU.

The [preceding full matrix](write-prefill-full-results-2026-11-13.md) is an
independent historical run, not a causal source estimate. Some absolute seeding
metrics worsen: concurrent v1 CPU is 2.995 versus 2.800 seconds/GiB; many-file
v2 seeding throughput is 330.8 versus 361.6 MB/s. Native measurements also
shift. These differences remain open rather than being dismissed or attributed
to the candidate. The [balanced source comparisons](request-burst-revised-results-2026-11-13.md)
separately establish download CPU/throughput gains, but RSS and seeding remain
inconclusive. The first form's established seeding RSS cost remains recorded;
this full run does not prove the revision resolves it.

The production request window remains eight; queue/disk limits, caches,
stored-byte hashing, filesystem ownership safeguards and cancellation remain.
All 94 production-source hashes match the measured candidate. Correctness
validation passes 362 package tests, 25 focused tests under each sanitizer,
466 native interoperability PASS records (including encryption and µTP),
52 real-volume storage checks, application contracts/lifecycle, Debug/Release
builds, linkage/licences and unchanged repeat build. User Xcode edits remain
untouched. [Validation evidence](request-burst-revised-validation-2026-11-13.json)
retains log hashes. [Fresh profiles of both engines](request-burst-profiles-2026-11-13.md)
validate eight diagnostic trials and still identify filesystem calls and scans
as the largest download cost.

[Absolute medians and intervals](request-burst-revised-full-comparison-2026-11-13.csv),
[complete summary](request-burst-revised-full-summary-2026-11-13.json) and
[source checks/raw hashes](request-burst-revised-full-evidence-2026-11-13.json)
retain evidence. Raw phases, environment and trials remain under
`.build/benchmarks/request-burst-scalar-full`; disposable payloads, binaries
and successful per-trial routine logs are removed by the wrapper. No release,
parity or cost-free claim is made.
