# Controlled seeding source comparison — 12 November 2026

The full matrices recorded many-file v1 seeding CPU +5.1% and throughput −23.5%,
and concurrent v2 seeding throughput −20.0% despite lower CPU. A new diagnostic
in the existing benchmark entry point compares production `1931e70` and
`5b9ef12` contemporaneously. Production code is unchanged by this investigation.

Both Release engines are built before timing. The same current driver source
is linked against each package; one identical pinned native binary supplies all
counterparts and native control trials. The previous source is built in a
disposable detached worktree, removed after successful child cleanup. Recorded
source/package hashes, driver hashes and ready events identify the actual
engines: previous pipeline eight, current pipeline 31.

Each case uses one warm-up per engine per source, then a fixed six balanced,
reproducibly shuffled source-order pairs. Within each source block, Swift/native
engine order is also balanced. A source pair contains four fresh-process trials.
Sources are streamed warm, destinations and state fresh, with independent digest
and state-reopen checks. All 56 trials pass. Source-prefixed IDs keep every
sample separate; no result is retried or replaces an original full-run sample.

## Paired current/previous results

Intervals are paired median percentile bootstrap, 10,000 resamples, 95%. A ratio
below one means lower CPU/RSS or lower throughput, respectively. Intervals that
cross one are inconclusive; this diagnostic does not infer full acceptance.

| Workload | CPU s/GiB previous → current | CPU ratio [95%] | MB/s previous → current | Throughput ratio [95%] |
| --- | ---: | --- | ---: | --- |
| Many-file v1 seed | 5.090 → 5.078 | 0.995 [0.984–1.005] | 388.2 → 387.7 | 1.005 [0.990–1.034] |
| Concurrent v2 seed | 3.561 → 3.613 | 1.008 [0.994–1.041] | 813.8 → 803.5 | 0.997 [0.970–1.002] |

Neither large full-run loss reproduces as a source effect in these paired
conditions. The intervals exclude losses of the original magnitudes. This is
not proof of identical performance or an explanation of the original losses;
sequence, environment and runtime variation remain unisolated possibilities.
The original full matrices, their uncertainty intervals and regression entries
remain unchanged.

Both revisions pass memory against the original fresh baseline. Paired
current/previous whole-process RSS is 1.018 [0.986–1.040] for many-file v1 and
1.031 [1.008–1.047] for concurrent v2. The latter modest increase is retained
explicitly. Native-counterpart CPU ratios are 0.990 [0.984–1.007] and
1.011 [0.997–1.036]. Native-to-native control throughput ratios are
1.001 [0.992–1.009] and 1.000 [0.990–1.004]; their CPU intervals also cross one.

Neither revision meets the CPU target in either diagnostic case. The latest
full matrix still records CPU 0/18, throughput 9/18 and memory 18/18. No gate or
sample is relaxed. Further work should target the measured filesystem/hash and
scheduling costs, while keeping the sequence-dependent regression question open.

## Harness verification and evidence

Sixteen harness tests with 105 assertions pass. Added coverage proves source and
engine order balance, one native command for both source labels, paired CPU/byte
and RSS accounting, failed/duplicate native trials, failed warm-ups and separate
raw failure records. Existing phase/deadline/counterpart/child cleanup tests pass.
Both real engine builds, 56 transfers and worktree removal also pass.

- [Every trial](raw/seeding-source-order/trials.jsonl),
  [paired ratios and per-source native comparisons](raw/seeding-source-order/summary.json),
  [environment, revisions and fingerprints](raw/seeding-source-order/environment.json),
  [fixtures](raw/seeding-source-order/fixtures.json),
  [verification and cleanup](raw/seeding-source-order/checks.json).
- [Full current matrix](window31-full-results-2026-11-12.md),
  [preceding full matrix](framed-window-results-2026-11-12.md),
  [source-matched CPU profiles](window31-profiles-2026-11-12.md).

Run `Scripts/test-benchmark.sh --compare-source OUTPUT`; optionally set
`BUTTER_BENCHMARK_PREVIOUS_REVISION`. This fixed-sampling diagnostic remains
separate from the ordinary `--full` acceptance and extension policy.
