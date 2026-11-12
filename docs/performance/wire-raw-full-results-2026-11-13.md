# Revised upload buffers: full matrix

Candidate `4806204`, measured at `58960f2`: all 252 trials validate, with zero
failures across eighteen cases. Throughput passes 9/18, CPU 0/18 and original
Swift-baseline memory 18/18. CPU parity remains unmet: paired CPU/native medians
range from 1.532 to 5.192. There is no combined workload performance score.

Each case uses one declared warm-up per engine and six balanced, reproducibly
shuffled measured pairs, fresh processes/destinations and explicitly warm sources.
No acceptance interval crosses a threshold, so no case extends beyond six pairs.
Fixtures are 1 GiB single-file, 128 equal files totalling 1 GiB, and four
simultaneous 256 MiB files; all use 256 KiB pieces and v1/v2/hybrid metadata.
Both tested engines use the same pinned native counterpart. Production request
windows and all verification, ownership, cancellation and queue limits remain.
Independent streaming payload digests and saved-state reopening validate every
trial. Seeding completes only when the receiving peer verifies the payload.

The table reports candidate/native paired medians with 95% bootstrap intervals.
Verified throughput and throughput through durable completion remain separate;
CPU is seconds/GiB through durable completion. Native persistence differences
and equivalent payload/state fsync barriers remain labelled in the raw environment.
Whole-process phase wall/CPU, peak RSS and counterpart metrics remain in raw trials.

| Workload | Format | Direction | Verified throughput ratio [95%] | Durable throughput ratio [95%] | CPU ratio [95%] |
| --- | --- | --- | --- | --- | --- |
| single | v1 | download | 0.563 [0.513–0.605] | 0.643 [0.596–0.748] | 2.858 [2.730–2.928] |
| single | v1 | seed | 1.290 [1.264–1.321] | 1.290 [1.264–1.321] | 1.532 [1.485–1.594] |
| single | v2 | download | 0.573 [0.562–0.584] | 0.644 [0.618–0.673] | 2.844 [2.793–2.890] |
| single | v2 | seed | 1.304 [1.244–1.326] | 1.308 [1.246–1.330] | 1.679 [1.520–1.790] |
| single | hybrid | download | 0.518 [0.507–0.533] | 0.563 [0.558–0.611] | 2.241 [2.077–2.293] |
| single | hybrid | seed | 1.437 [1.408–1.463] | 1.441 [1.413–1.467] | 1.831 [1.767–1.952] |
| many | v1 | download | 0.255 [0.251–0.256] | 0.256 [0.251–0.257] | 5.189 [5.118–5.236] |
| many | v1 | seed | 0.885 [0.760–0.893] | 0.886 [0.761–0.893] | 2.175 [2.066–2.236] |
| many | v2 | download | 0.248 [0.241–0.251] | 0.251 [0.243–0.255] | 5.192 [5.116–5.436] |
| many | v2 | seed | 0.635 [0.625–0.675] | 0.638 [0.628–0.677] | 2.200 [2.137–2.300] |
| many | hybrid | download | 0.236 [0.217–0.243] | 0.237 [0.218–0.245] | 4.321 [4.027–4.662] |
| many | hybrid | seed | 0.647 [0.636–0.699] | 0.649 [0.639–0.703] | 2.593 [2.387–2.826] |
| concurrent | v1 | download | 1.102 [1.044–1.168] | 1.373 [1.337–1.492] | 3.381 [3.324–3.678] |
| concurrent | v1 | seed | 1.742 [1.712–1.777] | 1.748 [1.713–1.768] | 1.561 [1.409–1.615] |
| concurrent | v2 | download | 1.178 [1.154–1.226] | 1.385 [1.346–1.454] | 3.348 [3.286–3.513] |
| concurrent | v2 | seed | 1.883 [1.862–1.912] | 1.895 [1.869–1.932] | 1.650 [1.545–1.671] |
| concurrent | hybrid | download | 1.105 [1.064–1.201] | 1.277 [1.178–1.292] | 2.843 [2.617–3.094] |
| concurrent | hybrid | seed | 1.627 [1.606–1.645] | 1.619 [1.601–1.638] | 1.811 [1.685–1.899] |

Many-file downloads are the largest gap: 23.6–25.5% of native verified
throughput and 4.32–5.19 times CPU. Current profiles identify repeated layout
inspection, file opening and write dispatch as major costs; this is the next
area to investigate while preserving filesystem safeguards and stored-byte hashes.

The seven balanced source comparisons separately establish 2.3–4.3% seeding
CPU reductions, with single/concurrent hybrid RSS 4.3%/7.7% lower. Several
source throughput/download intervals remain wide and inconclusive; this matrix
does not prove their absence of cost. It compares with native rather than the
preceding source. The original wire-buffer form's concurrent-download RSS cost
remains disqualifying, and historical 31-request/owned-buffer matrices describe
different candidates.

The revised source passes 354 package tests, fifteen focused tests under each
sanitizer, Release build, and the unfiltered native suite (466 PASS records).
The earlier full-suite µTP timeout remains unexplained despite passing in the
current full sequence with unchanged deadlines. No release or parity claim is made.

[Per-case absolute medians and intervals](wire-raw-full-comparison-2026-11-13.csv),
[complete summary](wire-raw-full-summary-2026-11-13.json), and
[evidence, source checks and raw hashes](wire-raw-full-evidence-2026-11-13.json)
retain the result. Raw environment, fixtures, all phase/resource measurements
and every trial remain in `.build/benchmarks/wire-raw-full`. Successful temporary
payloads/binaries are removed by the harness. Earlier failures remain in their
original diagnostic directories and reports.
