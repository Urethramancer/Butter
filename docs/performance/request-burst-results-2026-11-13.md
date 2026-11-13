# Ready TCP request bursts

First form `f3b6648` is disqualified by a seeding RSS regression despite its
download gains. All 112 source trials remain. A revised form restores original
scalar admission code before further measurement; the cause is not established.

Candidate `f3b6648` versus `ec966eb`: single-file 1 GiB v1 TCP download,
256 KiB pieces and production windows. Four warm-ups precede six balanced
source/engine pairs. All 28 trials validate independent payload digests and
saved-state reopening; no sample is retried or omitted.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.913 | 0.899–0.935 |
| Verified throughput | 1.047 | 1.016–1.073 |
| Peak RSS | 0.995 | 0.991–1.002 |
| Counterpart CPU seconds/GiB | 0.899 | 0.809–0.967 |

CPU falls 8.7%, throughput rises 4.7% and counterpart CPU falls 10.1%.
RSS is inconclusive, with no established increase; absence of cost remains
unproven. Native control CPU is inconclusive; control throughput falls 0.8%
[0.5–1.7%], retained separately. Raw Swift medians are 4.061 → 3.718 CPU
seconds/GiB and 315.2 → 327.1 MB/s. Candidate/native CPU remains 1.989
[1.940–2.004], with verified throughput 0.735 [0.727–0.761]. Parity is unmet.

Already-ready TCP requests share one bounded wire buffer and publish atomically
under one queue lock with one wake-up. Each remains a separate frame/message
for the existing sixteen-frame writer bound and 128-message admission limit.
The eight-request default, maximum 32-request burst, byte reservations, 512 KiB
queue budget and control order remain. Partial bursts flush immediately;
single requests and µTP retain individual-frame output. No production checks,
hashes, caches, request deadlines or transport backends change. Both sources
include the independent Unicode scanner correction.

New tests cover exact wire equivalence, empty/short/max bursts, µTP fallback,
atomic byte/message admission with upload reservations, malformed-field failure
before publication and close handling. All 362 package tests, 176 engine tests
under each sanitizer and Release build pass. Native interoperability and a
refreshed full matrix are not acceptance evidence for this disqualified form.

## Broader source cases

Each additional case uses its own fixed six pairs and four warm-ups. All
84 additional trials validate, without retries or extensions.

| Workload | CPU ratio [95%] | Throughput ratio [95%] | RSS ratio [95%] | Counterpart CPU ratio [95%] |
| --- | ---: | ---: | ---: | ---: |
| Many-file hybrid download | 0.962 [0.954–0.968] | 1.009 [1.007–1.025] | 0.996 [0.991–1.003] | 0.812 [0.797–0.850] |
| Concurrent hybrid download | 0.956 [0.940–0.960] | 1.022 [0.969–1.092] | 1.010 [0.972–1.036] | 0.972 [0.883–0.988] |
| Many-file v1 seeding | 1.011 [0.997–1.021] | 1.011 [0.979–1.072] | 1.050 [1.001–1.086] | 1.002 [0.990–1.015] |

Seeding establishes a 5.0% peak-RSS cost [0.1–8.6%], disqualifying this form.
Its CPU/throughput/counterpart CPU changes remain inconclusive. Native controls
cross one in all three additional cases. Download gains do not override the
seeding cost or prove absence of other costs. No combined score is reported.

The next candidate restores upload encoding, output joining and scalar enqueue
bodies exactly to `ec966eb`, keeping burst-specific admission separate. This
removes a change to the ordinary upload path but does not prove the RSS cause.
It is a changed candidate, not a retry of this measurement.

[Measurements, validation and raw hashes](request-burst-comparison-2026-11-13.json)
retain evidence. Raw trials remain in
`.build/benchmarks/request-burst-single-v1-source-order`.
