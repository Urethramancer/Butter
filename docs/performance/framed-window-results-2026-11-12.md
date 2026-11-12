# Corrected transfer candidate comparison — 12 November 2026

The full matrix retained 252 trials: 252 accepted and 0 failed. Memory passes 18/18 cases, throughput 9/18 and CPU 0/18. The unchanged targets are at least 90% native throughput, no more than 1.25× native CPU seconds/GiB and peak RSS within 10% of the original fresh Swift baseline.

Measured source: `3f1c7cce250752ecc4b0df6edbf01b7773cfbb30`. The preceding full candidate is `3686720`; the original baseline is `3a4df88`. 0 cases extended to twelve measured pairs; the others use six. Production source is `1931e70`; measured revision includes subsequent evidence. Every case has one declared warm-up per engine. Every result and failure is retained.

Against the preceding full candidate, fourteen independent CPU intervals are
below one. Single-file hybrid download uses 2.8% more CPU, ratio 1.028
[1.001–1.074]; three other comparisons remain inconclusive. These outcomes
remain separate. All eighteen cases still clearly miss the native CPU ceiling.
The nine throughput passes are the three concurrent downloads and six
single-file/concurrent seeding cases. The other nine clearly miss throughput;
there is no unresolved acceptance interval requiring twelve pairs in this run.

## Changes and correctness

The candidate includes scan-local parent validation reuse, metadata-defined hashing, available TCP input batching, disk admission only on verified cache loads, a framed-capacity upload advertisement and cancellation cleanup for every remaining ready piece. The download pipeline remains eight; advertised reqq is corrected from 32 to 31, with the same 32 per-peer admission cap, 64 transfer jobs and 512 KiB output budget. Hashing, ownership checks and deadlines remain. Rejected bulk inspection and available-read batching remain reverted.

All 334 package tests and 41 focused cases under each sanitizer passed for production source `1931e70`. All nine fresh native contract, lifecycle, storage/failure, interruption, reference and Debug/Release application/linkage suites passed. The initial failed preflight and deterministic cancellation reproduction are preserved separately. The measured revision differs only in documentation from this verified source. [Source-specific evidence](advertised-window-results-2026-11-12.md).

## Per-case results

CPU values are Swift seconds/GiB through durable completion: original → TCP batching → current. Throughput is verified-transfer MB/s: TCP batching → current. Native ratios use paired median bootstrap intervals (10,000 resamples, 95%). The independent cross-commit CPU intervals are retained separately; samples from different commits are not paired. Whole-process peak RSS uses independent intervals and an observed-maximum gate against the original baseline. Sources are explicitly warm, processes and destinations fresh, transport plaintext TCP and request windows the production defaults. [Complete method](README.md).

### Downloads

| Workload / format | Pairs | Swift CPU original → preceding → current | Swift MB/s preceding → current | Throughput ratio [95%] | CPU ratio [95%] | Memory / peak MiB |
| --- | ---: | ---: | ---: | --- | --- | --- |
| single / v1 | 6 | 13.83 → 5.33 → 5.07 | 245.5 → 255.5 | 0.567 [0.546–0.583] | 3.194 [3.099–3.234] | pass / 15.9 |
| single / v2 | 6 | 18.37 → 7.01 → 6.46 | 179.8 → 199.1 | 0.446 [0.431–0.453] | 3.915 [3.880–4.007] | pass / 16.2 |
| single / hybrid | 6 | 17.92 → 6.76 → 6.95 | 185.2 → 182.4 | 0.422 [0.388–0.429] | 2.816 [2.778–3.087] | pass / 16.8 |
| many / v1 | 6 | 36.83 → 11.79 → 11.19 | 96.7 → 104.3 | 0.234 [0.228–0.239] | 6.429 [6.218–6.538] | pass / 15.0 |
| many / v2 | 6 | 42.57 → 13.95 → 12.08 | 83.1 → 96.8 | 0.230 [0.226–0.245] | 6.649 [6.565–6.802] | pass / 17.6 |
| many / hybrid | 6 | 40.26 → 13.72 → 12.41 | 84.0 → 94.0 | 0.208 [0.195–0.213] | 5.108 [4.948–5.435] | pass / 16.8 |
| concurrent / v1 | 6 | 16.10 → 7.56 → 7.42 | 554.6 → 585.8 | 1.219 [1.173–1.270] | 3.848 [3.704–3.929] | pass / 21.4 |
| concurrent / v2 | 6 | 17.60 → 8.12 → 8.26 | 558.4 → 486.5 | 1.045 [0.958–1.125] | 3.955 [3.926–4.105] | pass / 22.7 |
| concurrent / hybrid | 6 | 17.61 → 7.86 → 7.94 | 582.8 → 549.4 | 1.130 [1.055–1.149] | 2.934 [2.838–3.113] | pass / 23.1 |

### Seeding

