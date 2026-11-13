# Ready TCP request bursts

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
under each sanitizer and Release build pass. Broader source comparisons,
native interoperability and a refreshed full matrix remain pending. This is
focused evidence, not release or parity acceptance.

[Measurements, validation and raw hashes](request-burst-comparison-2026-11-13.json)
retain evidence. Raw trials remain in
`.build/benchmarks/request-burst-single-v1-source-order`.
