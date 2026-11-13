# Grouped upload publication: full matrix

Candidate `afad9d1`, measured at `49040fa`: all 264 trials validate with zero
failures across eighteen cases. Throughput passes nine cases, fails eight and
remains inconclusive in one. CPU passes 0/18; original Swift-baseline memory
passes 18/18. CPU/native paired medians range from 1.435 to 3.982. CPU parity
remains unmet; no combined workload score is reported.

Each case uses one declared warm-up per engine and six balanced, reproducibly
shuffled measured pairs. Many-file v1 seeding extends to twelve pairs because
its throughput interval crosses 0.90, retaining every original sample. Its
final verified-throughput interval is 0.765939–0.900011, still crossing the
threshold; durable throughput is also inconclusive. No further extension or
retry is performed. The other seventeen cases remain at six pairs.

Fixtures are one 1 GiB file, 128 equal files totalling 1 GiB and four simultaneous
256 MiB files, with 256 KiB pieces and v1/v2/hybrid metadata. Fixture hashes
match the preceding full matrix. Both engines use the same pinned libtorrent
counterpart. Fresh processes/destinations and explicitly warm sources are used;
no cold-cache claim is made. Independent streaming digests and saved-state
reopening validate every trial. Upload trials end when the receiver verifies
the payload.

Ratios are Swift/native paired medians with 95% bootstrap intervals. Verified
and durable throughput remain separate; CPU is seconds/GiB through durable
completion. Raw records retain setup, transfer, persistence, shutdown,
whole-process wall/user/system/RSS and counterpart measurements. Native
persistence placement differences and equivalent payload/state fsync barriers
remain labelled. Measured Swift peak RSS is 15,040,512–46,940,160 bytes.
Passing the original memory baseline does not prove absence of a source cost.

| Workload | Format | Direction | Pairs | Verified throughput ratio [95%] | Durable throughput ratio [95%] | CPU ratio [95%] |
| --- | --- | --- | ---: | --- | --- | --- |
| single | v1 | download | 6 | 0.737 [0.693–0.745] | 0.862 [0.817–0.950] | 1.951 [1.933–1.979] |
| single | v1 | seed | 6 | 1.289 [1.204–1.372] | 1.289 [1.204–1.372] | 1.539 [1.479–1.667] |
| single | v2 | download | 6 | 0.696 [0.665–0.714] | 0.788 [0.762–0.832] | 2.082 [2.052–2.153] |
| single | v2 | seed | 6 | 1.261 [1.218–1.332] | 1.264 [1.221–1.336] | 1.526 [1.434–1.544] |
| single | hybrid | download | 6 | 0.604 [0.595–0.640] | 0.722 [0.660–0.748] | 1.709 [1.627–1.927] |
| single | hybrid | seed | 6 | 1.407 [1.343–1.496] | 1.410 [1.346–1.503] | 1.706 [1.682–1.842] |
| many | v1 | download | 6 | 0.319 [0.311–0.326] | 0.321 [0.311–0.328] | 3.982 [3.861–4.036] |
| many | v1 | seed | 12 | 0.884 [0.766–0.900] | 0.884 [0.766–0.900] | 2.417 [2.197–2.870] |
| many | v2 | download | 6 | 0.347 [0.340–0.354] | 0.351 [0.343–0.358] | 3.735 [3.513–3.890] |
| many | v2 | seed | 6 | 0.789 [0.783–0.800] | 0.792 [0.786–0.804] | 2.022 [1.959–2.187] |
| many | hybrid | download | 6 | 0.305 [0.302–0.308] | 0.306 [0.303–0.309] | 2.968 [2.919–2.997] |
| many | hybrid | seed | 6 | 0.632 [0.625–0.640] | 0.634 [0.628–0.642] | 2.347 [2.237–2.516] |
| concurrent | v1 | download | 6 | 1.316 [1.292–1.336] | 1.610 [1.573–1.623] | 2.277 [2.232–2.325] |
| concurrent | v1 | seed | 6 | 1.716 [1.702–1.721] | 1.711 [1.702–1.717] | 1.435 [1.370–1.562] |
| concurrent | v2 | download | 6 | 1.349 [1.323–1.373] | 1.614 [1.583–1.657] | 2.258 [2.223–2.281] |
| concurrent | v2 | seed | 6 | 1.882 [1.874–1.912] | 1.888 [1.880–1.926] | 1.509 [1.431–1.625] |
| concurrent | hybrid | download | 6 | 1.298 [1.201–1.383] | 1.584 [1.464–1.665] | 1.857 [1.800–1.878] |
| concurrent | hybrid | seed | 6 | 1.607 [1.543–1.654] | 1.614 [1.546–1.656] | 1.789 [1.621–1.893] |

Single-file v1 seeding medians are 570.2 versus 452.5 MB/s and 2.381 versus
1.583 CPU seconds/GiB. Concurrent v1 seeding has the smallest CPU ratio at
1.435 [1.370–1.562], still above 1.25. Many-file hybrid download reaches 138.8
versus 455.0 MB/s and 8.129 versus 2.742 CPU seconds/GiB. Many-file downloads
remain the largest gap: 30.5–34.7% native throughput and 2.97–3.98 times CPU.

The [preceding full matrix](request-burst-revised-full-results-2026-11-13.md) is
an independent historical run, not a causal source comparison. Both ends of
the CPU-ratio range move, from 1.51–3.84 to 1.43–3.98; this is not a combined
improvement score. Some absolute download CPU metrics worsen: many-file v1 is
7.963 versus 7.498 seconds/GiB (6.2% higher). Native CPU also shifts, and this
specific source/workload difference remains to be investigated. Many-file v1
seeding's native CPU falls from 1.971 to 1.697 while Swift falls from 4.167 to
4.079; its worse native ratio does not establish a Swift source regression.
All results remain rather than being selected for favourable comparisons.

The [six balanced source comparisons](upload-publication-results-2026-11-13.md)
separately establish seeding CPU savings of 3.4–4.7%, without an established
source regression in the three focused download cases. Several throughput/RSS
intervals remain inconclusive, including a wide single-file seeding RSS interval.
No absence-of-cost claim follows from those intervals or this full matrix.

The request window remains eight; all queue/disk limits, caches, stored-byte
hashes, filesystem ownership safeguards and cancellation remain. All 94
production-source hashes and the package match the measured candidate.
Correctness passes 363 package tests, 20 focused tests under each sanitizer,
466 native interoperability PASS records including encryption/µTP, 52 native
storage checks, application contracts/lifecycle and Debug/Release builds,
linkage/licences and unchanged repeat build. User Xcode edits remain untouched.
[Validation evidence](upload-publication-validation-2026-11-13.json) retains
counts and log hashes. Fresh profiles of the final candidate remain to be
captured before choosing another CPU change.

[Absolute medians and intervals](upload-publication-full-comparison-2026-11-13.csv),
[complete summary](upload-publication-full-summary-2026-11-13.json) and
[source checks/raw hashes](upload-publication-full-evidence-2026-11-13.json)
retain evidence. Raw phases, environment and every trial remain under
`.build/benchmarks/upload-publication-full`; disposable payloads/binaries and
successful per-trial routine logs are removed by the wrapper. No release,
parity or cost-free claim is made.
