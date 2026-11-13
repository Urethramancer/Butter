# Ordered CPU experiments

## 1. Bounded reordering and sequential proofs — rejected

An accepted-block metadata trace covered 3,138 complete 256 KiB pieces in the
500 Mbps, 128-file hybrid diagnostic. The offline model used 256 KiB per
transfer, 1 MiB per session, eight contexts and a 10 ms deadline. Potential
sequential-proof coverage rose from 179 to 3,128 pieces (5.7% to 99.7%); peak
buffered payload was 208 KiB. Thirty-one blocks reached their deadline; none
required a capacity flush. Mean simulated wait was 0.025 ms, maximum 10 ms.
The trace remains local, with its fingerprint in the recorded result.

The implementation shared bounded admission across peers and web seeds, copied
only accepted payload into charged buffers, retained picker contributors and
advanced proofs only after guarded writes. It kept disk admission outside
network waits and drained/cancelled work through shutdown and repair. Proof
contexts shared the session's 1 MiB ceiling, including digests and observations.
Explicit verification and unsupported/invalidated proofs used stored bytes.

The separate operation-count run authenticated 3,099 of 3,110 checks through
proofs (99.65%), with 2.75 MiB readback and 160 KiB peak buffered payload.
Received-proof hashing covered 813,842,432 bytes, of which 812,384,256 bytes
supported successful proofs. These instrumented runs are not timing evidence.

Serial checks passed 83 storage and 190 engine tests, 48 bidirectional native
TCP fixtures, focused Address Sanitizer and Thread Sanitizer suites, and final
assembler deadline/contributor checks under both sanitizers. Earlier cancellation
and repair-draining failures were corrected before timing; their logs remain
local. No test deadline or integrity assertion was relaxed.

All four warm-ups and 24 measured samples validated their partial payloads and
reopened checkpoints. Three native controls missed the unchanged 90% saturation
gate. Lower Swift CPU was also not established: descriptive current/previous
CPU/GiB ratio 1.029 (95% paired interval 0.974–1.078). This is not a qualified
retention inference. The candidate was reverted without another timing run;
there are no focused follow-up comparisons for this rejected candidate.

[Raw results, source fingerprints, validation results and candidate patch](raw/cpu-phases/)
are retained. Full build/test logs and the original receive trace remain in
`.build/experiments/cpu-phases/`. User Xcode edits were preserved.
