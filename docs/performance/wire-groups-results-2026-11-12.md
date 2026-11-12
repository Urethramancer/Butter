# Owned upload wire buffers

Candidate `268476b` versus `e7eb79e`, single-file 1 GiB v1 TCP seeding:
28 validated trials, four declared warm-ups and six balanced source/engine pairs.
Production request windows, queue credits and verification remain unchanged.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.957 | 0.948–0.970 |
| Verified throughput | 1.001 | 0.982–1.008 |
| Peak RSS | 0.979 | 0.944–1.007 |
| Counterpart CPU seconds/GiB | 0.973 | 0.950–0.984 |

CPU improves 4.3% without an established regression in the other measured
metrics. Raw Swift medians are 2.780 → 2.668 CPU seconds/GiB and
583.4 → 581.4 MB/s; paired ratios account for trial order. Native control
intervals cross one. Current CPU/native remains 1.569 [1.538–1.597], above
the 1.25 target; throughput/native is 1.298 [1.281–1.303]. These are focused
source diagnostics, not full-matrix acceptance. Broader seeding results follow;
download checks and full-matrix acceptance remain pending.

The change encodes available upload requests into owned buffers bounded by
256 KiB and sixteen frames. Contiguous frames share their wire storage;
cancelled gaps and mixed buffers use a bounded join. Receipts retain accounting
without retaining source buffers during a joined network write. No piece-cache
slice is retained by the output queue. µTP keeps separate frame buffers to
preserve transport admission ownership. Control messages never wait for a full
batch. All existing output limits and cancellation tokens remain.

All 354 package tests, Release build, fifteen focused tests under each of Address
and Thread Sanitizer, and 156 native upload fixtures pass. Native coverage includes
TCP/µTP, encryption, selective storage and fragmented IPv4/IPv6 traffic. The earlier
full-run µTP timeout remains unresolved; this pass does not erase that failure.

[Measurements, validation and raw hashes](wire-groups-comparison-2026-11-12.json)
retain the evidence. Raw trials remain under
`.build/benchmarks/wire-groups-single-seed-source-order`; validation logs remain
under `.build/diagnostics/piece-buffer/wire-groups-*`.

## Broader seeding checks

Each hybrid case uses its own six balanced source pairs and four warm-ups;
all 84 trials validate. These remain separate workloads, with no combined score.

| Hybrid workload | CPU ratio [95% interval] | Throughput ratio [95% interval] | RSS ratio [95% interval] | Counterpart CPU ratio [95% interval] |
| --- | --- | --- | --- | --- |
| Single | 0.964 [0.951–0.973] | 1.000 [0.980–1.020] | 0.971 [0.938–1.034] | 0.970 [0.963–0.978] |
| Many files | 0.978 [0.956–0.983] | 1.001 [0.985–1.018] | 0.984 [0.946–1.023] | 0.969 [0.953–0.991] |
| Concurrent | 0.978 [0.955–0.989] | 1.016 [0.996–1.026] | 0.955 [0.923–0.984] | 0.999 [0.961–1.012] |

CPU improves in all three cases. Concurrent RSS also improves reproducibly;
none establishes a cost in the measured metrics. Current raw medians are
631.1 MB/s and 3.122 CPU s/GiB (single), 284.7 MB/s and 4.741 s/GiB (many),
and 855.5 MB/s and 3.533 s/GiB (concurrent). Current CPU/native remains
1.768, 2.376 and 1.852 respectively, so parity is still unmet. Native throughput
controls shift slightly in the many-file case (ratio 1.005 [1.0002–1.009]);
source effects and control results are retained separately.

An initial command supplied only format/direction filters. The harness selected
no source cases and exited before any trial. That setup failure, environment,
fixture manifest and log are retained under
`.build/benchmarks/wire-groups-hybrid-seed-source-order` and
`.build/diagnostics/piece-buffer/wire-groups-hybrid-seed-source-order.log`.
The corrected commands supply all three filters and use fresh output directories;
no timed trial is discarded or retried.

[Broader measurements and raw hashes](wire-groups-broader-comparison-2026-11-12.json)
retain results. Download regression checks and full-matrix acceptance remain open.

## Download regression checks: first version disqualified

All 84 download trials validate, but the concurrent hybrid case establishes a
peak-RSS increase. That disqualifies `268476b` in this form despite its seeding
CPU gains. Revise the ordinary request/control representation before retention.
No timed sample is retried or omitted.

| Download workload | CPU ratio [95% interval] | Throughput ratio [95% interval] | RSS ratio [95% interval] |
| --- | --- | --- | --- |
| Single v1 | 1.008 [1.000–1.021] | 0.992 [0.964–1.007] | 0.992 [0.986–1.016] |
| Many-file hybrid | 1.044 [0.960–1.079] | 0.952 [0.923–1.054] | 1.016 [0.970–1.074] |
| Concurrent hybrid | 0.997 [0.993–1.042] | 1.007 [0.913–1.041] | 1.015 [1.008–1.074] |

