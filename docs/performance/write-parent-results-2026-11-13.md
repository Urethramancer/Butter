# Rejected write-parent retention

Candidate `64a8804` versus `6851db1`, many-file 1 GiB hybrid TCP download,
256 KiB pieces and production request windows. Four warm-ups precede six
balanced source/engine pairs. All 28 trials validate independent payload digests
and saved-state reopening; every sample remains and no null is extended.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.975 | 0.950–1.011 |
| Verified throughput | 1.027 | 0.990–1.051 |
| Peak RSS | 1.007 | 0.990–1.019 |
| Counterpart CPU seconds/GiB | 0.987 | 0.846–1.245 |

Rejected and reverted: neither CPU nor throughput establishes reproducible
benefit. Raw Swift medians are 11.381 → 11.106 CPU seconds/GiB and
100.9 → 103.4 MB/s; those differences do not override paired uncertainty.
Native control CPU and throughput intervals cross one.

The prototype retained one immediate-parent descriptor only within a write job,
revalidated its complete stamp through the anchored root before each reuse,
and checked effective read access. Changed metadata/access forced a fresh open.
Root/deeper paths kept the original traversal. Eight payload descriptor slots,
existing temporary traversal budget, 256 KiB/sixteen-block jobs, per-block leaf
identity/link checks and all durability checks remained. The cursor was released
before fallback traversals and full scans. No payload/checkpoint cache was added.

Before timing, 355 package tests, 62 storage tests under each sanitizer, Release
build and all 52 native storage checks pass. New baseline contracts cover parent
replacement, symlink substitution, moving the original file into a replacement
parent, and removing parent read access between writes. They pass before the
production experiment and remain useful after its removal. The initial test
visibility compile error and all subsequent logs remain in local diagnostics.

Restored production passes 62 storage tests, both Release package builds and the
bridge build. All 94 source hashes match the completed revised-buffer full
matrix. No parent-retention production code survives. No parity claim is made.

[Measurements, validation and raw hashes](write-parent-comparison-2026-11-13.json)
retain evidence. Raw data remain in
`.build/benchmarks/write-parent-many-hybrid-source-order`, with the rejected patch
and failure/check logs in `.build/diagnostics/piece-buffer/write-parent-*`.
