# Picker refill scans — 12 November 2026

The sixteen-request CPU profile attributes 15.7% of single-file v1 download
Running sample weight to picker allocation. Fresh selection repeatedly scans
the whole wanted set. The picker now tracks the contiguous completed prefix and
uses ascending remaining indices when every piece is wanted. It can stop after
finding a full candidate prefix at availability one only when there are no
suggestions: no later index can outrank those candidates. Sparse wanted sets
retain the existing scan. Rarity, suggestions, eligibility, exclusions, staged
verification and the active/request limits keep their existing rules.

Two new contracts pass on the unchanged implementation before the production
change: late rare/suggested candidates with full or selective wanted sets, and
corrupt/rejected staged pieces below completed holes. All eight picker tests,
35 focused tests and all 339 package tests pass with the change. Only a boolean
and a completed-prefix index are retained; no cache or queue limit increases.

Fourteen timing trials pass independent payload digest and saved-state reopen:
one warm-up per engine and six balanced measured pairs. Sources are warm and
processes/destinations fresh. Both runs use the sixteen-request Swift production
default, the same native counterpart, and equivalent persistence barriers.

| Single-file v1 download | Before | After | Independent ratio [95%] |
| --- | ---: | ---: | --- |
| Swift CPU seconds/GiB through durable | 4.206 | 3.597 | 0.855 [0.844–0.870] |
| Swift verified MB/s | 297.3 | 363.0 | 1.221 [1.180–1.236] |

CPU falls 14.5%; throughput rises 22.1%. Original-baseline and incremental memory
gates pass. Incremental median peak RSS ratio is 0.976 [0.955–0.991], with observed
maximum ratio 0.966. No trial was retried or removed.

Native-relative CPU is still 2.322 [2.279–2.367], above 1.25, and verified
throughput is 0.809 [0.801–0.813], below 0.90. Parity remains unmet. This focused
case does not replace the final eighteen-case matrix or native release checks.

[All trials](raw/picker-refill-single-v1/trials.jsonl),
[native ratios](raw/picker-refill-single-v1/summary.json),
[before/after](raw/picker-refill-single-v1/before-after.json),
[incremental memory](raw/picker-refill-single-v1/memory-versus-immediate-before.json),
[checks and baseline contracts](raw/picker-refill/checks.json) and
[environment/source hashes](raw/picker-refill-single-v1/environment.json)
retain the evidence. Independent cross-revision intervals use 10,000 bootstrap
resamples; samples from different revisions are not paired.
