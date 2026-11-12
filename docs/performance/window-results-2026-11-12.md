# Bounded request-window tuning — 12 November 2026

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
