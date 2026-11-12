# Queued verified-read coalescing experiment

Rejected and reverted. Six balanced many-file v1 seeding source pairs show
current/previous CPU 1.001 [0.992–1.012], verified throughput 0.991
[0.977–1.015] and whole-process peak RSS 1.033 [0.974–1.068]. Intervals are
95% paired median percentile bootstrap, 10,000 resamples. Neither CPU nor
throughput establishes reproducible benefit; original-baseline memory passes.

The prototype coalesces consecutive reads already queued for one storage owner,
freezing a batch before execution. Every request still consumes its own slot
in the unchanged eight-owner/64-global command budget. Intervening commands
separate batches; duplicate piece requests do not join the same batch. Payload
bytes are bounded by the existing 16 MiB single-piece maximum. Each piece is
hashed from storage with its independent cancellation check, and full-layout
stamps are checked before all reads and after all hashes before returning data.
No descriptor, payload or checkpoint cache is added. This result does not
establish why queue-level coalescing fails to help the measured workload.

Production logic `61584b7` plus the inert queue-count diagnostic and baseline
tests in `9c1b7ec` is compared with that revision plus `rejected.patch`. The
patch includes the prototype-specific tests and added source file. Both Release
packages use identical driver source and one pinned native binary in all roles.
Builds precede timing. The fixture is 128 equal files totalling 1 GiB, v1,
256 KiB pieces, warm source files and fresh processes/destinations. Four warm-ups
precede six balanced source pairs. All 28 trials pass independent payload
digests and saved-state reopening, with receiver-verified upload completion.
This fixed source diagnostic does not replace full-matrix acceptance.

Swift medians are 4.155 → 4.130 CPU s/GiB through durable completion and
385.5 → 383.8 verified MB/s; these marginal medians do not replace the paired
ratios above. Native control CPU is 1.019 [0.948–1.043], throughput 1.001
[0.998–1.009], and counterpart CPU 1.003 [0.993–1.023]. Every phase and peer
diagnostic remains in raw records. CPU parity remains unmet.

The candidate passes all 59 storage tests, a complete 349-test package run,
and 105 focused tests under each sanitizer. Deterministic tests cover
independent cancellation, corruption, full-layout changes, selective storage,
padding, queue admission and intervening writes. The first full-package run
fails across unchanged network fixtures with bind errors and timeouts; its log
is retained. No leftover test child is found afterward and the TCP table is not
exhausted. Fifteen isolated network tests, the second complete run and the
restored scheduler's complete 347-test run pass. The original bind failure's
cause remains unresolved. Initial fixture and compile corrections are also
retained explicitly; no failed performance trial is retried or removed.

No scheduling change survives. Public cancellation/order/admission tests remain,
including no-cancellation and selective-storage cases. The internal queue-count
getter supports those deterministic tests and does not change scheduling.
Prototype-only tests are preserved with the rejected patch. Raw results, exact
source hashes, all failed logs and checks are in
[`raw/verified-read-batches`](raw/verified-read-batches).
