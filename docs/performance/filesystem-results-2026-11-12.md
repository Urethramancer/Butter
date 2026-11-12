# Filesystem inspection experiments — 12 November 2026

The first focused experiment reduces many-file v2 seeding CPU from 9.001 to
8.184 seconds/GiB through durable completion. Its independent before/after
ratio is 0.909 [0.894–0.933] at 95%, using 10,000 median bootstrap resamples.
Verified throughput rises from 197.1 to 202.3 MB/s: 1.026 [1.002–1.055]. All
fourteen trials were accepted, including one warm-up per engine and six balanced
measured pairs. These cross-commit samples are not paired with each other.

The change reuses validation of the current parent prefix within a single file
stamp scan. It compares exact UTF-8 bytes, validates every new filename and
retains the whole-path length/absolute-path checks. Files are still inspected
individually; directory descriptors still expire with each scan, and the full
before/after stored-byte verification scans remain. No request, cache, queue or
admission limit changed.

The new path tests cover malformed leaves, UTF-8 byte lengths, NULs, traversal,
absolute paths, parent switching and root-level files. Existing fresh-scan,
replacement, symlink, hard-link and corruption tests remain. All 329 package
tests passed serially, all 51 storage tests passed under each sanitizer, and the
native crash/ENOSPC/read-only/replacement suite passed.

Memory passes the original baseline gate. Native-relative CPU is still
4.375 [4.311–4.482] and throughput 46.5% [45.0–48.6%], outside the unchanged
targets. The [latest full matrix](tcp-batching-results-2026-11-12.md) remains the
preceding candidate; this one-case experiment does not establish other cases.

- [Every trial](raw/scan-parent-many-v2/trials.jsonl), [summary](raw/scan-parent-many-v2/summary.json), [environment and complete source hashes](raw/scan-parent-many-v2/environment.json), [fixtures](raw/scan-parent-many-v2/fixtures.json).
- [Independent before/after intervals](raw/scan-parent-many-v2/before-after.json) and [correctness/sanitizer/native evidence](raw/scan-parent-many-v2/checks.json).

The fresh profiles still place filesystem metadata calls among the largest
costs. Reducing those calls while preserving every file-identity check remains
open. No parity or release claim is made, and no tag was created.
