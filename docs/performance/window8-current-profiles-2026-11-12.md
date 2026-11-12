# Current eight-request CPU profiles

All eight prescribed captures validate independent digests and saved-state
reopening: both engines in v1 download, v1 seeding, hybrid download and many-file
hybrid download. All 94 production source hashes match the restored candidate.
The earlier Instruments failures remain; the fixed-case recheck succeeds with
unchanged deadlines after host load improves. These instrumented results are
diagnostic, not throughput/CPU acceptance measurements.

| Case | Leading Swift costs |
| --- | --- |
| V1 download | Write operations 31.5% inclusive; flat open 9.2%, close 6.3%, write 10.1% |
| Hybrid download | Write operations 29.0%, piece digest 24.9% inclusive |
| Many-file hybrid download | Stamp scanning 40.0%, write operations 51.7% inclusive; flat stat 24.3%, open 16.1% |
| V1 seeding | Verified-piece read 39.4%, output writer 9.9%, send/enqueue 6.4% inclusive; flat SHA1 17.6%, copying 5.4% |

Analysis uses Running samples for the tested PID only. Inclusive fractions
overlap; sampled weights are not measured function durations. Missing backtraces
reach 5.9% for native and 0.15% for Swift, retained in the denominator. Kernel
trampolines do not establish thread creation cost. Counterpart measurements
remain separate, and every case uses fresh processes and warm source data.

An isolated allocation probe using actual piece-frame encoding retains about
20% less wire-buffer footprint when frames are grouped. It uses six fresh
processes per mode and validates frame boundaries. This is not evidence of an
application memory or CPU gain. It supports testing owned wire buffers for
already-available uploads; verified-piece slices must not pin unaccounted cache
memory. Output credits, cancellation, framing and existing limits must remain.

[Compact profiles and raw-export hashes](window8-current-profile-summary-2026-11-12.json)
retain both engines' accounting and leading symbols. Raw data remain in
`.build/benchmarks/window8-profiler-recheck`, `window8-seed-profiles` and
`window8-hybrid-profiles`. The isolated probe source, raw records and summary
remain in `.build/diagnostics/piece-buffer/wire-buffer-footprint-*`.
Full timing and the unresolved native interoperability failure remain open.
