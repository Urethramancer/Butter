# TCP batching candidate comparison — 12 November 2026

The full matrix retained 276 trials: 276 accepted and 0 failed. Memory passes 18/18 cases, throughput 7/18 and CPU 0/18. The unchanged targets are at least 90% native throughput, no more than 1.25× native CPU seconds/GiB and peak RSS within 10% of the original fresh Swift baseline.

Measured source: `36867209c4055c99fef78225e98958caf593e02c`. The preceding full candidate is `8be42c6`; the original baseline is `3a4df88`. 2 cases extended to twelve measured pairs; the others use six. Every case has one declared warm-up per engine. Every result and failure is retained.

Single-file v1 and hybrid seeding throughput remain inconclusive after twelve pairs; their intervals cross 90%. Seven other cases pass throughput and nine clearly miss it. CPU clearly misses its ceiling in all eighteen cases. All eighteen independent before/after CPU intervals lie below one.

## Changes and correctness

The candidate combines available TCP output batches (at most sixteen frames and 256 KiB), an integer count of missing wanted pieces, and bounded 256 KiB verification-read groups. Output never waits for a full batch. Existing queued/reserved byte, message, request, job and cache limits remain unchanged. Rate-limited traffic and µTP keep single-frame writes. Stored-byte SHA-1/Merkle hashes, anchored file opens, before/after file-stamp scans and inner 64 KiB read/cancellation checks remain.

All 327 package tests and the native storage failure/crash suite passed after the read-group change. The TCP batching source separately passed both sanitizers (24 focused tests each), all nine contract/lifecycle/storage/interruption/reference/application suites, and Debug/Release linkage checks. Those earlier integration checks apply to `148d71c`; they are not represented as a complete final-source integration pass. [Focused steps and exact validation records](outbound-batching-results-2026-11-12.md).

## Per-case results

CPU values are Swift seconds/GiB through durable completion: original → snapshot reuse → current. Throughput is verified-transfer MB/s: snapshot reuse → current. Native ratios use paired median bootstrap intervals (10,000 resamples, 95%). The independent cross-commit CPU intervals are retained separately; samples from different commits are not paired. Whole-process peak RSS uses independent intervals and an observed-maximum gate against the original baseline. Sources are explicitly warm, processes and destinations fresh, transport plaintext TCP and request windows the production defaults. [Complete method](README.md).

### Downloads

| Workload / format | Pairs | Swift CPU original → preceding → current | Swift MB/s preceding → current | Throughput ratio [95%] | CPU ratio [95%] | Memory |
| --- | ---: | ---: | ---: | --- | --- | --- |
| single / v1 | 6 | 13.83 → 7.66 → 5.33 | 200.0 → 245.5 | 0.542 [0.518–0.549] | 3.439 [3.381–3.586] | pass |
| single / v2 | 6 | 18.37 → 8.80 → 7.01 | 159.3 → 179.8 | 0.400 [0.395–0.410] | 4.415 [4.290–4.488] | pass |
| single / hybrid | 6 | 17.92 → 8.84 → 6.76 | 157.4 → 185.2 | 0.411 [0.409–0.436] | 3.055 [2.800–3.113] | pass |
| many / v1 | 6 | 36.83 → 14.79 → 11.79 | 84.2 → 96.7 | 0.215 [0.212–0.219] | 7.157 [6.893–7.249] | pass |
| many / v2 | 6 | 42.57 → 16.58 → 13.95 | 74.0 → 83.1 | 0.191 [0.185–0.200] | 8.006 [7.536–8.081] | pass |
| many / hybrid | 6 | 40.26 → 16.41 → 13.72 | 74.7 → 84.0 | 0.185 [0.181–0.188] | 5.841 [5.764–5.991] | pass |
| concurrent / v1 | 6 | 16.10 → 9.31 → 7.56 | 503.9 → 554.6 | 1.162 [1.135–1.187] | 4.053 [3.969–4.091] | pass |
| concurrent / v2 | 6 | 17.60 → 10.06 → 8.12 | 501.0 → 558.4 | 1.183 [1.166–1.204] | 4.208 [4.104–4.274] | pass |
| concurrent / hybrid | 6 | 17.61 → 9.96 → 7.86 | 503.2 → 582.8 | 1.159 [1.091–1.176] | 3.157 [3.098–3.259] | pass |

