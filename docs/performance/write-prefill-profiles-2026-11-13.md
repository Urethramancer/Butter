# Write-refill Release profiles

Both engines' four fresh Time Profiler cases validate independent payload
digests and saved-state reopening: eight accepted diagnostic trials. All 94
Swift source hashes match the completed full matrix. Captures are separate
from timing acceptance and cover the entire transfer through durable completion.

| Swift workload | Running samples | fstatat/openat/close, flat | Write operations, inclusive | Layout scans, inclusive |
| --- | ---: | ---: | ---: | ---: |
| Many-file hybrid download | 8,661 | 43.9% | 45.7% | 35.5% |
| Single-file v1 download | 4,020 | 21.3% | 33.0% | 2.5% |
| Single-file hybrid download | 4,731 | 17.9% | 26.6% | Below reported top symbols |
| Single-file v1 seeding | 2,447 | 4.2% | Not on this path | 2.3% |

Inclusive percentages overlap. Swift unavailable backtraces are 1, 38, 27 and
0 respectively. Native has 2,568/1,763/2,391/1,566 Running samples and
124/303/9/0 unavailable backtraces; unavailable samples remain in denominators.
The v1 native download's 17.2% unavailable backtraces limit detailed attribution.
No capture is retried or omitted.

Many-file instrumented whole-process CPU is Swift 3.60 user/5.25 system
seconds and native 1.54/1.12; these include setup/shutdown and are not timing-run
CPU/GiB estimates. The other instrumented process measurements remain in JSON.
Swift SHA-1/SHA-256 compression statistical weights are 0.440/0.455 seconds;
native weights are comparable. Single-file v1/hybrid show material filesystem
and scheduling contributions, while Swift seeding retains a visible
stored-byte hashing cost. Sample weights are not measured function durations.
Thread-entry trampolines do not prove thread creation; these profiles do not
justify a timer rewrite or weakening hashing/ownership checks. Copies appear
in the flat profiles, but their cost does not explain the many-file gap.

## Filesystem diagnostic

A separate File Activity/Time Profiler pair also validates. Its requested
trailing one-second window exports measured syscall spans of 0.391 seconds
for Swift and 1.053 seconds for native; these are partial, unequal captures.
Table coverage omits some calls, including Swift openat/close and native pwritev,
so counts are not exhaustive or directly comparable between engines.

Within Swift write contexts, 2,383 16 KiB writes accompany 321 inferred
metadata-scan sections, versus 1,729 writes/436 sections before either refill
change: 7.42 versus 3.97 writes per section. All selected backtraces resolve.
The new write-side full-layout stat count is 41,088 (321 × 128). Sections are
inferred from per-thread backtrace transitions, not proven job counts; creation
refresh scans and capture boundaries can add sections. These diagnostics are
consistent with fuller batches within the existing eight-request window, not
a whole-transfer call-count or throughput estimate.

The next optimisation should target repeated filesystem inspection/opening and
the remaining disk scheduling costs. The reader now supplies substantially
fuller batches; increasing request windows or caches is not justified by this
result. Earlier parent-retention, bulk-scan, UTF-8/C-string and verified-read
experiments remain rejected; the profiles do not reverse their measured costs
or null results.

[Attribution, process measurements, syscall counts and raw hashes](write-prefill-profiles-2026-11-13.json)
retain evidence. Raw traces remain in the four
`.build/benchmarks/write-prefill-profile-*` directories and
`.build/benchmarks/write-prefill-file-activity`.
