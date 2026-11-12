# Parent descriptor borrowing experiment

Rejected and reverted. Six balanced source pairs show no reproducible benefit:
current/previous CPU is 1.004 [0.984–1.015], verified throughput 1.006
[0.979–1.028], and peak RSS 1.002 [0.990–1.027]. Intervals are paired median
percentile bootstrap, 10,000 resamples, 95%. No performance gate is relaxed.

The experiment borrowed the anchored root descriptor through a synchronous
callback with `withExtendedLifetime`, rather than duplicating and closing it
for each parent traversal. Descendant opens and all file checks remained.
The tested source is `6d82236` plus the archived `rejected.patch`, against
production `5b9ef12`. Both use a 31-request production window. The identical
current driver source is linked against both packages; one pinned native binary
serves all reference and counterpart roles. Builds finish before measurement.

All 28 trials (four warm-ups and 24 measured) pass digest and state reopening.
The case is one 1 GiB v1 download with 256 KiB pieces, warm source files and
fresh processes/destinations. This fixed six-pair source diagnostic does not
replace the full acceptance matrix. Swift medians are 3.265 → 3.283 CPU s/GiB
through durable completion and 381.0 → 386.7 verified MB/s. Native control
CPU/throughput intervals cross one. Both variants pass original-baseline memory.

Before measurement, the candidate passes 53 storage tests, all 341 package
tests serially, and eight Release layout tests. The previously committed
callback lifetime/error contracts remain useful and are retained. No production
change survives this experiment. Raw environment, source/driver hashes, fixture
hashes, trials, summary, checks and rejected patch are in
[`raw/parent-anchor`](raw/parent-anchor).
