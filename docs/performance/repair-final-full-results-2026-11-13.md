# Lazy verification and repair: full transfer matrix

All 264 trials validate, including warm-ups and the twelve-pair extension for
concurrent v1 seeding. Throughput passes 11/18 cases, CPU 0/18 and memory 18/18
against the original fresh Swift baseline. No parity claim is justified.
Counters and profilers were disabled; builds and tests did not run alongside timing.

Ratios below are Swift/libtorrent. Throughput targets at least 0.90, CPU/GiB
through durable completion at most 1.25. The raw summary retains paired 95%
intervals and memory gates; every case has a resolved pass/fail interval.

| Layout | Format | Direction | Throughput | CPU/GiB | Pairs |
| --- | --- | --- | ---: | ---: | ---: |
| single | v1 | download | 0.660 | 2.059 | 6 |
| single | v1 | seed | 1.293 | 1.510 | 6 |
| single | v2 | download | 0.677 | 2.073 | 6 |
| single | v2 | seed | 1.332 | 1.561 | 6 |
| single | hybrid | download | 0.591 | 1.738 | 6 |
| single | hybrid | seed | 1.380 | 1.799 | 6 |
| many | v1 | download | 0.495 | 2.399 | 6 |
| many | v1 | seed | 1.157 | 1.311 | 6 |
| many | v2 | download | 0.512 | 2.489 | 6 |
| many | v2 | seed | 1.177 | 1.473 | 6 |
| many | hybrid | download | 0.438 | 2.047 | 6 |
| many | hybrid | seed | 0.815 | 1.676 | 6 |
| concurrent | v1 | download | 1.268 | 2.188 | 6 |
| concurrent | v1 | seed | 1.782 | 1.423 | 12 |
| concurrent | v2 | download | 1.270 | 2.149 | 6 |
| concurrent | v2 | seed | 1.783 | 1.597 | 6 |
| concurrent | hybrid | download | 1.235 | 1.782 | 6 |
| concurrent | hybrid | seed | 1.652 | 1.730 | 6 |

Many-file hybrid download is the weakest throughput case: 0.438× reference
throughput and 2.047× CPU/GiB. Many-file v2 download has the largest CPU ratio,
2.489×. These results prioritise download filesystem overhead for the next
independent optimisation experiment. They do not attribute differences between
separate full runs to individual source changes.

All trials use production windows, independent streaming digests and saved-state
reopening. Reference revision, archive and binary fingerprints remain pinned.
The [installed-reference provenance qualification](restart-and-native-diagnostics-2026-11-13.md)
still applies. [Raw trials](raw/repair-final-full/trials.jsonl),
[summary](raw/repair-final-full/summary.json),
[environment](raw/repair-final-full/environment.json) and
[fixtures](raw/repair-final-full/fixtures.json) preserve the evidence.