| Workload / format | Pairs | Swift CPU original → preceding → current | Swift MB/s preceding → current | Throughput ratio [95%] | CPU ratio [95%] | Memory / peak MiB |
| --- | ---: | ---: | ---: | --- | --- | --- |
| single / v1 | 6 | 10.24 → 4.43 → 3.29 | 411.0 → 515.2 | 1.150 [1.142–1.158] | 1.919 [1.889–2.017] | pass / 23.5 |
| single / v2 | 6 | 11.11 → 5.06 → 3.41 | 414.5 → 518.9 | 1.161 [1.156–1.174] | 1.983 [1.964–2.101] | pass / 26.9 |
| single / hybrid | 6 | 11.15 → 5.33 → 3.84 | 393.8 → 608.4 | 1.353 [1.344–1.383] | 2.251 [2.194–2.284] | pass / 25.7 |
| many / v1 | 6 | 14.56 → 8.08 → 5.05 | 210.8 → 390.5 | 0.872 [0.862–0.877] | 2.544 [2.460–2.679] | pass / 22.8 |
| many / v2 | 6 | 13.90 → 9.00 → 5.17 | 197.1 → 290.6 | 0.699 [0.684–0.829] | 2.750 [2.622–3.158] | pass / 25.0 |
| many / hybrid | 6 | 14.56 → 9.28 → 5.56 | 198.8 → 290.2 | 0.646 [0.628–0.671] | 2.894 [2.729–3.090] | pass / 25.8 |
| concurrent / v1 | 6 | 8.90 → 5.73 → 3.56 | 507.7 → 793.1 | 1.662 [1.354–1.877] | 1.707 [1.599–1.802] | pass / 48.0 |
| concurrent / v2 | 6 | 9.84 → 6.22 → 4.03 | 645.6 → 983.7 | 2.110 [1.715–2.280] | 1.660 [1.476–1.833] | pass / 43.2 |
| concurrent / hybrid | 6 | 9.80 → 6.46 → 4.10 | 645.7 → 834.6 | 1.644 [1.619–1.665] | 2.026 [1.820–2.179] | pass / 45.5 |

## Evidence and remaining gaps

- [Every trial](raw/framed-window-full/trials.jsonl), [summary](raw/framed-window-full/summary.json), [environment and source hashes](raw/framed-window-full/environment.json), [fixtures](raw/framed-window-full/fixtures.json).
- [Independent before/after CPU intervals](framed-window-cpu-comparison-2026-11-12.json) and [comparison CSV](framed-window-comparison-2026-11-12.csv).
- [Setup, transfer, persistence, shutdown and whole-process accounting for both engines and counterparts](raw/framed-window-full/phase-accounting.json), [driver diagnostics and their phase records](raw/framed-window-full/diagnostics.json).
- [Preceding full matrix](tcp-batching-results-2026-11-12.md), [earlier full candidate](results-2026-11-12.md) and [focused steps/profiles](advertised-window-results-2026-11-12.md).
- [Source-matched four-case Release profiles](raw/framed-window-profiles/summary.json), [all eight profile-only trials and counterpart measurements](raw/framed-window-profiles/trials.jsonl), [profile source/environment hashes](raw/framed-window-profiles/environment.json).

CPU target remains unmet wherever the per-case interval exceeds the ceiling; crossing intervals remain inconclusive. Hashing, filesystem inspections, allocations, upload admission and scheduling remain measured costs. No combined workload average substitutes for these gates. No tag was created.

Whole-process observed Swift peak RSS ranges from 15.0 to 48.0 MiB across cases;
the table gives each case's peak, and all memory gates use its own original
baseline. Seven concurrent-download trials (two warm-ups and five measured)
retain nine Swift connection-reset diagnostics, first reported at verified
completion. All payload/recovery checks pass; no diagnostic was removed or
turned into a retry. Native roles retain 304 normal `torrent finished` notices.
The original control-limit stall is absent from all twenty-one many-file Swift
seeding trials, whose maximum transfer wall time is 5.24 seconds.

## Rejected piece-decoder follow-up

A focused experiment parsed piece headers directly from the bounded input
buffer and copied the payload without first constructing a complete frame-body
object. Fourteen trials were accepted, but single-file hybrid download CPU was
6.988 versus 6.950 s/GiB: independent ratio 1.005 [0.933–1.105]. Throughput was
178.1 versus 182.4 MB/s: 0.977 [0.829–1.074]. Neither establishes a benefit.
Original and immediate-before memory gates pass; the latter is 0.998
[0.974–1.031], with observed maximum ratio 1.004.

The production experiment is fully reverted. Two added contract tests remain:
owned payloads across fragmented/coalesced input and buffer compaction, and
strict piece-size errors retaining the following frame. They pass on the
original decoder. All 336 package tests pass both with the experiment and after
restoring production. This experiment does not resolve the measured hybrid
CPU regression; no retry or discarded sample is used to claim otherwise.

[Every trial](raw/direct-piece-decode-hybrid/trials.jsonl),
[summary](raw/direct-piece-decode-hybrid/summary.json),
[independent before/after intervals](raw/direct-piece-decode-hybrid/before-after.json),
[source/environment hashes](raw/direct-piece-decode-hybrid/environment.json),
[incremental memory](raw/direct-piece-decode-hybrid/memory-versus-immediate-before.json),
[checks](raw/direct-piece-decode-hybrid/checks.json) and
[discarded patch](raw/direct-piece-decode-hybrid/experiment.patch) retain the
negative result separately from the full matrix.

## Rejected available-request batching follow-up

Batching available upload requests reduced actor crossings without changing
request windows or budgets. Fourteen trials were accepted. Single-file v1 seed
CPU was 3.250 versus 3.288 s/GiB, ratio 0.989 [0.983–1.001], so a CPU benefit
is inconclusive. Throughput fell from 515.2 to 505.0 MB/s, ratio 0.980
[0.972–0.984]. Original-baseline memory passes; incremental memory is
inconclusive, ratio 1.085 [1.011–1.124], observed maximum ratio 1.031.

The production change is fully reverted. A burst-ordering test remains: cancel
and choke are handled while payload disk work is blocked, with exact remaining
payloads and accounting across plaintext/RC4 and limited/unlimited input. All
337 package tests pass with the experiment and after restoration; the bridge
was rebuilt after restoration. No CPU improvement is claimed.

[Trials](raw/available-requests-single-v1/trials.jsonl),
[comparison](raw/available-requests-single-v1/before-after.json),
[checks](raw/available-requests-single-v1/checks.json) and
[discarded patch](raw/available-requests-single-v1/experiment.patch) preserve
the result.
