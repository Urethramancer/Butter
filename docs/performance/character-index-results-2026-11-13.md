# Character indices after byte separator lookup

Candidate `0264db9` versus corrected baseline `5148f4b`: many-file 1 GiB hybrid
TCP download, 256 KiB pieces and production windows. Four warm-ups precede six
balanced source/engine pairs. All 28 trials validate independent payload digests
and saved-state reopening. No trial is retried or omitted.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.959 | 0.950–0.986 |
| Verified throughput | 1.048 | 1.019–1.058 |
| Peak RSS | 0.997 | 0.959–1.0005 |
| Counterpart CPU seconds/GiB | 1.001 | 0.966–1.042 |

CPU falls 4.1% and throughput rises 4.8%; RSS and counterpart CPU changes are
inconclusive. No measured cost is established, but absence of cost is unproven.
Native controls' intervals cross one. Raw Swift medians are 8.683 → 8.406 CPU
seconds/GiB and 132.6 → 137.8 MB/s. Candidate/native CPU remains 3.095
[3.042–3.148], with throughput 0.304 [0.299–0.313]; parity remains unmet.

The scanner searches bytes for the separator, converts just that position to a
validated String character index, then keeps the existing substring/leaf checks.
A separator joined to combining marks uses the original character lookup and
the corrected validated component fallback. No descriptor cache, queue, request
window, stored-byte hash or filesystem call is removed or enlarged.

The baseline correction first reproduces rejection of nested combining-mark
leaves on unchanged production. It also checks traversal and nested symlink
rejection. It is committed separately, so this source comparison measures only
the faster lookup. The candidate passes 358 package tests, 63 storage tests
under each sanitizer and Release build. Broader comparisons and native
interoperability remain pending; this is focused evidence, not release acceptance.

The earlier UTF-8-only RSS regression remains rejected. These are separate runs
with a corrected baseline; they do not isolate why their memory results differ
or establish that character-index conversion fixes the earlier memory cause.

[Measurements, validation and raw hashes](character-index-comparison-2026-11-13.json)
retain evidence. Raw trials remain in
`.build/benchmarks/character-index-many-hybrid-source-order`.
