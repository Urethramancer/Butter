# Restart verification and native disk diagnostics

All [24 restart diagnostics](raw/restart-verification/environment.json) pass
independent payload SHA-256 comparison and eager reopening. Each uses 128 pieces
of 1 MiB, with one file or 128 files, v1/v2/hybrid metadata, complete or half-missing
payload, and eager/deferred opening. Setup is excluded; every deferred check,
flush and completion snapshot is included through `durable`. These controlled
storage-policy probes are separate from managed background scheduling, which has
progressive-advertisement and paused-start tests.

| Policy / population | Bytes hashed at open | First verified piece | After 64 demanded pieces | All checks complete |
| --- | ---: | ---: | ---: | ---: |
| Eager / complete | 128 MiB | 128 MiB | 128 MiB | 128 MiB |
| Deferred / complete | 0 | 1 MiB | 64 MiB | 128 MiB |
| Eager / partial | 64 MiB | 64 MiB | 64 MiB | 64 MiB |
| Deferred / partial | 0 | 1 MiB | 64 MiB | 64 MiB |

Counts agree across both layouts and all formats. Every final snapshot has zero
pending checks and exactly 128/64 verified pieces respectively. Hybrid SHA-1 and
SHA-256 consume the same read bytes. Repeated demand does not rehash verified
pieces. Raw phase records include CPU and wall time, descriptor opens, scan/file
counts, disk jobs and I/O sizes. Other validation ran concurrently: these times
are diagnostic observations, **not timing acceptance or CPU savings**. Lazy
opening moves work to when it is needed; it does not eliminate full verification.

## Pinned native probe

The [standalone probe](../../Tests/NativeDiskDiagnostics.cpp) links the unchanged
installed libtorrent archive at revision `6da363d2994f17c0b3c0450d124cf73a31a73847`.
It uses zero disk/hasher threads to hold one cached block deterministically; these
are probe settings, not the headline reference settings. Every returned hash and
upload byte is checked. All four cases and cache cleanup pass.

| 256 KiB piece / 16 KiB blocks | Read operations | Read-back blocks | Completion callbacks | File-pool hits / misses |
| --- | ---: | ---: | ---: | ---: |
| Hybrid hash, uncached | 1 | 16 | 1 | 0 / 1 |
| Hybrid hash, one cached block | 30 | 30 | 1 | 29 / 2 |
| Upload, uncached | 16 | 0 | 16 | 15 / 1 |
| Upload, one cached block | 15 | 0 | 16 | 14 / 1 |

The partial hybrid fallback reads each of 15 missing blocks twice: 480 KiB instead
of 240 KiB. SHA-1 and SHA-256 match. The uncached path already reads once and
hashes both algorithms from that buffer. The extra partial-case file-pool miss
and race counter include the cache write/flush, not just hash reads.

Source inspection explains the upload counts: each request allocates a read job,
consults the cache after fences, obtains a send buffer and schedules completion.
A cache hit copies into its send buffer. File-pool lookups acquire its mutex;
the counters measure lookups, not lock duration or allocator churn. Swift's
immutable checked whole-piece cache avoids repeated disk loading and hashing for
its block requests; it still performs protocol/output work. Profiles and timing
comparisons are needed to quantify the net advantage.

## Probe failures and provenance

The installed archive exposes Boost 1.92's `execution_context` ABI, although the
cached Apple-build flags name Boost 1.88. Directly constructing that context with
1.88 headers crashed; matching headers alone then exposed allocation/deallocation
toolchain incompatibility during cleanup. Matching the LLVM compiler and Boost
headers resolved both. A final probe error was its rejection of the expected
cancelled write when discarding the intentionally dirty cache; explicit cleanup
now handles that cancellation. [Failed outputs](raw/native-disk-diagnostics/)
remain alongside successful counts, with no failed sample replaced.

The reference archive and acceptance binaries were not rebuilt or patched for
this investigation. Earlier benchmark records include their exact archive hashes,
which remain the comparison anchor; cached build flags alone do not establish
the installed archive's compiler/Boost provenance. Reproduction must retain this
qualification rather than claim the old flags conclusively describe the archive.
