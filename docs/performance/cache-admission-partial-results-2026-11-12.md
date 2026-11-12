# Cache admission partial matrix — 12 November 2026

This run was interrupted after eight of eighteen planned cases completed six measured pairs each. All 117 trial records are retained: 116 accepted and one operator-interrupted trial in the next case. Its two warm-ups and first measured pair also remain. This is not a completed full-matrix result.

Measured revision `5d4fabb` has the same production source as fully verified `9c90973`. Production and harness hashes matched when the run was archived. Processes and destinations were fresh, sources explicitly warm, transport plaintext TCP and windows the production defaults. The original memory baseline remains `3a4df88`.

All eight completed cases pass memory and miss the 1.25× native CPU ceiling. Three single-file seeding cases pass the 90% throughput floor. CPU values are seconds/GiB through durable completion. Ratios are paired median percentile bootstrap intervals, 10,000 resamples, 95%; they are not ratios of the displayed medians.

| Case | Swift CPU | Native CPU | Swift MB/s | Native MB/s | CPU ratio [95%] | Throughput ratio [95%] |
| --- | ---: | ---: | ---: | ---: | --- | --- |
| single / v1 / download | 5.30 | 1.61 | 243.8 | 448.7 | 3.314 [3.241–3.806] | 0.544 [0.458–0.551] |
| single / v1 / seed | 3.29 | 1.72 | 546.6 | 443.0 | 1.904 [1.802–1.956] | 1.242 [1.202–1.291] |
| single / v2 / download | 6.86 | 1.65 | 185.8 | 446.9 | 4.079 [3.869–4.399] | 0.418 [0.387–0.445] |
| single / v2 / seed | 3.41 | 1.70 | 553.8 | 447.8 | 2.031 [1.949–2.156] | 1.239 [1.209–1.251] |
| single / hybrid / download | 6.95 | 2.29 | 181.7 | 445.9 | 3.030 [2.810–3.213] | 0.406 [0.386–0.430] |
| single / hybrid / seed | 4.06 | 1.78 | 607.9 | 445.4 | 2.334 [2.236–2.365] | 1.360 [1.105–1.380] |
| many / v1 / download | 11.01 | 1.72 | 105.6 | 449.1 | 6.424 [6.393–6.451] | 0.235 [0.233–0.237] |
| many / v1 / seed | 5.84 | 1.95 | 17.0 | 448.5 | 3.005 [2.857–3.063] | 0.038 [0.038–0.038] |

## Repeated seeding stall

Every measured many-file v1 Swift seeding trial recorded a control-message-limit disconnect and about 63 seconds in transfer; the native counterpart recorded a reset and subsequently completed. Independent bytes/state checks passed, so these are accepted but slow trials with retained diagnostics, not failed hashes or discarded outliers.

Code inspection found that the extension handshake advertises 32 requests, but the unchanged 512 KiB output limit fits only 31 maximum payload frames (16,384 + 13 bytes each). The pinned native implementation honours `reqq`. An over-promised queue is a candidate cause of repeated busy rejections; causality still requires a focused regression and corrected-revision comparison. No control or resource limit has been raised.

The controller received SIGINT after this case completed all six pairs, recording the next interrupted trial and executing child cleanup. A process check found no surviving driver from this run. Completed and interrupted records will not be overwritten or retried under the same source.

## Evidence

- [Every trial and counterpart measurements](raw/cache-admission-partial/trials.jsonl), [eight completed summaries](raw/cache-admission-partial/summary.json), [source/environment hashes](raw/cache-admission-partial/environment.json), [fixtures](raw/cache-admission-partial/fixtures.json).
- [Interruption reason and scope](raw/cache-admission-partial/termination.json), [controller output](raw/cache-admission-partial/controller.log).
- [Focused cache-admission benefit and all nine native checks](cache-load-admission-results-2026-11-12.md), [last completed full matrix](tcp-batching-results-2026-11-12.md).

The remaining cases are incomplete. No parity claim, aggregate passing score or tag is made.
