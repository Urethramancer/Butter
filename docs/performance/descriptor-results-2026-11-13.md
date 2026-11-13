# Download descriptor diagnostics

The current many-file hybrid diagnostic validates both engines. During Swift's
1 GiB start-to-durable interval it records 95,603 directory opens, 12,852 file
opens, 66 atomic-state opens and 112,509 descriptor duplications. Open counters
count attempts; duplications are separate. Their sum matches the existing
108,521-open total. Across 8,454 write batches and 65,536 blocks, the existing
bounded payload cache records 56,967 hits. Filesystem overhead is primarily
repeated directory traversal, not an absent payload-descriptor cache.

[Raw profile and counters](raw/descriptor-baseline-profile/counts.json),
[phase records](raw/descriptor-baseline-profile/trials.jsonl) and
[environment](raw/descriptor-baseline-profile/environment.json) are retained.
Full sample text remains in `.build/benchmarks/descriptor-baseline-profile-20261113`,
with its [manifest](raw/descriptor-baseline-profile/sample-manifest.json).
Diagnostic runs do not support timing claims.

## Rejected root-descriptor borrowing

Candidate `d08e756` versus `4ac2916` removed root duplication and its matching
close while preserving all descendant opens and leaf checks. All 28 balanced
source/engine trials validate independent digests and saved-state reopening.
Counters/profilers were disabled, with no concurrent tests or builds.

| Current/previous | Median | 95% interval |
| --- | ---: | ---: |
| cpu_seconds_per_gib | 1.0130 | 0.9849–1.0292 |
| verified_bytes_per_second | 0.9852 | 0.9507–1.0154 |
| peak_rss | 1.0671 | 0.9773–1.0896 |
| counterpart_cpu_seconds_per_gib | 0.9804 | 0.9279–1.0507 |

Every interval includes one. There is no established benefit or regression;
the experiment is reverted rather than retained as a speed-up. Native controls
also include one. [All raw samples](raw/borrowed-root-source/trials.jsonl),
[summary](raw/borrowed-root-source/summary.json) and
[environment](raw/borrowed-root-source/environment.json) remain.

Before measurement, all 385 package tests, 77 storage tests under each sanitizer
and 67 native filesystem checks pass, including recovery, ENOSPC and read-only
storage. Logs remain under `.build/borrowed-root-*`. The initial diagnostics test
invocation omitted the repository's serial setting: process-wide descriptor
assertions and shared disk admission failed. The complete failure log remains
at `.build/descriptor-diagnostics-tests.log`; the prescribed serial run passes
all 77 storage tests. No failing measurement has been replaced.

## Rejected parent reuse after scoped verification

Retested bounded immediate-parent reuse against the current scoped-verification
source. The [original attempt](write-parent-results-2026-11-13.md) remains rejected
and its evidence is unchanged. New evidence is the 90.6% reduction in inspected
leaves, directories accounting for 88% of remaining opens, and the unsuccessful
root-duplication experiment. This changes the measured cost balance; it is not
proof that retention now helps. Keep full parent-stamp/effective-access checks,
per-block leaf identity checks, eight payload slots and existing job limits.

Candidate `bf7b252` versus `a30e41e` again validates all 28 balanced trials.
Directory opens fall from 95,603 to 30,377 in the separate diagnostic, but it
adds 74,318 parent inspections and 65,395 effective-access checks.
The [new diagnostic counts](raw/scoped-parent-profile/counts.json) retain this
replacement work; [raw phases](raw/scoped-parent-profile/trials.jsonl) and the
[sample manifest](raw/scoped-parent-profile/sample-manifest.json) preserve both
engines. Full sample text remains in `.build/benchmarks/scoped-parent-profile-20261113`.

| Current/previous | Median | 95% interval |
| --- | ---: | ---: |
| cpu_seconds_per_gib | 0.9602 | 0.9021–1.0125 |
| verified_bytes_per_second | 1.0535 | 0.9913–1.1171 |
| peak_rss | 1.0036 | 0.9730–1.1008 |
| counterpart_cpu_seconds_per_gib | 0.9570 | 0.8369–1.1034 |

All source intervals include one, so the candidate is reverted. Native-control
CPU also shifts down (0.9905, interval 0.9819–0.9946), reinforcing the need for
balanced controls and caution. It is not evidence that Swift became faster.
No counters, profilers, other builds or tests ran during timing. All 77 storage
tests pass before measurement. [Raw trials](raw/scoped-parent-source/trials.jsonl),
[summary](raw/scoped-parent-source/summary.json) and
[environment](raw/scoped-parent-source/environment.json) retain the new evidence
separately from the original parent-cache rejection. No samples were replaced.
