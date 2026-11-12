# Authenticated hash readiness — 12 November 2026

The on-CPU profile showed 14.1% of single-file hybrid download sample weight
under hash-request selection. It repeatedly constructed wanted minus available
hashes even when that difference was empty. A boolean now records when all
fixed wanted pieces have authenticated hashes. It is initialised from the
storage hash set and rechecked when authenticated hashes accumulate. Missing
hash requests, proof verification, staged hybrid data, request windows and disk
checks retain their existing behaviour. No cache or queue limit increases.

Fourteen trials passed (one warm-up per engine and six balanced measured pairs),
with production windows, warm sources, fresh destinations, independent payload
digest and saved-state reopen. Against the preceding full candidate:

| Single-file hybrid download | Before | After | Independent ratio [95%] |
| --- | ---: | ---: | --- |
| Swift CPU seconds/GiB through durable | 6.950 | 6.019 | 0.866 [0.829–0.890] |
| Swift verified MB/s | 182.4 | 213.1 | 1.168 [1.135–1.258] |

CPU falls 13.4%; throughput rises 16.8%. Both original-baseline and incremental
memory gates pass. Incremental median peak RSS ratio is 1.034 [1.008–1.044],
with observed maximum ratio 0.999. The earlier hybrid regression against the
TCP-batching candidate is also resolved by this focused case; the retained
comparison uses that candidate's original samples.

Native-relative acceptance remains unmet: paired CPU ratio 2.624
[2.372–2.689] exceeds 1.25 and throughput 0.474 [0.465–0.504] is below 0.90.
This focused result does not replace the eighteen-case full matrix. All 337
package tests pass, including sparse/poisoned hash proofs and hybrid staging;
eighteen focused tests in three suites also pass. Broader native validation and
the final full candidate matrix remain separate requirements.

[All trials](raw/wanted-hash-readiness-single-hybrid/trials.jsonl),
[native ratios](raw/wanted-hash-readiness-single-hybrid/summary.json),
[before/after](raw/wanted-hash-readiness-single-hybrid/before-after.json),
[comparison with the earlier TCP candidate](raw/wanted-hash-readiness-single-hybrid/versus-preceding.json),
[incremental memory](raw/wanted-hash-readiness-single-hybrid/memory-versus-immediate-before.json),
[checks](raw/wanted-hash-readiness-single-hybrid/checks.json) and
[source/environment](raw/wanted-hash-readiness-single-hybrid/environment.json)
retain the evidence. Independent cross-revision comparisons use 10,000 bootstrap
resamples; samples from different revisions are not paired.
