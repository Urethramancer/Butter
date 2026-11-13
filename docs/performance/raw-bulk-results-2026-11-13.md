# Rejected raw-name bulk inspection

Candidate `d936b03` versus `6305bc7`: many-file 1 GiB hybrid TCP download,
256 KiB pieces and production request windows. Four warm-ups precede six
balanced source/engine pairs. All 28 trials validate independent payload digests
and saved-state reopening. No sample is retried, extended or omitted.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 1.017 | 1.007–1.036 |
| Verified throughput | 0.978 | 0.963–0.992 |
| Peak RSS | 1.013 | 1.008–1.017 |
| Counterpart CPU seconds/GiB | 1.017 | 0.962–1.029 |

Rejected and reverted: CPU rises 1.7%, throughput falls 2.2% and memory rises
1.3%, all established costs. Counterpart CPU is inconclusive. Native control
CPU/throughput intervals cross one. Raw Swift medians are 8.120 → 8.281 CPU
seconds/GiB and 138.4 → 134.6 MB/s. No gain is retained.

Unlike the earlier String-based directory map, this prototype retained packed
names in one scan-local 32 KiB buffer and indexed offsets/stamps by a numeric
byte hash. An exact byte comparison, never hash or Unicode equality alone,
established each match. Duplicate/hash collisions discarded the batch. Entries
were consumed once; invalid/missing/unsupported/type/link cases used scalar
checks. Enumeration and entries remained bounded; no descriptor survived a scan.
The independent combining-mark path correction remained in place.

Before timing, all 367 package tests, 68 storage tests under each sanitizer,
Release build and 52 native real-volume failure/recovery checks passed.
New tests exercised malformed bounds/offsets, canonical aliases, repeated
consumption, entry limits, native/scalar stamp parity, enumeration position and
unsafe-link/type fallback. These parser tests and code were removed with the
rejected prototype; its patch remains available in Git and local diagnostics.

Restoration passes 63 storage tests, Release/native outputs and the bridge
build. All 94 production-source hashes and the package match the completed
revised request-burst full matrix. No user Xcode edits are changed. The failure
shows removing entry String construction/normalisation is insufficient; it does
not identify the remaining bulk overhead. Do not repeat bulk variants without
a new measured cause.

[Summary, validation and raw hashes](raw-bulk-comparison-2026-11-13.json) retain
evidence. Raw trials remain in `.build/benchmarks/raw-bulk-many-hybrid-source-order`;
the rejected patch and logs remain in `.build/diagnostics/piece-buffer/raw-bulk-*`.
