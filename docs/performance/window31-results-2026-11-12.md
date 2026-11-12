# Thirty-one-request pipeline — 12 November 2026

The production request default increases from sixteen to 31, within the existing
maximum of 32 and the remote peer's advertised queue. This fits the current
31-frame upload advertisement and can prefetch work beyond one 256 KiB disk
job. Job size, disk admission, output, control and cache limits remain unchanged;
available batches still flush without waiting to fill. No verification or
filesystem safeguard changes.

The preceding picker candidate `9a2803a` supplies the sixteen-request baseline.
Only the production default changes. All 339 package tests pass. Each timing
case retains fourteen accepted trials: one warm-up per engine and six balanced
measured pairs, with the same pinned native counterpart. Sources are warm,
processes and destinations fresh, with independent payload digest and usable
saved-state reopen. No trial is retried or removed.

| Single-file v1 download | Sixteen | Thirty-one | Independent ratio [95%] |
| --- | ---: | ---: | --- |
| Swift CPU seconds/GiB through durable | 3.597 | 3.274 | 0.910 [0.898–0.920] |
| Swift verified MB/s | 363.0 | 379.8 | 1.046 [1.033–1.054] |

CPU falls 9.0%; throughput rises 4.6%. Original-baseline and incremental memory
gates pass. Incremental median peak RSS ratio is 1.032 [1.022–1.054], with
observed maximum ratio 1.044. Pending requests increase within the existing cap;
the memory trade-off is retained explicitly.

Native-relative CPU remains 2.100 [2.080–2.108], above 1.25, and verified
throughput is 0.842 [0.836–0.849], below 0.90. Through-durable throughput is
reported separately and does not replace verified throughput for acceptance.
No acceptance interval crosses a threshold, so the case remains at six pairs.
Parity and the full eighteen-case candidate matrix remain open. Native
regression and sanitizer checks for this default are separate requirements.

Committed production source `5b9ef12` subsequently passes all 466 pinned native
reference checks, including encrypted TCP, µTP, all 24 session DHT transfers,
sparse/hybrid proofs and web-seed comparisons. All 52 focused picker, transfer,
resource and output-budget tests pass under each of Address and Thread
Sanitizer. The full matrix and remaining release acceptance are still open.

[All trials](raw/window31-single-v1/trials.jsonl),
[native ratios](raw/window31-single-v1/summary.json),
[before/after](raw/window31-single-v1/before-after.json),
[incremental memory](raw/window31-single-v1/memory-versus-immediate-before.json),
[checks](raw/window31-single-v1/checks.json) and
[source/environment](raw/window31-single-v1/environment.json) retain the evidence.
Independent cross-revision intervals use 10,000 bootstrap resamples; samples
from different revisions are not paired.