### Seeding

| Workload / format | Pairs | Swift CPU original → preceding → current | Swift MB/s preceding → current | Throughput ratio [95%] | CPU ratio [95%] | Memory |
| --- | ---: | ---: | ---: | --- | --- | --- |
| single / v1 | 12 | 10.24 → 7.99 → 4.43 | 274.0 → 411.0 | 0.902 [0.896–0.907] | 3.175 [2.836–3.245] | pass |
| single / v2 | 6 | 11.11 → 8.74 → 5.06 | 244.4 → 414.5 | 0.923 [0.911–0.929] | 3.147 [2.799–3.380] | pass |
| single / hybrid | 12 | 11.15 → 8.81 → 5.33 | 243.4 → 393.8 | 0.897 [0.887–0.930] | 3.225 [3.159–3.316] | pass |
| many / v1 | 6 | 14.56 → 13.09 → 8.08 | 176.1 → 210.8 | 0.472 [0.465–0.478] | 4.005 [3.888–4.160] | pass |
| many / v2 | 6 | 13.90 → 14.50 → 9.00 | 143.2 → 197.1 | 0.446 [0.439–0.454] | 4.957 [4.825–5.063] | pass |
| many / hybrid | 6 | 14.56 → 14.08 → 9.28 | 147.6 → 198.8 | 0.439 [0.433–0.451] | 4.796 [4.712–5.011] | pass |
| concurrent / v1 | 6 | 8.90 → 7.48 → 5.73 | 520.0 → 507.7 | 1.067 [1.062–1.068] | 2.853 [2.525–2.989] | pass |
| concurrent / v2 | 6 | 9.84 → 8.33 → 6.22 | 400.0 → 645.6 | 1.365 [1.328–1.401] | 3.046 [2.785–3.211] | pass |
| concurrent / hybrid | 6 | 9.80 → 8.40 → 6.46 | 395.3 → 645.7 | 1.300 [1.268–1.310] | 3.261 [3.031–3.327] | pass |

## Evidence and remaining gaps

Peer diagnostics remain separate from accepted-trial digest/reopen results. Four Swift reset diagnostics occurred only in concurrent downloads (three measured trials and one warm-up); native tested engines emitted 102 completion notices. Exact per-connection timing is not captured, so no narrower cause is claimed. [Diagnostic counts](raw/tcp-batching-full/diagnostics-summary.json) retain native completion notices and any other errors without converting them into hidden retries.

- [Fresh Release profiles for both engines](raw/tcp-batching-profiles/summary.json): eight accepted profile-only trials across v1 download, hybrid download, many-file hybrid download and v1 seeding, excluded from timing acceptance.
- [Every trial](raw/tcp-batching-full/trials.jsonl), [summary](raw/tcp-batching-full/summary.json), [environment and source hashes](raw/tcp-batching-full/environment.json), [fixtures](raw/tcp-batching-full/fixtures.json).
- [Independent before/after CPU intervals](tcp-batching-cpu-comparison-2026-11-12.json) and [comparison CSV](tcp-batching-comparison-2026-11-12.csv).
- [Preceding full matrix](snapshot-reuse-results-2026-11-12.md), [earlier full candidate](results-2026-11-12.md) and [focused steps/profiles](outbound-batching-results-2026-11-12.md).

CPU target remains unmet wherever the per-case interval exceeds the ceiling; crossing intervals remain inconclusive. Hashing, filesystem inspections, allocations, upload admission and scheduling remain measured costs. No combined workload average substitutes for these gates. No tag was created.
