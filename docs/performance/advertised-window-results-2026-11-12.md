# Match the advertised queue to framed capacity — 12 November 2026

Correcting the production upload advertisement from 32 to 31 requests removes
the repeated many-file v1 seeding disconnect/reconnect stall in six fresh
measured pairs. Median verified throughput rises from 17.0 to 393.9 MB/s,
independent ratio 23.138 [22.511–23.445]. CPU through durable completion falls
from 5.843 to 5.058 seconds/GiB: 0.866 [0.841–0.886], a 13.4% reduction.
Intervals use independent median percentile bootstrap, 10,000 resamples, 95%.
Samples from different revisions are not paired.

The preceding run retained six measured Swift transfers around 63 seconds,
each with a control-limit disconnect followed by a native reset/reconnect.
The corrected run retains fourteen accepted trials: one warm-up per engine
and six balanced measured pairs. Swift's measured transfer times are 2.67–2.84
seconds, with no peer errors. Its native counterpart reports one normal
`torrent finished` notice and no reset. All independent digest and recovery-state
reopen checks passed. Neither run has been retried or overwritten.

## Correction and verification

Source `167439f` derives the advertised limit from the unchanged 512 KiB output
budget and maximum 16,384+13-byte payload frame. Thirty-two such frames need
524,704 bytes, exceeding 524,288; thirty-one fit. Per-peer admission remains
32 requests, transfer jobs remain 64, and the control-message budget remains
8,192/second. The pinned native implementation applies the received `reqq`.
The benchmark now reads the production advertisement for its metadata.

The regression test uses the real extension handshake, blocks disk admission
and submits the advertised number of full-sized requests. Before the fix, only
31 of 32 are admitted and one is charged against controls; after the fix, the
entire advertised window fits without a busy rejection. All 333 package tests
and 33 focused upload/output/resource/completion/encryption/µTP cases passed.
Its native peer preflight subsequently exposed a separate batch-cancellation
liveness failure. The error path now releases later ready pieces after an
earlier verification is interrupted. A deterministic regression, all 334 package
tests and 41 focused cases under each sanitizer pass. The initial failure remains
recorded; corrected-source native integration and new full timing are outstanding.

This is the same 1 GiB, 128-file v1 workload with 256 KiB pieces, warm sources,
fresh processes/destinations and production windows. Swift's download pipeline
remains eight; its advertisement changes from 32 to 31 in production. Native
archives, compiler and machine match the preceding run. All measured production
and harness hashes matched when archived.

## Remaining gap and memory

Native medians are 447.3 MB/s and 1.976 CPU seconds/GiB. Paired Swift/native
verified throughput is 0.878 [0.857–0.897], durable throughput 0.879
[0.857–0.897], and CPU cost 2.567 [2.471–2.623]. Both the 90% throughput floor
and 1.25× CPU ceiling remain unmet; neither interval crosses its threshold.

Whole-process Swift peak RSS is 22.50 MiB median and 23.83 MiB maximum. The
original-baseline gate passes at median ratio 0.203 [0.197–0.210], maximum
ratio 0.214. The immediate-before comparison also passes: median ratio 0.933
[0.894–0.997], maximum ratio 0.943. The original baseline remains unchanged.

The [partial matrix](cache-admission-partial-results-2026-11-12.md) retains all
117 records, including its operator-interrupted next case. This focused
correction does not establish the remaining workloads; a new full matrix is
required. No aggregate passing score, parity claim or tag is made.

## Separate profiles

Fresh Release profiles capture both engines and their counterparts for v1
download, hybrid download, many-file hybrid download and v1 seeding. All eight
profile trials pass independent validation and are labelled `profile-only`,
excluded from timing acceptance. Many-file download still shows whole-layout
file inspection and repeated directory opens; single-file downloads show opens,
writes and hashing. Seeding shows stored-byte SHA-1, copying and reads alongside
network work. Samples include idle waits and do not establish CPU percentages.
Per-phase user/system CPU remains available separately in the trial records.

## Evidence

- [Every corrected trial](raw/advertised-window-many-v1/trials.jsonl), [summary](raw/advertised-window-many-v1/summary.json), [environment/source hashes](raw/advertised-window-many-v1/environment.json), [fixtures](raw/advertised-window-many-v1/fixtures.json).
- [Before/after intervals](raw/advertised-window-many-v1/before-after.json), [all preceding and corrected Swift diagnostics](raw/advertised-window-many-v1/diagnostics.json), [incremental memory](raw/advertised-window-many-v1/memory-versus-immediate-before.json).
- [Regression failure before the fix](raw/advertised-window-regression/before-failure.log), [package and focused checks](raw/advertised-window-regression/checks.json).
- [Four-case profile records](raw/advertised-window-profiles/summary.json), [all profile trials and counterpart CPU](raw/advertised-window-profiles/trials.jsonl), [many-file Swift download sample](raw/advertised-window-profiles/many-hybrid-download-0-Swift-measured-download.sample.txt), [profile environment/source hashes](raw/advertised-window-profiles/environment.json).
- [Initial native failure](raw/ready-batch-cancellation/initial-native-results.jsonl), [reproduced peer state](raw/ready-batch-cancellation/discovery-diagnostic-failure.log), [deterministic cancellation failure](raw/ready-batch-cancellation/deterministic-before-failure.log), [corrected package/sanitizer checks](raw/ready-batch-cancellation/checks.json).
