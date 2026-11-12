# Rejected bulk filesystem inspection

Two bounded, scan-local directory inspection candidates were compared with
`ecffa35`, each using six balanced source pairs and 28 validated trials.
Ratios below are candidate/previous, with 95% paired intervals.

| Candidate | CPU seconds/GiB | Verified throughput | Peak RSS |
| --- | --- | --- | --- |
| `4ade4ea` | 1.074 [1.052–1.102] | 0.717 [0.701–0.739] | 0.979 [0.952–1.036] |
| `40c21c2` | 0.987 [0.970–1.006] | 1.047 [0.984–1.350] | 1.036 [1.020–1.105] |

The first regressed CPU and throughput. Its separate profile identified costly
String matching; replacing that with a byte predicate did not establish a CPU
or throughput benefit and increased memory. Both candidates are reverted.
Neither justifies weakening filesystem checks or increasing caches.

Restored production sources match `ecffa35`. All 351 serial package tests and
both Release package builds pass. The expanded checkpoint-publication race
test remains. Raw trials, profile exports and diagnostics remain locally in
`.build/benchmarks/lean-bulk-source-order`,
`.build/benchmarks/lean-bulk-byte-source-order`,
`.build/benchmarks/lean-bulk-rejected-profile` and
`.build/diagnostics/piece-buffer`.
