# Revised ready TCP request bursts

Candidate `93a41c8` restores original scalar output admission while retaining
bounded ready-request bursts. Baseline is `ec966eb`. These measurements belong
to the revised source; the first form's seeding RSS regression remains recorded.

Each case uses four warm-ups and six balanced source/engine pairs, production
windows, fresh processes/destinations and explicitly warm source files. All
56 trials pass independent payload digests and saved-state reopening; none is
retried or replaced. Ratios below are revised/previous, with 95% paired median
bootstrap intervals.

| Case | CPU/GiB | Verified throughput | Peak RSS | Counterpart CPU/GiB |
| --- | ---: | ---: | ---: | ---: |
| Single-file v1 download | 0.917 [0.907–0.927] | 1.037 [1.024–1.055] | 0.996 [0.984–1.006] | 0.914 [0.857–0.960] |
| Many-file v1 seeding | 1.002 [0.991–1.051] | 0.959 [0.831–1.052] | 1.029 [0.966–1.079] | 0.995 [0.985–1.040] |

Single-file download CPU falls 8.3% and throughput rises 3.7%; counterpart CPU
falls 8.6%. RSS remains inconclusive. Raw Swift medians are 4.042 → 3.716 CPU
seconds/GiB and 322.5 → 333.7 MB/s. Revised/native paired CPU is 1.988
[1.959–2.205] and throughput 0.748 [0.738–0.757]. Native controls cross one.

Seeding establishes neither improvement nor regression. Its wide intervals
do not prove the first form's RSS cost is resolved. Revised/native paired CPU
is 2.301 [2.223–2.602] and throughput 0.810 [0.656–0.915]. Native controls also
cross one. No cost-free or parity claim is made. Many-file and concurrent
download comparisons, native validation and the final full matrix remain open.

The seeding wrapper's tool handle was lost before observation of finalisation.
Subsequent inspection finds its normal summary, final success log message and
no remaining worktree. This supersedes the earlier interruption diagnosis;
the reconstructed statistics match the normal summary. No wrapper exit status
was observed for that run. The single-file wrapper exits successfully.

[Summaries and raw artifact hashes](request-burst-revised-comparison-2026-11-13.json)
preserve both cases under `.build/benchmarks/request-burst-scalar-*`.
