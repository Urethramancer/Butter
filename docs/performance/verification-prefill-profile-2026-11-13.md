# Verification-prefill many-file hybrid profiles

Fresh Release Time Profiler captures for both engines validate independent
payload digests and saved-state reopening. All 94 Swift production-source
hashes match the three source comparisons. These diagnostics are separate
from timing acceptance; earlier source captures provide context, not paired
profile measurements.

| Swift Running samples | Previous source | Prefill candidate |
| --- | ---: | ---: |
| stat/open/close, flat | 46.5% | 44.5% |
| write operations, inclusive | 53.1% | 48.6% |
| layout stamps, inclusive | 39.7% | 36.8% |
| disk dispatch, inclusive | 79.2% | 77.2% |

The new Swift capture has 10,427 Running samples with no unavailable backtraces;
native has 2,780 with 223 unavailable (8.0%). Missing samples remain in the
denominator. Inclusive costs overlap. Statistical weights for Swift stat/open
fall from 2.639/1.701 to 2.368/1.522 seconds; these are sample weights, not
measured function durations or syscall counts. The profiles are consistent
with reduced write-side work, but do not establish fewer scans or larger batches.

SHA-1/SHA-256 compression weights remain comparable: Swift 0.476/0.458 seconds,
native 0.445/0.483. Filesystem inspection and opening remain the dominant Swift
gap; the trace does not support weakening stored-byte hashing. Thread-entry
trampolines do not establish thread-creation overhead. No new socket backend,
larger caches, queue limits or timer changes are justified by this capture.

[Attribution, source checks and raw hashes](verification-prefill-profile-2026-11-13.json)
retain evidence. Raw traces, exported samples and both engines' phase/counterpart
measurements remain in `.build/benchmarks/verification-prefill-many-hybrid-profile`.
