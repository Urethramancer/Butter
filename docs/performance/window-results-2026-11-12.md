# Bounded request-window tuning — 12 November 2026

## Balanced recheck and restoration of the original default

The user's no-trade-offs requirement supersedes the earlier ten-percent memory
allowance for accepting optimisations. A fresh comparison changes only the
default from 31 to eight against `1d34479`: single-file 1 GiB v1 download,
warm sources, fresh processes/destinations, four warm-ups and six balanced
source/engine pairs. All 28 trials validate independent digests and saved-state
reopening; the eight-request candidate passes 24 focused tests.

| Eight / thirty-one | Median | 95% paired interval |
| --- | ---: | ---: |
| Swift CPU seconds/GiB | 1.407 | 1.380–1.479 |
| Verified throughput | 0.759 | 0.707–0.775 |
| Whole-process peak RSS | 0.959 | 0.932–0.977 |
| Counterpart CPU seconds/GiB | 1.567 | 1.447–1.736 |

The larger window has a measured memory cost: 31/eight peak RSS is 1.043
[1.024–1.073]. Restore the original eight-request default and explicitly give
up the window-tuning CPU/throughput gains. This reversal moves CPU further from
parity; it is not a performance improvement. Swift CPU medians are 3.412 →
4.815 s/GiB and throughput 372.7 → 281.3 MB/s. Eight-request CPU/native is
2.970 [2.893–3.125] and throughput/native 0.632 [0.590–0.656], both failing.
Native-control CPU rises 2.3% [1.3–4.7%] and throughput falls 0.7% [0.4–1.9%];
that smaller environmental difference remains in the record. No retries or
uncertainty-driven extensions are used in this fixed source diagnostic.

[Ratios and artifact hashes](window8-recheck-comparison-2026-11-12.json)
retain compact evidence. Raw phases, fixtures and source/build metadata remain
in `.build/benchmarks/window8-recheck-source-order`; the one-line experiment
patch remains in `.build/diagnostics/piece-buffer`.
The restored eight-request default passes all 351 package tests and both Release
builds. Native interoperability and final full-matrix acceptance remain pending.
The native run then exits 1 after 273 observed passes: the IPv6 v2 upload with
negotiated encryption and deliberate SYN-ACK loss times out before payload
traffic; no disk error is recorded. Cleanup also reports a reference flush
timeout. This failure remains unresolved and is not attributed to the window
change without evidence. The full log and its hash remain in
`.build/diagnostics/piece-buffer/window8-native-peer.log` and
`window8-native-failure.json`. A focused diagnostic preserves its fixture and
uses the original deadlines; the full suite is not retried to hide the failure.

## Historical independent comparison

The production default request pipeline increases from eight to sixteen blocks.
The existing maximum remains 32; the remote queue advertisement still bounds
each peer's actual window. Disk jobs stay at sixteen blocks/256 KiB, with the
same disk admission, output, cache and control-message limits. Available work
still flushes without waiting to fill a batch. Encryption and µTP retain their
existing input bounds.

The experiment follows on-CPU evidence of request-selection and file-open costs.
An eight-block window can supply at most 128 KiB before refill, below the existing
256 KiB storage job bound. Fuller available batches are a hypothesis for the
benefit; the timing result alone does not measure individual job occupancy.

A fresh baseline uses retained hash-readiness production source `317c80d` with
eight requests. The candidate changes only the default to sixteen. Each has
fourteen accepted trials: one warm-up per engine, then six balanced measured
pairs with the same pinned native counterpart. Sources are warm, processes and
destinations fresh, windows are each engine's production defaults, and payload
digests plus saved-state reopen pass. No timing or correctness failure occurred.

| Single-file v1 download | Eight | Sixteen | Independent ratio [95%] |
| --- | ---: | ---: | --- |
| Swift CPU seconds/GiB through durable | 5.188 | 4.206 | 0.811 [0.802–0.819] |
| Swift verified MB/s | 253.4 | 297.3 | 1.173 [1.159–1.215] |

CPU falls 18.9%; throughput rises 17.3%. Original-baseline and incremental
memory gates both pass. Incremental median peak RSS ratio is 1.045
[1.028–1.068], with observed maximum ratio 1.040. The full package suite passes
all 337 tests; 28 focused tests in four suites also pass. Committed source
`90c3414` subsequently passes all 466 native reference checks, including
encrypted TCP, µTP, discovery, sparse/hybrid proofs and web-seed transfers.
All 44 focused transfer/resource/output-budget tests pass under each of Address
and Thread Sanitizer for that committed source.
The final eighteen-case timing matrix remains outstanding.

Native-relative acceptance is still unmet: paired CPU ratio 2.692
[2.646–2.715] exceeds 1.25 and throughput 0.660 [0.657–0.679] is below 0.90.
This focused download result does not establish seeding or other-format gains.
It does not replace the earlier full matrix.

[Fresh eight-request trials](raw/window8-current-single-v1/trials.jsonl),
[sixteen-request trials](raw/window16-single-v1/trials.jsonl),
[native ratios](raw/window16-single-v1/summary.json),
[before/after](raw/window16-single-v1/before-after.json),
[incremental memory](raw/window16-single-v1/memory-versus-immediate-before.json),
[checks](raw/window16-single-v1/checks.json) and
[source/environment](raw/window16-single-v1/environment.json) retain the
evidence. Independent cross-revision intervals use 10,000 bootstrap resamples;
trials from different revisions are not paired.

## Fresh CPU profiles

After timing and correctness checks, source `90c3414` completed the four
required CPU-profile workloads for both engines: all eight profile-only trials
passed independent digest and state-reopen checks. These single instrumented
pairs do not establish timing improvements in the other workloads.

Single-file v1 download has 3,915 Running samples, twelve without backtraces
(retained in the denominator). Picker allocation accounts for 15.7% inclusive
weight, with `openat` at 5.3% flat and `close` at 5.8%. Many-file hybrid download
retains 33.8% under stamp scans, including 20.5% flat in `fstatat` and 13.6% in
`openat`. The previous hash-request subtraction cost is no longer prominent in
the hybrid profile. Single-file v1 seeding retains 5.3% under global task enqueue
and 14.8% flat in SHA1 compression. Inclusive percentages overlap; sample weights
are statistical attribution rather than measured CPU durations.

[Profile trials](raw/window16-cpu-profiles/trials.jsonl),
[profile environment](raw/window16-cpu-profiles/environment.json) and
[checks/XML hashes](raw/window16-cpu-profiles/checks.json) preserve the samples
and source fingerprints separately from timing results.
