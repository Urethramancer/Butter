# Rejected isolated UTF-8 separator scan

Candidate `c643c61` versus `93c73ce`, 128 files totalling 1 GiB, hybrid TCP
download, 256 KiB pieces and production windows. Four warm-ups precede six
balanced source/engine pairs. All 28 trials validate independent payload
digests and saved-state reopening; no sample is retried or omitted.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.940 | 0.934–0.955 |
| Verified throughput | 1.063 | 1.055–1.081 |
| Peak RSS | 1.019 | 1.008–1.052 |
| Counterpart CPU seconds/GiB | 0.967 | 0.947–0.983 |

Rejected and reverted: CPU falls 6.0% and throughput rises 6.3%, but peak RSS
rises 1.9% [0.8–5.2%]. This is an established cost under the user's requirement.
Native control intervals cross one. Raw Swift medians are 8.638 → 8.150 CPU
seconds/GiB and 133.7 → 143.0 MB/s; no performance improvement is retained.

The four-line change isolated UTF-8 separator lookup and prefix comparison from
the earlier rejected C-string/validator changes. Existing String leaf creation,
validation and filesystem calls remained. This rules out removing the C-string
change alone as a solution to the earlier memory cost; the allocation/lifetime
cause remains unproven.

All 62 storage tests pass normally and under each sanitizer on the candidate,
including Unicode, symlink/parent replacement and checkpoint contracts. Restored
production passes 62 storage tests, both Release builds and the bridge build.
All 94 source hashes match the completed write-refill full matrix. User Xcode
edits are untouched; no tag is created.

[Measurements, validation logs and raw hashes](byte-split-comparison-2026-11-13.json)
retain evidence. Raw trials remain in
`.build/benchmarks/byte-split-many-hybrid-source-order`; the rejected patch and
check logs remain in `.build/diagnostics/piece-buffer/byte-split-*`.
