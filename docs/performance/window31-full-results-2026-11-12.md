# Full thirty-one-request comparison — 12 November 2026

All 252 trials were accepted, with zero failures. Memory passes 18/18 cases,
verified throughput 9/18 and CPU 0/18. The unchanged gates are at least
90% native verified throughput, at most 1.25× native CPU seconds/GiB through
durable completion, and peak RSS within 10% of the original fresh Swift baseline.
CPU parity remains unmet.

Production source is `5b9ef12`; measured evidence revision is `b6e8a8a3ce73e478b54d48d8c0f3ca55deae6497`.
The preceding full candidate is production `1931e70`; the original fresh baseline
is `3a4df88`. Every case uses one warm-up per engine, then six balanced measured
pairs. No acceptance interval crosses a threshold; no case requires extension.
Sources are explicitly warm, processes and destinations fresh, transport plaintext
TCP, pieces 256 KiB and windows the production defaults (Swift 31; native settings
in each ready event). Filesystem safeguards, hashing and persistence barriers stay
in place. Encryption and µTP are correctness regressions outside timing scope.

Compared with the preceding full candidate, independent CPU intervals improve
12 cases, regress 1 and leave 5 inconclusive.
Cross-revision samples are not paired; paired native ratios remain separate.
No combined workload average substitutes for the per-case gates.

All 339 package tests, 466 native reference checks and 52 focused tests under each
of Address and Thread Sanitizer pass for this production source. The native suite
includes encrypted TCP, µTP and all 24 session DHT transfers. The subsequent
[source-matched profiles](window31-profiles-2026-11-12.md) cover all four standard
workloads and both seeding regressions: twelve accepted profile-only trials.
Remaining release acceptance and the performance target remain open.

## Per-case results

CPU is Swift seconds/GiB through durable completion; throughput is verified MB/s.
Before means the preceding full candidate. Native ratios are paired medians with
95% bootstrap intervals (10,000 resamples). Peak RSS is the whole-process observed
maximum including warm-ups. Every memory gate uses its own original baseline.

### Downloads

| Workload / format | Pairs | CPU before → current | MB/s before → current | Throughput/native [95%] | CPU/native [95%] | Memory / peak MiB |
| --- | ---: | ---: | ---: | --- | --- | --- |
| single / v1 | 6 | 5.07 → 3.22 | 255.5 → 388.4 | 0.860 [0.846–0.872] | 2.037 [2.014–2.075] | pass / 15.8 |
| single / v2 | 6 | 6.46 → 3.28 | 199.1 → 378.5 | 0.846 [0.836–0.860] | 2.017 [1.999–2.048] | pass / 17.5 |
| single / hybrid | 6 | 6.95 → 3.49 | 182.4 → 348.6 | 0.784 [0.773–0.806] | 1.537 [1.475–1.555] | pass / 18.1 |
| many / v1 | 6 | 11.19 → 6.37 | 104.3 → 181.2 | 0.399 [0.395–0.407] | 3.782 [3.671–3.850] | pass / 17.1 |
| many / v2 | 6 | 12.08 → 6.25 | 96.8 → 181.8 | 0.409 [0.403–0.418] | 3.511 [3.491–3.548] | pass / 17.0 |
| many / hybrid | 6 | 12.41 → 6.52 | 94.0 → 173.0 | 0.383 [0.373–0.386] | 2.718 [2.681–2.814] | pass / 18.5 |
| concurrent / v1 | 6 | 7.42 → 6.03 | 585.8 → 767.1 | 1.602 [1.541–1.617] | 3.192 [3.087–3.296] | pass / 22.6 |
| concurrent / v2 | 6 | 8.26 → 6.12 | 486.5 → 754.2 | 1.602 [1.533–1.636] | 3.128 [3.104–3.147] | pass / 24.8 |
| concurrent / hybrid | 6 | 7.94 → 5.50 | 549.4 → 824.8 | 1.636 [1.592–1.653] | 2.184 [2.116–2.222] | pass / 25.0 |

### Seeding

