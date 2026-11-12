# Revised-source many-file hybrid CPU profiles

Both engines' fresh Release captures validate payload digests and saved-state
reopening. All 94 source hashes match the completed revised-candidate full matrix.
These are instrumented diagnostics, excluded from performance acceptance.

Swift has 11,041 Running samples, including two unavailable backtraces (0.018%).
Native has 2,638, including 72 unavailable backtraces (2.73%). Analysis includes
only the tested PID; missing backtraces remain in the denominator.

| Swift cost | Running samples |
| --- | ---: |
| stat | 23.9% flat |
| open | 15.4% flat |
| close | 7.2% flat |
| payload write | 5.0% flat |
| SHA-1 / SHA-256 compression | 4.2% / 4.2% flat |
| write operations | 53.1% inclusive |
| layout stamps | 39.7% inclusive |
| disk dispatch | 79.2% inclusive |

Inclusive costs overlap and must not be added. Kernel trampolines do not
establish thread-creation costs. SHA compressor statistical weights are
0.460/0.460 seconds for Swift and 0.464/0.481 for native; these are sample
weights rather than measured function durations. The comparable hash weights
and much larger filesystem costs support targeting filesystem work first.

The current receive path awaits each available storage batch and its ready-piece
verification before returning to the network reader. This is a concrete boundary
to investigate for bounded coalescing; no new scheduling benefit is established
by the profile. Checks, admission, cancellation and durability must remain.
Previous queued/explicit verified-read batching and descriptor/bulk-scan
experiments remain rejected; their null results are not replaced by this trace.

[Compact attribution and raw hashes](wire-raw-many-hybrid-profile-2026-11-13.json)
retain evidence. Raw traces, exports, both engines' phases and separate counterpart
measurements remain in `.build/benchmarks/wire-raw-many-hybrid-profile`.