The single-file CPU lower bound is 0.999648 before rounding, so that CPU
increase is inconclusive. Many-file changes are also inconclusive, rather than
proof of unchanged performance. Counterpart CPU intervals cross one in all
three download cases. [Complete download measurements and raw hashes](wire-groups-download-comparison-2026-11-12.json)
retain the source/control results and raw paths.

## Revision: preserve ordinary Data frames

Revision `4806204` keeps ordinary frames directly as Data, allocating shared wire
wrappers only for grouped upload payloads. Its own fixed six-pair comparisons
against `e7eb79e` validate all 56 trials. This is a changed source, rather than a
retry or extension of the first version's measurements.

| Revised workload | CPU ratio [95% interval] | Throughput ratio [95% interval] | RSS ratio [95% interval] | Counterpart CPU ratio [95% interval] |
| --- | --- | --- | --- | --- |
| Concurrent hybrid download | 0.997 [0.982–1.018] | 1.019 [0.980–1.078] | 0.992 [0.929–1.044] | 0.993 [0.960–1.145] |
| Single v1 seed | 0.957 [0.920–0.972] | 0.986 [0.968–1.016] | 0.977 [0.952–1.038] | 0.954 [0.914–0.999] |

The seeding CPU reduction remains reproducible. No measured cost is established
in these two revised cases. The concurrent RSS interval remains wide: this does
not prove unchanged memory or establish a direct revision/first-version effect.
The original version's measured memory cost remains disqualifying and is not
erased by the revision. Current v1 seeding raw medians are 578.6 MB/s and
2.686 CPU seconds/GiB versus native 444.1 MB/s and 1.750 s/GiB; the paired
CPU/native ratio is 1.527 [1.473–1.607], still above target.

The revision passes 354 package tests, fifteen focused tests under each
sanitizer, and Release build. The first version's 156 native upload checks do
not substitute for final native validation of the revised representation.
[Revised comparisons and raw hashes](wire-raw-comparison-2026-11-12.json) retain
results. Broader source checks, native validation and full-matrix acceptance
remain pending.

## Revised broader source checks

The remaining five revised cases validate all 140 trials, bringing revision
`4806204` to 196 accepted source trials across seven cases. Each case retains
its own fixed six balanced source/engine pairs and four warm-ups. No combined
workload score or source-null extension is used.

| Revised workload | CPU ratio [95% interval] | Throughput ratio [95% interval] | RSS ratio [95% interval] | Counterpart CPU ratio [95% interval] |
| --- | --- | --- | --- | --- |
| Many-file hybrid download | 0.992 [0.956–1.031] | 1.021 [0.971–1.076] | 0.986 [0.908–1.028] | 0.986 [0.962–1.042] |
| Single v1 download | 1.022 [0.942–1.112] | 0.981 [0.887–1.050] | 1.004 [0.980–1.010] | 1.038 [0.873–1.129] |
| Single hybrid seed | 0.961 [0.939–0.989] | 1.028 [0.796–1.323] | 0.957 [0.906–0.986] | 0.977 [0.941–1.005] |
| Many-file hybrid seed | 0.977 [0.952–0.993] | 1.019 [0.996–1.087] | 0.959 [0.934–1.015] | 0.971 [0.941–0.986] |
| Concurrent hybrid seed | 0.969 [0.948–0.984] | 0.952 [0.695–1.037] | 0.923 [0.897–0.953] | 1.006 [0.859–1.039] |

CPU reductions are supported in all four revised seeding cases. Single and
concurrent hybrid seeding also establish RSS reductions. No checked metric
establishes a cost, but this does not prove unchanged performance: several
throughput and download intervals remain wide. In particular, concurrent
seeding throughput trends 4.8% lower with an interval reaching 30.5% lower;
that cost question is inconclusive and must remain explicit. Native-control
CPU and throughput intervals cross one in all five cases.

[Broader revised measurements and raw hashes](wire-raw-broader-comparison-2026-11-12.json)
retain all source/control intervals and absolute medians. The full native suite
is running after the timed comparisons, with failed fixtures retained. Full-matrix
acceptance and CPU parity remain unmet; these focused comparisons do not replace
the complete matrix or erase the first version's measured memory regression.

## Revised full native validation

The unfiltered full native suite exits successfully with 466 PASS records.
Coverage includes bidirectional TCP/µTP, encryption, selective storage,
fragmentation, identity, discovery, tracker and web-seed integrations. The
previously failing IPv6 v2 negotiated-µTP upload fixture passes in this full
sequence with unchanged deadlines. The cause of the original failure remains
unexplained; its evidence and the earlier isolated/stress passes remain recorded.

[Native outcome, log hash and source manifest](wire-raw-native-validation-2026-11-12.json)
retain the evidence. The wrapper removes successful temporary fixtures and
binaries, and would retain failed fixtures. Full-matrix performance acceptance
and CPU parity remain open.
