# Full owned-buffer comparison — 12 November 2026

All **276 trials validate, with zero failures**. Memory passes **18/18** cases,
verified throughput **11/18**, and CPU **0/18**. CPU parity remains unmet.
The unchanged requirements are throughput ≥0.90× native, CPU seconds/GiB through
durable completion ≤1.25× native, and whole-process peak RSS ≤1.10× the original
fresh Swift baseline (`3a4df88`). Peak RSS across all Swift trials is 15.1–46.1 MiB.

Production source is `b328472`, measured at `14b72b3`; all recorded Swift source
hashes match. The preceding complete matrix is `5b9ef12` (9 throughput passes,
18 memory passes, no CPU passes). Grouped upload workers and owned-buffer returns
are both included here; this full-run comparison cannot isolate their effects.
Separate balanced source comparisons establish the focused improvements.

Each case has one warm-up per engine and six balanced, reproducibly shuffled
measured pairs. Many-file v1/v2 seeding extend to twelve because their initial
intervals cross a throughput threshold; all original samples remain. Both finish
with throughput intervals above 0.90, while CPU remains above 1.25. No final
interval crosses a threshold. Fixtures are deterministic, 256 KiB pieces, warm
source files, fresh processes/destinations, plaintext TCP and production windows.
Both engines use the same pinned libtorrent counterpart. The workspace temporary
root is on the same APFS volume and recorded in the environment. No other builds,
tests, profiles or source edits run alongside timing.

Independent streaming payload digests and saved-state reopening pass for every
trial. Phase/durability accounting, native persistence differences, request
settings, whole-process CPU/RSS, compiler/machine data, fixture hashes and
counterpart errors remain in the local raw records. Encryption and µTP performance
are outside this matrix; the recorded native rerun passes 466 correctness checks.
All 347 package tests and 110 focused tests under each sanitizer pass. The earlier
native run's missing temporary artefacts remain unresolved, as described in the
[focused result](piece-buffer-results-2026-11-12.md).

CPU and MB/s columns give Swift medians before → current. Paired Swift/native
ratios show 95% median percentile bootstrap intervals (10,000 resamples). Peak RSS
is the observed whole-process maximum, including warm-ups. Cross-run before/after
intervals are independent, recorded separately in the machine-readable result.
No workload averages or causal claims are inferred from the historical comparison.

## Downloads

| Workload / format | Pairs | CPU before → current | MB/s before → current | Throughput/native [95%] | CPU/native [95%] | Peak MiB |
| --- | ---: | ---: | ---: | --- | --- | ---: |
| single / v1 | 6 | 3.22 → 3.27 | 388.4 → 390.6 | 0.873 [0.835–0.900] | 2.087 [2.071–2.153] | 15.4 |
| single / v2 | 6 | 3.28 → 3.28 | 378.5 → 383.4 | 0.855 [0.851–0.863] | 2.061 [2.048–2.084] | 17.0 |
| single / hybrid | 6 | 3.49 → 3.46 | 348.6 → 352.2 | 0.794 [0.785–0.809] | 1.561 [1.500–1.591] | 17.1 |
| many / v1 | 6 | 6.37 → 6.03 | 181.2 → 189.1 | 0.420 [0.415–0.424] | 3.673 [3.641–3.724] | 15.7 |
| many / v2 | 6 | 6.25 → 6.12 | 181.8 → 186.1 | 0.421 [0.415–0.424] | 3.507 [3.483–3.541] | 16.9 |
| many / hybrid | 6 | 6.52 → 6.61 | 173.0 → 171.6 | 0.383 [0.380–0.384] | 2.797 [2.768–2.810] | 18.5 |
| concurrent / v1 | 6 | 6.03 → 6.00 | 767.1 → 763.2 | 1.594 [1.532–1.641] | 3.293 [3.267–3.322] | 22.8 |
| concurrent / v2 | 6 | 6.12 → 6.16 | 754.2 → 767.2 | 1.622 [1.603–1.643] | 3.273 [3.247–3.319] | 24.9 |
| concurrent / hybrid | 6 | 5.50 → 5.50 | 824.8 → 828.6 | 1.576 [1.480–1.623] | 2.345 [2.230–2.393] | 25.1 |

## Seeding

| Workload / format | Pairs | CPU before → current | MB/s before → current | Throughput/native [95%] | CPU/native [95%] | Peak MiB |
| --- | ---: | ---: | ---: | --- | --- | ---: |
| single / v1 | 6 | 3.13 → 2.54 | 529.3 → 622.9 | 1.387 [1.333–1.412] | 1.430 [1.396–1.477] | 26.7 |
| single / v2 | 6 | 3.35 → 2.61 | 524.1 → 631.9 | 1.413 [1.401–1.458] | 1.497 [1.444–1.524] | 28.5 |
| single / hybrid | 6 | 3.77 → 2.94 | 608.5 → 679.5 | 1.530 [1.528–1.595] | 1.724 [1.644–1.740] | 25.5 |
| many / v1 | 12 | 5.30 → 3.95 | 298.7 → 410.8 | 0.918 [0.908–0.927] | 2.054 [2.010–2.097] | 24.2 |
| many / v2 | 12 | 4.97 → 3.94 | 384.3 → 413.7 | 0.936 [0.931–0.947] | 2.052 [2.033–2.120] | 25.4 |
| many / hybrid | 6 | 5.53 → 4.55 | 281.6 → 296.1 | 0.659 [0.653–0.666] | 2.395 [2.337–2.483] | 25.8 |
| concurrent / v1 | 6 | 3.41 → 2.76 | 748.5 → 824.0 | 1.727 [1.698–1.738] | 1.381 [1.318–1.454] | 46.1 |
| concurrent / v2 | 6 | 3.58 → 2.83 | 786.8 → 927.2 | 1.948 [1.846–1.958] | 1.428 [1.312–1.540] | 46.0 |
| concurrent / hybrid | 6 | 4.05 → 3.50 | 812.1 → 835.4 | 1.657 [1.649–1.704] | 1.795 [1.481–1.832] | 45.5 |

## Remaining gap and evidence

Independent historical CPU comparisons: 6 inconclusive, 12 improve. These include runtime/native variation, so use the
source comparisons for attribution. The full preceding seeding regressions remain
recorded; this run does not establish their sequence/runtime cause.

Concurrent v1 seeding is closest at 1.381 [1.318–1.454] CPU/native. Many-file
downloads remain 2.797–3.673× native CPU and 0.383–0.421× throughput. All three
single-file downloads also miss throughput. Fresh profiles are needed before
choosing the next change; existing profiles point to full-layout inspection,
file opening, hashing, copying and scheduling. No safeguards or targets are relaxed.

[Machine-readable results](piece-buffer-full-summary-2026-11-12.json) include every
case, paired intervals, historical independent comparisons, counterpart CPU medians
and raw-artifact hashes. Full raw records remain locally in
`.build/benchmarks/piece-buffer-full`; their roughly 2 MiB trial stream is not
copied into repository documentation. No failed trial or retry is omitted.

The candidate also passes both engine contracts, application lifecycle, 51 native
storage checks (including real volume failures and killed-child recovery), five
reference disk checks, nine reference interruption checks, unsigned Debug/Release
app builds, linkage/licence checks and an unchanged repeat build. The harness
passes 16 tests with 105 assertions. Temporary fixtures/module caches use workspace
locations; native storage package tests are serial. Numeric EngineOperations and
user Xcode edits are unchanged. [Validation results](piece-buffer-validation-2026-11-12.json)
record outcomes and artefact hashes, including the earlier unsuccessful native
run with missing temporary paths. Performance acceptance remains unmet.
