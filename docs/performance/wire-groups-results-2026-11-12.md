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
source diagnostics, not full-matrix acceptance. Broader cases remain pending.

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
