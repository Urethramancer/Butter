# Current candidate CPU profiles — 12 November 2026

Production `5b9ef12` completes all eight standard four-workload Time Profiler
trials, plus four focused trials for the two seeding regressions. Both roles
pass independent payload digest and saved-state reopen in every trial. The
tested process is attached while both drivers wait at ready, and an Instruments
notification gates start. The counterpart is not instrumented but retains phase
accounting. Recording stops after durable completion. No production change,
build or timing run occurs alongside an active capture.

These are single instrumented pairs, excluded from timing acceptance. Weights
describe Running samples, not exact CPU durations; inclusive symbols overlap.
Unavailable backtraces remain in the denominator. The largest unavailable share
is 7.5% in native single-file v1 download; Swift's maximum is below 0.1%.

| Swift workload | Running samples | Measured CPU paths |
| --- | ---: | --- |
| Single v1 download | 3,132 | SHA1 compression 14.8% flat; `pwrite` 10.4%; `close` 7.1%; memory movement 6.4%. |
| Single hybrid download | 3,422 | SHA1 13.9% and SHA256 13.6% flat; `pwrite` 8.8%; memory movement 7.1%. |
| Many-file hybrid download | 6,521 | Stamp scans 34.5% inclusive; `fstatat` 21.9% and `openat` 15.6% flat. |
| Single v1 seed | 3,186 | SHA1 14.3% flat; global task enqueue 6.0% inclusive; scheduling/system transition frames remain prominent. |
| Many-file v1 seed | 4,837 | Stamp scans 32.8% inclusive; `fstatat` 20.4% and SHA1 9.9% flat; task enqueue 4.8% inclusive. |
| Concurrent v2 seed | 3,465 | SHA256 13.6% and memory movement 7.6% flat; shared piece-cache calls 3.6% inclusive. |

Native download profiles concentrate roughly 32% of v1 or 39–40% of hybrid
sample weight in hashing, alongside receives and vector writes. Native seeding
retains reads, sends and synchronisation. All raw native exports and summaries
remain alongside Swift's.

## What the regressions establish

The full timing matrix records a 5.1% CPU increase and 23.5% throughput loss in
many-file v1 seeding, and a 20.0% throughput loss with lower CPU in concurrent
v2 seeding. These profiles identify current costs but do not establish why the
losses occurred. Their instrumented throughput is not a replacement sample and
is not used to dismiss either regression.

For many-file v1 Swift seeding, through-durable median wall time rises from
2.752 to 3.597 seconds across the full matrices. Marginal user CPU medians rise
2.386 to 2.489 seconds and system medians 2.658 to 2.818. The native receiver
counterpart rises from 2.754 to 3.599 seconds wall, 0.699 to 0.730 user and
0.803 to 0.910 system. In native-to-native trials, tested-seed wall time remains
2.395 versus 2.365 seconds while its CPU medians change. Different CPU changes
in the two roles make an unsupported attribution to one production change
especially inappropriate.

For concurrent v2 Swift seeding, through-durable wall rises 1.107 to 1.378
seconds while marginal user/system CPU medians fall 2.503/1.522 to 2.408/1.169.
Receiver counterpart wall rises 1.397 to 1.524 seconds. These are independent
per-phase medians; component medians must not be summed as exact total CPU.

Both regressions remain open. A controlled source comparison is needed before
attributing them to the larger request default or another retained change.
Filesystem checks, stored-byte hashing, cancellation and all resource caps stay
in place. No parity or release claim is made.

- [Standard trials](raw/window31-cpu-profiles/trials.jsonl),
  [environment](raw/window31-cpu-profiles/environment.json),
  [checks/XML hashes](raw/window31-cpu-profiles/checks.json).
- [Many-file v1 seeding trials](raw/window31-many-v1-seed-profile/trials.jsonl),
  [environment](raw/window31-many-v1-seed-profile/environment.json),
  [checks/XML hashes](raw/window31-many-v1-seed-profile/checks.json).
- [Concurrent v2 seeding trials](raw/window31-concurrent-v2-seed-profile/trials.jsonl),
  [environment](raw/window31-concurrent-v2-seed-profile/environment.json),
  [checks/XML hashes](raw/window31-concurrent-v2-seed-profile/checks.json).
- [Full timing matrix](window31-full-results-2026-11-12.md),
  [phase and counterpart accounting](raw/window31-full/phase-accounting.json),
  [preceding full phase accounting](raw/framed-window-full/phase-accounting.json).