| Workload / format | Pairs | CPU before → current | MB/s before → current | Throughput/native [95%] | CPU/native [95%] | Memory / peak MiB |
| --- | ---: | ---: | ---: | --- | --- | --- |
| single / v1 | 6 | 3.29 → 3.13 | 515.2 → 529.3 | 1.170 [1.162–1.176] | 1.938 [1.914–1.982] | pass / 22.5 |
| single / v2 | 6 | 3.41 → 3.35 | 518.9 → 524.1 | 1.171 [1.161–1.194] | 1.960 [1.911–2.006] | pass / 26.8 |
| single / hybrid | 6 | 3.84 → 3.77 | 608.4 → 608.5 | 1.359 [1.340–1.416] | 2.259 [2.229–2.294] | pass / 24.4 |
| many / v1 | 6 | 5.05 → 5.30 | 390.5 → 298.7 | 0.655 [0.637–0.773] | 3.372 [3.119–3.486] | pass / 23.2 |
| many / v2 | 6 | 5.17 → 4.97 | 290.6 → 384.3 | 0.868 [0.862–0.874] | 2.617 [2.474–2.838] | pass / 25.1 |
| many / hybrid | 6 | 5.56 → 5.53 | 290.2 → 281.6 | 0.624 [0.620–0.626] | 2.893 [2.836–3.004] | pass / 25.7 |
| concurrent / v1 | 6 | 3.56 → 3.41 | 793.1 → 748.5 | 1.564 [1.548–1.580] | 1.774 [1.725–1.845] | pass / 43.1 |
| concurrent / v2 | 6 | 4.03 → 3.58 | 983.7 → 786.8 | 1.662 [1.650–1.686] | 1.819 [1.653–1.888] | pass / 46.5 |
| concurrent / hybrid | 6 | 4.10 → 4.05 | 834.6 → 812.1 | 1.605 [1.576–1.670] | 2.065 [1.863–2.196] | pass / 43.5 |

## Regressions and uncertainty

- many / v1 / seed: CPU 1.051 [1.039–1.061]; throughput 0.765 [0.733–0.896] (independent current/preceding intervals).
- concurrent / v2 / seed: CPU 0.889 [0.873–0.969]; throughput 0.800 [0.747–0.968] (independent current/preceding intervals).

Many-file v1 seeding is a measured regression and remains open. Timing alone
does not establish its cause; neither the target nor its samples are relaxed.
The unchanged seeding bottlenecks include stored-byte hashing, whole-layout
stamp inspection and per-block task/cache scheduling. Downloads still retain
hashing, disk calls and scheduling after removing the dominant picker scan.

Many-file v1 seeding CPU rises 5.1%, while throughput falls 23.5%. Concurrent
v2 seeding uses 11.1% less CPU but loses 20.0% throughput; it still clearly
passes the native throughput gate. Both losses remain visible separately.
A subsequent [balanced source comparison](seeding-source-comparison-2026-11-12.md)
does not reproduce either loss as a source effect. That diagnostic does not
replace these samples or explain their sequence/runtime cause.
All nine download CPU intervals improve, with individual reductions from
18.7% to 49.8%; this range is not a combined workload score.

Per-case whole-process Swift peak RSS spans 15.8–46.5 MiB. Three measured
concurrent-download trials retain four Swift connection-reset diagnostics,
first reported at verified completion. Every payload and recovery check passes;
none was converted into a retry. Native roles retain 311 normal `torrent finished`
notices, also first reported at verified completion. Raw diagnostic roles identify
the actual engine, including the always-native counterpart.

## Evidence

- [All trials](raw/window31-full/trials.jsonl), [summary](raw/window31-full/summary.json), [environment/source hashes](raw/window31-full/environment.json), [fixtures](raw/window31-full/fixtures.json) and [checks](raw/window31-full/checks.json).
- [Independent before/after intervals](raw/window31-full/before-after.json), [comparison CSV](window31-full-comparison-2026-11-12.csv), [all phase and counterpart accounting](raw/window31-full/phase-accounting.json), [every reported diagnostic with first phase](raw/window31-full/diagnostics.json).
- [Source-specific native/sanitizer evidence](raw/window31-single-v1/checks.json), [preceding full matrix](framed-window-results-2026-11-12.md), [complete method](README.md).

No tag was created.
