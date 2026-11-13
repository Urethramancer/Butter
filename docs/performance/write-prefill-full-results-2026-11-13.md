# Write-time refill: full matrix

Candidate `cd68e8f`, measured at `6eed864`: all 252 trials validate, with zero
failures across eighteen cases. Throughput passes 9/18, CPU 0/18 and original
Swift-baseline memory 18/18. CPU/native paired medians range from 1.547 to
3.966. CPU parity remains unmet; there is no combined workload score.

Each case uses one declared warm-up per engine and six balanced, reproducibly
shuffled measured pairs, fresh processes/destinations and explicitly warm sources.
No acceptance interval crosses a threshold, so none extends to twelve pairs.
Fixtures are one 1 GiB file, 128 equal files totalling 1 GiB, and four simultaneous
256 MiB files, all with 256 KiB pieces and v1/v2/hybrid metadata. Fixture hashes
match the preceding full matrix. Both engines use the same pinned native
counterpart. Independent streaming digests and saved-state reopening validate
every trial. Seeding finishes when the receiver verifies the payload.

Ratios are Swift/native paired medians with 95% bootstrap intervals. Verified
and durable throughput remain separate; CPU is seconds/GiB through durable
completion. Whole-process wall/CPU/RSS and counterpart metrics remain in raw
trials. Native persistence differences and equivalent payload/state fsync
barriers remain labelled in the raw environment. No cold-cache claim is made.

| Workload | Format | Direction | Verified throughput ratio [95%] | Durable throughput ratio [95%] | CPU ratio [95%] |
| --- | --- | --- | --- | --- | --- |
| single | v1 | download | 0.713 [0.697–0.736] | 0.827 [0.776–0.875] | 2.304 [2.228–2.356] |
| single | v1 | seed | 1.288 [1.275–1.299] | 1.287 [1.275–1.290] | 1.574 [1.458–1.651] |
| single | v2 | download | 0.714 [0.687–0.739] | 0.789 [0.765–0.828] | 2.324 [2.281–2.389] |
| single | v2 | seed | 1.252 [1.189–1.317] | 1.256 [1.193–1.322] | 1.582 [1.552–1.636] |
| single | hybrid | download | 0.619 [0.608–0.645] | 0.711 [0.655–0.792] | 1.949 [1.808–2.039] |
| single | hybrid | seed | 1.395 [1.318–1.448] | 1.399 [1.323–1.452] | 1.810 [1.735–1.867] |
| many | v1 | download | 0.342 [0.332–0.350] | 0.343 [0.332–0.352] | 3.930 [3.880–3.980] |
| many | v1 | seed | 0.874 [0.869–0.899] | 0.874 [0.870–0.900] | 2.145 [2.096–2.318] |
| many | v2 | download | 0.335 [0.326–0.340] | 0.338 [0.331–0.342] | 3.966 [3.837–4.059] |
| many | v2 | seed | 0.818 [0.793–0.842] | 0.821 [0.795–0.846] | 2.195 [2.103–2.302] |
| many | hybrid | download | 0.307 [0.296–0.309] | 0.309 [0.298–0.311] | 3.251 [3.202–3.315] |
| many | hybrid | seed | 0.629 [0.615–0.646] | 0.632 [0.622–0.649] | 2.404 [2.306–2.514] |
| concurrent | v1 | download | 1.304 [1.252–1.329] | 1.560 [1.443–1.593] | 2.798 [2.729–2.851] |
| concurrent | v1 | seed | 1.707 [1.683–1.859] | 1.705 [1.678–1.858] | 1.547 [1.393–1.580] |
| concurrent | v2 | download | 1.231 [1.193–1.270] | 1.462 [1.378–1.549] | 2.767 [2.651–2.822] |
| concurrent | v2 | seed | 1.876 [1.850–1.943] | 1.888 [1.860–1.952] | 1.676 [1.581–1.731] |
| concurrent | hybrid | download | 1.247 [1.160–1.336] | 1.468 [1.309–1.660] | 2.219 [2.072–2.321] |
| concurrent | hybrid | seed | 1.636 [1.575–1.714] | 1.645 [1.585–1.714] | 1.830 [1.723–1.923] |

Single-file v1 medians are 320.5 versus 450.5 MB/s and 4.043 versus 1.752 CPU
seconds/GiB. Many-file hybrid reaches 139.1 versus 455.9 MB/s, using 8.379
versus 2.572 CPU seconds/GiB. Many-file downloads remain the largest gap:
30.7–34.2% native throughput and 3.25–3.97 times CPU.

The [preceding full matrix](wire-raw-full-results-2026-11-13.md) had many-file
download ratios of 23.6–25.5% throughput and 4.32–5.19 times CPU. These are
separate runs, not causal source estimates. In particular, seeding differences
must not be attributed to this download-only change. The [three balanced source
comparisons](write-prefill-results-2026-11-13.md) separately establish CPU and
throughput gains. Their many/concurrent RSS intervals remain inconclusive, so
absence of source costs is unproven despite passing the baseline memory target.
Earlier refill gains are not compounded into a claimed aggregate improvement.

The production request window remains eight; all queue/disk limits, caches,
stored-byte hashes, filesystem ownership checks and cancellation remain.
All 94 production-source hashes match the measured candidate. Verification
passes 357 package tests, nine focused tests under each sanitizer, 466 native
interoperability PASS records, 52 native storage checks, application contract
and lifecycle suites, Debug/Release builds, linkage/licences and unchanged repeat
build. The historical µTP timeout passes unchanged deadlines in the full native
run, but its original cause remains unexplained. User Xcode edits are preserved.

[Absolute per-case medians and intervals](write-prefill-full-comparison-2026-11-13.csv),
[complete summary](write-prefill-full-summary-2026-11-13.json), and
[source checks, raw hashes and acceptance totals](write-prefill-full-evidence-2026-11-13.json)
retain the result. Raw phases, environment and all trials remain in
`.build/benchmarks/write-prefill-full`; successful disposable payloads/binaries
are removed. [Fresh profiles of both engines](write-prefill-profiles-2026-11-13.md)
cover all four prescribed workloads and still identify filesystem work as the
largest gap. No release, parity or cost-free claim is made.
