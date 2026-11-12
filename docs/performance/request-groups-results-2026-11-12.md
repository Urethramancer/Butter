# Available request dispatch over grouped upload workers

Rejected and reverted. Six balanced many-file v1 seeding source pairs give
current/previous CPU 1.005 [0.994–1.016], verified throughput 1.010
[0.985–1.044] and whole-process peak RSS 0.995 [0.945–1.053]. These are 95%
paired median percentile bootstrap intervals with 10,000 resamples. Neither
CPU nor throughput establishes reproducible benefit. Original-baseline and
incremental memory comparisons pass.

The candidate gathers at most 32 request frames already decoded from one
available network read and dispatches them in one actor call. It flushes before
control/piece frames, scheduler yields and the next network wait. Each request
still delegates to the existing receive/admission handler. Independent upload
tokens, grouped payload workers, queue limits, hashing and filesystem checks
remain unchanged. The queued storage coalescer was reverted before this trial;
the two standalone experiments are not combined or averaged.

Baseline revision `fa9b0fb` contains production logic `61584b7` and the retained
queue diagnostics/tests. The candidate adds only `rejected.patch`. Both Release
packages link identical driver source and use one pinned native binary for all
reference/counterpart roles. Builds finish before timing. The case is 128 equal
files totalling 1 GiB, v1, 256 KiB pieces, warm sources, and fresh processes and
destinations. Four warm-ups precede six balanced source pairs. All 28 trials
pass independent payload digests and saved-state reopening. Upload completion
is receiver-verified. This fixed diagnostic does not replace full acceptance.

Swift medians are 4.128 → 4.163 CPU s/GiB through durable completion and
382.8 → 383.7 verified MB/s. Native control CPU is 0.990 [0.971–1.035],
throughput 1.003 [0.999–1.010], and counterpart CPU 1.005 [0.989–1.025].
Marginal medians do not replace the paired ratios above. Full phase, process,
counterpart and peer-diagnostic records remain in the raw artifacts.

The candidate passes all 347 serial package tests and all 53 focused transfer,
admission, request/control ordering, output, encryption and µTP tests under
each sanitizer. The restored source also passes the complete 347-test package
run. No production dispatch change survives. Raw source hashes, fixtures,
measurements, checks and patch are in [`raw/request-groups`](raw/request-groups).

After restoration, every package source hash matches the baseline manifest.
The Release package is rebuilt, and current Debug/Release storage and engine
archives contain no symbols from either rejected prototype. Archive hashes and
the restoration checks are retained with the raw evidence.

The earlier request-loop prototype predated grouped payload workers; this
experiment tests the changed ownership context rather than substituting its
old measurement. Both results remain. A future explicit multi-piece read API
could share filesystem guards without depending on incidental queue timing;
that remains an unimplemented hypothesis, not a performance claim.
