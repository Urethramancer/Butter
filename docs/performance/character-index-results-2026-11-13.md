# Rejected character-index lookup

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
under each sanitizer and Release build. These download gains do not override
the seeding regression below.

## Seeding regression and restoration

Many-file v1 seeding validates all 28 trials in another fixed six-pair source
comparison, with four warm-ups and no retries or extensions.

| Candidate/previous | Paired median | 95% interval |
| --- | ---: | ---: |
| CPU seconds/GiB | 0.954 | 0.949–0.982 |
| Verified throughput | 0.976 | 0.952–0.997 |
| Peak RSS | 0.954 | 0.903–1.074 |
| Counterpart CPU seconds/GiB | 0.993 | 0.975–1.015 |

Rejected and reverted: CPU improves 4.6% but throughput falls 2.4% with an
interval below one. Native control throughput also shifts down 0.6%
[0.1–1.1%]; this drift is retained and does not justify ignoring the observed
cost. Native control CPU and source RSS/counterpart CPU remain inconclusive.

Restored production passes 63 storage tests, both Release outputs and the bridge
build. The separately committed Unicode correction and its contracts remain;
no faster lookup survives. This baseline differs from the preceding full matrix
only by the cached Unicode split correction, with no performance claim for it.

The earlier UTF-8-only RSS regression remains rejected. These are separate runs
with a corrected baseline; they do not isolate why their memory results differ
or establish that character-index conversion fixes the earlier memory cause.

[Measurements, validation and raw hashes](character-index-comparison-2026-11-13.json)
retain evidence. Raw trials remain in
`.build/benchmarks/character-index-many-hybrid-source-order`.
