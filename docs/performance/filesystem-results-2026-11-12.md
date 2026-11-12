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

## Rejected directory attribute batching

A subsequent production prototype queried one 32 KiB metadata batch after seeing
eight managed children in a parent, retained at most 256 records for that scan,
and fell back to individual inspection for absent/unsupported records. It used
an independent anchored directory handle, exact filename bytes and every field
required by the existing file-stamp and regular-file/link checks. Decoder bounds,
unsupported attributes, native field equivalence, directory offsets, Unicode
identities, link/type checks and checkpoint-time replacement passed 55 storage
tests. The API packing contract was checked against [Apple's manual](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/getattrlistbulk.2).

All fourteen timing trials were accepted, but CPU regressed from 8.184 to 9.054
s/GiB: independent ratio 1.106 [1.072–1.118]. Throughput changed from 202.3 to
198.5 MB/s, ratio 0.981 [0.956–1.015], inconclusive. Memory passed. Median
through-durable user CPU rose from 4.408 to 5.233 seconds, while system CPU
remained 3.779 versus 3.805. Separate profiles still show expensive metadata
calls alongside the added decoding/bookkeeping. Fewer individual `fstatat`
observations did not produce a CPU benefit.

The entire prototype and its dedicated decoder tests were removed. The restored
production tree is the verified parent-validation candidate; all 51 storage
tests passed after rebuilding it. The negative result remains reproducible from
its [patch](raw/bulk-inspection-many-v2/experiment.patch) against `a5eaa9a`,
[every trial](raw/bulk-inspection-many-v2/trials.jsonl),
[summary](raw/bulk-inspection-many-v2/summary.json),
[before/after intervals](raw/bulk-inspection-many-v2/before-after.json),
[checks](raw/bulk-inspection-many-v2/checks.json) and
[separate profile artifacts](raw/bulk-inspection-profile/summary.json).
