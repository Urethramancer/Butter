# Lazy verification: full-transfer source comparison

All 28 trials validate in the fixed six-pair, balanced many-file hybrid download
comparison. Candidate `a476e2a` is compared with `2801926`, which already contains
scoped write/piece inspection. This isolates subsequent lazy-verification,
completion-barrier and repair changes from those earlier measured gains. No
concurrent builds or tests ran during timing; counters and profilers were off.

| Current / preceding source | Median | 95% interval |
| --- | ---: | ---: |
| CPU/GiB through durable completion | 0.9957 | 0.9895–1.0415 |
| Verified throughput | 1.0002 | 0.9501–1.0266 |
| Peak RSS | 1.0019 | 0.9530–1.0806 |
| Counterpart CPU/GiB | 0.9968 | 0.9699–1.0533 |

Every source interval includes one. No speed-up or regression is established;
this does not prove absence of cost. Native controls also include one. The
standalone restart diagnostic demonstrates earlier availability without hiding
remaining checks; it does not establish a full-transfer CPU reduction.

The driver uses direct storage and its normal eager policy, with prechecked
seed setup outside the transfer window. Thus this comparison checks ongoing
transfer costs, not managed startup latency. Durable metrics retain forced
completion checkpoints. Every trial has independent streaming digests and
saved-state reopening. This fixed source experiment makes no full-matrix
acceptance claim and performs no uncertainty-driven retries.

[Raw trials](raw/lazy-verification-source/trials.jsonl),
[summary](raw/lazy-verification-source/summary.json) and
[environment](raw/lazy-verification-source/environment.json) retain all samples,
binary/source hashes, production limits and reference provenance. The installed
archive/toolchain qualification in the
[native diagnostics](restart-and-native-diagnostics-2026-11-13.md) still applies.
