# Rejected UTF-8 stamp-scan experiment

Six balanced source pairs compare a UTF-8 scanner and scoped C-string leaf
borrow with restored production `7926668`: 128 files totalling 1 GiB, v1
seeding, warm sources, fresh processes/destinations and production windows.
All 28 trials pass independent payload digests and saved-state reopening.

| Candidate/previous | Median | 95% paired interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.944 | 0.904–0.988 |
| Verified throughput | 0.991 | 0.953–0.999 |
| Whole-process peak RSS | 1.110 | 1.048–1.182 |
| Counterpart CPU seconds/GiB | 1.024 | 0.992–1.085 |

Rejected and reverted: lower CPU comes with memory and throughput regressions.
Native-control intervals cross one. Swift CPU medians are 4.150 → 3.902 s/GiB;
throughput is 396.8 → 394.6 MB/s. The unchanged production control remains
2.136 [2.061–2.268] times native CPU, outside the 1.25 target. No parity claim
or additional sampling follows this fixed six-pair diagnostic.

The candidate passes 351 package tests and 60 storage tests under each sanitizer.
The separately committed Unicode path ownership fix remains. Additional Unicode
parent/leaf parity cases remain useful independently of the rejected scanner.
Raw trials, phase accounting, source/build hashes and fixtures remain in
`.build/benchmarks/byte-stamp-source-order`; the rejected patch and checks
remain in `.build/diagnostics/piece-buffer/byte-stamp-*`.

Restoration passes all 351 package tests and both Release builds; all 94
production source hashes match `7926668`. The first restored package run fails
in an unchanged UDP rollback fixture: a TCP port collision masks the intended
UDP bind failure. The fixture now supplies an already-bound listener, preserving
the exact error and rollback assertions without production changes or retries.
The failed log remains; [check outcomes and hashes](byte-stamp-validation-2026-11-12.json)
retain verification evidence after successful routine logs are removed.
