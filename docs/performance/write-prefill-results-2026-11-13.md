# Refill the existing window during writes

Candidate `cd68e8f` versus `9b08091` moves the existing TCP refill from before
verification to before the admitted disk write. Each of three source cases
uses four warm-ups and six balanced source/engine pairs. All 84 trials validate
independent payload digests and saved-state reopening; no failures or retries.
All 94 production-source hashes match across the cases.

| Download workload | CPU ratio [95%] | Verified throughput ratio [95%] | Peak RSS ratio [95%] | Counterpart CPU ratio [95%] |
| --- | ---: | ---: | ---: | ---: |
| Many-file hybrid | 0.891 [0.878–0.907] | 1.167 [1.147–1.188] | 0.990 [0.982–1.005] | 0.926 [0.885–0.942] |
| Concurrent hybrid | 0.959 [0.936–0.995] | 1.123 [1.026–1.235] | 1.008 [0.964–1.076] | 0.871 [0.794–0.906] |
| Single-file v1 | 0.896 [0.886–0.908] | 1.194 [1.163–1.228] | 0.989 [0.980–0.997] | 0.918 [0.851–0.958] |

CPU and throughput improve reproducibly in all three cases. Single-file RSS
also improves; many-file and concurrent RSS are inconclusive. No measured cost
is established, but the concurrent RSS interval includes a 7.6% increase, so
absence of cost is unproven. Counterpart CPU falls in every case. Native CPU
and throughput control intervals cross one. These are separate source cases,
not a combined performance score; earlier refill gains are not compounded.

Raw single-file Swift medians are 278.7 → 327.9 MB/s and 4.432 → 4.003 CPU
seconds/GiB. Its candidate/native paired ratios remain 0.732 [0.723–0.750]
for verified throughput and 2.231 [2.189–2.259] for CPU. Many-file hybrid
medians are 112.3 → 131.3 MB/s and 9.762 → 8.696 CPU seconds/GiB, still
0.292 [0.268–0.305] native throughput and 3.232 [3.178–3.382] native CPU.
Parity remains unmet.

The existing unrestricted TCP/authenticated-hash guard remains. Refill runs
after staging and disk admission, with writing blocks excluded from selection.
No queues, tasks, buffers, caches or caps are added; the production eight-request
window, actual-send timestamps, deadlines and disk limits remain. Stored-byte
hashes and filesystem checks still precede verified completion.

The new scalar/batched test holds the storage worker while checking requests
overlap admitted writes within the existing window, with no piece published as
verified. Both cases fail before the production edit and pass afterward. All
357 package tests, nine focused tests under each sanitizer and Release build pass.

The full native interoperability suite passes with 466 PASS records, including
bidirectional TCP/µTP, encryption, fragmentation, selective storage, discovery
and web seeds. The historical µTP timeout passes with unchanged deadlines;
its original cause remains unexplained. Application contract and lifecycle
suites pass. Native storage records 52 passes covering killed-process recovery,
actual ENOSPC, failed checkpoint publication and read-only volumes. Unsigned
Debug/Release application builds, linkage/licence checks and the unchanged
repeat build pass. The user's Xcode edits remain untouched; no tag is created.

The full matrix remains pending. The candidate is provisional; this is not
release acceptance.

[Measurements, validation and raw hashes](write-prefill-comparison-2026-11-13.json)
retain the evidence. Raw trials remain in the three
`.build/benchmarks/write-prefill-*-source-order` directories.
