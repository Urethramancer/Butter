# CPU at common connection speeds

Exploratory: one sample per engine/rate; 5s settle, 10s measured. CPU 100% = one core. Decimal MB/s. No statistical significance or full-transfer acceptance claim.

| Mbps | Butter MB/s | CPU % | CPU s/GiB | Seed CPU % | Status | libtorrent MB/s | CPU % | CPU s/GiB | Seed CPU % | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 100 | 11.57 | 6.7 | 6.22 | 3.1 | saturated | 12.18 | 2.0 | 1.78 | 1.7 | saturated |
| 250 | 30.07 | 16.8 | 5.99 | 7.6 | saturated | 30.42 | 5.8 | 2.03 | 4.5 | saturated |
| 500 | 57.78 | 37.5 | 6.97 | 13.7 | saturated | 60.90 | 11.2 | 1.97 | 7.3 | saturated |
| 750 | 90.54 | 56.0 | 6.64 | 25.9 | saturated | 85.62 | 16.2 | 2.03 | 12.8 | saturated |
| 1000 | 116.05 | 67.5 | 6.25 | 28.3 | saturated | 116.94 | 24.5 | 2.25 | 16.2 | saturated |

All ten samples pass independent comparison of every claimed verified piece with
the fixture and partial-checkpoint reopening. All reach at least 90% of the
requested ceiling; none exceeds 110%. Butter uses 6.0–7.0 CPU seconds/GiB,
compared with libtorrent's 1.8–2.3 in these single observations.

The workload is a reusable 4 GiB, 128-file hybrid fixture with 256 KiB pieces.
Rates ran in order 500, 100, 1,000, 750, 250 Mbps; engine order alternated.
Downloaders used their normal unlimited configuration. The common libtorrent
seed applied a global upload limit with loopback explicitly included.
Counters and profilers were disabled; no builds or tests ran during measurement.
Seed CPU is reported separately above and is not added to downloader CPU.

[Raw events](raw/rate-sweep-2026-11-13/rate-sweep.jsonl),
[summary](raw/rate-sweep-2026-11-13/rate-sweep-summary.json),
[environment](raw/rate-sweep-2026-11-13/environment.json) and
[fixture manifest](raw/rate-sweep-2026-11-13/fixtures.json) are retained separately
from historical matrices. Run `Scripts/test-benchmark.sh --rate-sweep` to make
a fresh comparison. The recorded environment describes the measured harness;
subsequent edits only tidy indentation and clarify sweep output metadata/defaults.
