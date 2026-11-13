# Verification and repair candidate profiles

All eight diagnostic trials validate independent digests and saved-state
reopening: both engines, single-file v1 download/seeding, single-file hybrid
download and many-file hybrid download. No tests or other builds ran alongside
the captures. Counters and two-second `sample` captures are diagnostic only;
acceptance timing runs have counters disabled.

| Swift workload, 1 GiB | Files inspected | Descriptor opens | Disk jobs | Payload bytes read / hashed |
| --- | ---: | ---: | ---: | ---: |
| Single v1 download | 83,870 | 14,236 | 14,114 | 1 GiB / 1 GiB |
| Single hybrid download | 83,823 | 14,189 | 14,066 | 1 GiB / 1 GiB |
| Many hybrid download | 107,468 | 108,591 | 12,575 | 1 GiB / 1 GiB |
| Single v1 seeding | 8,193 | 4,097 | 4,097 | 1 GiB / 1 GiB |

Many-file inspected leaves fall 90.6% from the earlier 1,147,763 diagnostic;
scans remain similar (16,857 versus 16,899), as do descriptor opens and disk jobs.
The gain is narrower inspection, not removing integrity checks. Hybrid hashes
both consume the same 1 GiB of stored bytes. Checkpoint bytes remain included
in write counters, separately from payload verification.

Seeding loads each 256 KiB piece once, using four bounded 64 KiB reads per piece,
and retains immutable checked bytes for its sixteen 16 KiB block requests.
There are 4,096 piece jobs plus one checkpoint job. The 396 recorded cache hits
exclude requests coalesced into an already-running load; they are not the total
number of requests benefiting from reuse. Newly loaded disk pieces are still
hashed. The native probe separately demonstrates sixteen upload jobs/read
operations and callbacks for an uncached piece.

The many-file Swift sample still shows substantial `openat`/`close` activity
(377/280 top-of-stack observations), followed by payload writes and both hash
compression routines. These wall-sampling stacks include waiting threads and
omit symbols below five observations from their collapsed summary; they are
not Running-sample CPU percentages. Native samples retain their file-pool,
cache, allocation and completion-scheduling stacks. Do not infer allocator churn
or lock duration from function appearance alone.

[Phase records](raw/repair-final-profiles/trials.jsonl),
[aggregated counts and collapsed stacks](repair-final-profiles-2026-11-13.json)
and [environment fingerprints](raw/repair-final-profiles/environment.json) are
retained. Full raw sample text remains in
`.build/benchmarks/repair-final-profiles-20261113`, with a committed
[SHA-256 manifest](raw/repair-final-profiles/sample-manifest.json).
The installed-reference ABI provenance qualification in the
[native probe findings](restart-and-native-diagnostics-2026-11-13.md) applies.
