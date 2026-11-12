# Snapshot reuse comparison — 12 November 2026

The new full matrix contains 252 trials: 252 accepted and 0 failed. Memory passes 18/18 cases and throughput passes 4/18. Overall outcomes: target-unmet: 18. The acceptance thresholds are unchanged.

Measured source: `8be42c6e36a077844d1f00e2a383dd4bc349638e`. The previous full candidate is `1309716`; the original pre-batching baseline is public commit `3a4df88`. The original and previous raw records remain intact. 0 cases used twelve measured pairs; the remainder used six. Every case has one warm-up per engine.

## Change and safeguards

A verified-piece operation previously scanned every payload file during invalidation, scanned again for its pre-hash snapshot, then scanned after hashing. It now reuses the initial invalidation snapshot as the pre-hash baseline. Every file is still inspected before and after stored-byte hashing. The same snapshot spans any forced checkpoint before hashing, so a replacement in that interval also fails verification. No cache, request-window, queue or disk-admission limit increased.

The new regression test replaces an unrelated payload with identical bytes during checkpoint publication between the initial scan and hashing. Verification rejects the changed file identity. All 320 package tests, all 47 storage tests under each sanitizer, native crash/ENOSPC/read-only tests, serial contract/lifecycle/reference/bidirectional TCP/MSE/µTP suites and Debug/Release linkage checks passed.

## Full matrix

CPU values are Swift seconds/GiB through durable completion, shown as original baseline → previous candidate → snapshot reuse. Throughput is verified-transfer MB/s. Ratio intervals compare the new Swift engine with libtorrent using paired median bootstrap intervals, 10,000 resamples at 95%. Memory is whole-process peak RSS versus the original baseline, with median uncertainty and observed maximum checks. Sources are warm, processes/destinations fresh, TCP plaintext and production windows unchanged. A crossing interval extends a case to twelve pairs; an unresolved metric remains inconclusive.

### Downloads

| Workload / format | Pairs | Swift CPU original → previous → new | Swift MB/s previous → new | Throughput ratio [95%] | CPU ratio [95%] | Memory |
| --- | ---: | ---: | ---: | --- | --- | --- |
| single / v1 | 6 | 13.83 → 8.24 → 7.66 | 185.7 → 200.0 | 0.451 [0.438–0.471] | 4.616 [4.546–4.750] | pass |
| single / v2 | 6 | 18.37 → 9.66 → 8.80 | 146.3 → 159.3 | 0.360 [0.351–0.366] | 5.304 [5.211–5.505] | pass |
| single / hybrid | 6 | 17.92 → 8.71 → 8.84 | 160.4 → 157.4 | 0.360 [0.352–0.372] | 3.745 [3.522–3.820] | pass |
| many / v1 | 6 | 36.83 → 15.45 → 14.79 | 80.0 → 84.2 | 0.188 [0.184–0.195] | 8.293 [8.139–8.505] | pass |
| many / v2 | 6 | 42.57 → 16.78 → 16.58 | 72.5 → 74.0 | 0.172 [0.168–0.174] | 8.898 [8.745–9.187] | pass |
| many / hybrid | 6 | 40.26 → 16.87 → 16.41 | 72.1 → 74.7 | 0.166 [0.163–0.171] | 6.653 [6.470–6.841] | pass |
| concurrent / v1 | 6 | 16.10 → 9.49 → 9.31 | 512.0 → 503.9 | 1.057 [0.987–1.085] | 4.907 [4.801–5.035] | pass |
| concurrent / v2 | 6 | 17.60 → 10.29 → 10.06 | 474.4 → 501.0 | 1.054 [1.005–1.065] | 5.300 [5.101–5.395] | pass |
| concurrent / hybrid | 6 | 17.61 → 10.15 → 9.96 | 490.3 → 503.2 | 1.002 [0.987–1.031] | 4.009 [3.895–4.137] | pass |

### Seeding

| Workload / format | Pairs | Swift CPU original → previous → new | Swift MB/s previous → new | Throughput ratio [95%] | CPU ratio [95%] | Memory |
| --- | ---: | ---: | ---: | --- | --- | --- |
| single / v1 | 6 | 10.24 → 8.33 → 7.99 | 265.8 → 274.0 | 0.615 [0.611–0.626] | 4.657 [4.507–4.765] | pass |
| single / v2 | 6 | 11.11 → 8.73 → 8.74 | 244.4 → 244.4 | 0.550 [0.547–0.556] | 5.003 [4.944–5.290] | pass |
| single / hybrid | 6 | 11.15 → 8.84 → 8.81 | 242.5 → 243.4 | 0.550 [0.547–0.554] | 4.980 [4.887–5.083] | pass |
| many / v1 | 6 | 14.56 → 14.93 → 13.09 | 139.6 → 176.1 | 0.399 [0.394–0.403] | 6.396 [6.307–6.705] | pass |
| many / v2 | 6 | 13.90 → 16.00 → 14.50 | 117.8 → 143.2 | 0.337 [0.327–0.345] | 7.293 [6.945–7.921] | pass |
| many / hybrid | 6 | 14.56 → 16.00 → 14.08 | 121.4 → 147.6 | 0.326 [0.307–0.340] | 7.368 [7.084–7.880] | pass |
| concurrent / v1 | 6 | 8.90 → 7.46 → 7.48 | 532.5 → 520.0 | 1.075 [1.065–1.080] | 3.930 [3.771–4.122] | pass |
| concurrent / v2 | 6 | 9.84 → 8.45 → 8.33 | 407.5 → 400.0 | 0.845 [0.831–0.865] | 4.168 [3.753–4.313] | pass |
| concurrent / hybrid | 6 | 9.80 → 8.39 → 8.40 | 405.1 → 395.3 | 0.800 [0.784–0.816] | 4.187 [3.134–4.395] | pass |

## Evidence and limits

- [New full summary](raw/stamp-reuse-full/summary.json), [every trial](raw/stamp-reuse-full/trials.jsonl), [environment](raw/stamp-reuse-full/environment.json) and [fixtures](raw/stamp-reuse-full/fixtures.json).
- [Independent before/after CPU intervals](snapshot-reuse-cpu-comparison-2026-11-12.json) and [comparison CSV](snapshot-reuse-comparison-2026-11-12.csv).
- [Causal many-file seeding profile](raw/many-seed-investigation/summary.json), [focused 42-trial experiment](raw/stamp-snapshot-reuse/summary.json), [new validation history](raw/snapshot-reuse-validation/results.jsonl) and [package/sanitizer/controller evidence](raw/snapshot-reuse-validation/checks.json).
- [Previous full results](results-2026-11-12.md) and [complete method](README.md).

CPU parity remains open. Full file-stamp inspection, per-block upload scheduling/admission and Network.framework sends remain measured costs. Stored-byte hashes, ownership safeguards and bounded resources remain in place. Peer diagnostic strings are retained separately from accepted-trial digest/recovery outcomes. No tag was created.
