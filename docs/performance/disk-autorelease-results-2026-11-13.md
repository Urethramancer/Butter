# Rejected per-job autorelease scope

Candidate `9aa0aa6` versus `18ef13e`: many-file 1 GiB hybrid TCP download,
256 KiB pieces, production windows, four warm-ups and six balanced source pairs.
All 28 trials validate independent payload digests and saved-state reopening.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 1.000 | 0.989–1.016 |
| Verified throughput | 1.000 | 0.987–1.022 |
| Peak RSS | 0.991 | 0.948–1.012 |
| Counterpart CPU seconds/GiB | 0.994 | 0.976–1.084 |

Rejected and reverted: explicit `.workItem` autorelease frequency establishes
no benefit. All native control intervals cross one. No null is extended or
retried, and this does not establish the cause of the rejected UTF-8 memory cost.
The scanner, filesystem calls, queue/admission limits and caches were unchanged.

Candidate passes 357 package tests, 62 storage tests under each sanitizer and
Release build. Restored production passes 62 storage tests, both Release outputs
and the bridge build; all 94 source hashes match the completed write-refill matrix.
User Xcode edits remain untouched.

[Measurements, check logs, rejected patch and raw hashes](disk-autorelease-comparison-2026-11-13.json)
retain evidence. Raw trials remain in
`.build/benchmarks/disk-autorelease-many-hybrid-source-order`.
