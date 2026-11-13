# Remaining audit and acceptance checks

## TCP performance parity

- Resolve remaining grouped upload performance uncertainty and reduce repeated
  full-layout write inspection. Fresh profiles validate eight diagnostic trials:
  many-file filesystem calls are 45.1% flat and layout scans 33.5% inclusive.
  The full matrix validates all 264 trials: throughput passes
  nine cases, fails eight and remains inconclusive in many-file v1 seeding after
  twelve pairs; CPU passes 0/18 and original-baseline memory 18/18. Many-file v1
  download source CPU 0.995 [0.952–1.030] does not reproduce its 6.2% cross-run
  rise; source metrics remain inconclusive and the original difference remains.
  Single-file v1 seeding CPU
  falls 4.7%; many-file CPU falls 4.6%, throughput
  rises 1.2% and counterpart CPU falls 1.9%; concurrent hybrid CPU falls 3.4%
  across 196 validated trials including four download regression
  checks. Single-file download RSS falls 0.3%; other download changes are
  inconclusive. Preserve
  inconclusive source intervals, especially RSS and the wide single-file memory
  interval rather than claiming no cost. Package/sanitizer checks, native
  interoperability (466 PASS records), application/recovery and Debug/Release
  build/linkage/licence/repeat-build checks pass.

- Resolve revised request-burst source RSS/seeding uncertainty and reduce the
  remaining CPU gap. The full matrix validates all 252 trials, passing throughput
  9/18, CPU 0/18 and original-baseline memory 18/18. Revised single-file download
  saves 8.3% CPU and raises throughput 3.7%; RSS and seeding remain inconclusive
  across 168 validated trials; many-file hybrid CPU/throughput improve 4.5%/2.0%
  and concurrent hybrid 5.8%/3.6%, with inconclusive RSS. First form is disqualified by 5.0%
  higher seeding RSS; all 112 trials remain. Keep this failure separate from
  revised-source evidence. Native checks (466 PASS records), application,
  recovery, sanitizers and Debug/Release builds pass. Investigate cross-run
  many-file v2 seeding throughput differences: its source ratio 0.999
  [0.871–1.018] still includes the earlier 8.5% loss. Concurrent v1 seeding source CPU
  is 1.001 [0.985–1.006], not reproducing its 7.0% cross-run rise; RSS and
  throughput remain inconclusive. Native controls also shift, so do not infer
  a source cause from separate runs.

- Isolate the UTF-8 lookup's RSS cost before further scanner variants. It saves
  6.0% CPU but adds 1.9% peak RSS and remains rejected. Gate heap/VM diagnostics
  show nearly equal live heap with different empty-arena/stack residency; this
  does not prove cause or measure churn. Use the new bounded source profiler;
  Instruments Allocations startup probes currently fail. Per-job autorelease
  scope establishes no benefit and is reverted. Character-index conversion
  also remains reverted: seeding throughput falls 2.4% despite lower CPU.

- Reduce filesystem inspection/opening and remaining disk scheduling costs:
  revised request-burst profiles validate eight captures, showing 46.0% flat
  fstatat/openat/close and 37.0% inclusive scans in many-file hybrid downloads.
  Request selection is 1.4% inclusive; disk-worker ancestry includes filesystem
  and hashing work, so do not attribute its whole weight to scheduling.
  Raw-name bulk inspection is also rejected/reverted: CPU +1.7%, throughput
  −2.2%, RSS +1.3% across 28 validated trials. Removing entry String construction
  is insufficient; require a new measured cause before further bulk variants.
  fresh write-refill profiles show 43.9% flat fstatat/openat/close and 35.5%
  inclusive layout scans in many-file hybrid downloads. Partial syscall captures
  show fuller batches (7.42 versus 3.97 writes per inferred scan section), so
  increasing request windows/caches is not justified. Preserve inconclusive
  many/concurrent source RSS intervals rather than claiming absence of cost.

- Reduce the write-refill candidate's remaining CPU gap: its full matrix validates
  all 252 trials, passing throughput 9/18, CPU 0/18 and memory 18/18. Prioritise
  many-file downloads (3.25–3.97× native CPU); preserve wide/inconclusive source
  throughput intervals and all rejected experiments.

- Resolve wide/inconclusive source throughput intervals and obtain quiet-host
  timings for the final candidate. Keep earlier Instruments failures and
  loaded-host samples labelled as diagnostics.

- Meet the unchanged per-case targets: at least 90% of libtorrent throughput,
  at most 1.25× CPU seconds/GiB through durable completion and peak RSS within
  10% of baseline. The [current full results](docs/performance/upload-publication-full-results-2026-11-13.md)
  pass memory 18/18 and throughput 9/18 (one throughput case remains inconclusive),
  but fail CPU throughout. Retain gains only
  without established costs in CPU, throughput, memory, correctness or counterpart CPU.
- Investigate the historical many-file v1 seeding regression against its preceding full
  candidate: CPU rises 5.1% and throughput falls 23.5%. A balanced old/current
  source comparison does not reproduce the loss as a source effect; retain the
  original runs and isolate the sequence/runtime conditions.
- Investigate the historical concurrent v2 seeding throughput loss of 20.0% despite lower
  CPU. The source comparison is inconclusive around a ratio of one; it still
  meets native throughput, but the full-run regression remains open.
- Reduce repeated whole-layout stamp inspection and write scheduling overhead.
  Fresh many-file hybrid download profiles attribute 39.7% inclusive to stamps,
  53.1% to write operations and 46.5% flat to stat/open/close (inclusive costs
  overlap). Preserve hashing, ownership checks, cancellation and queue caps.

## Validation diagnostics

- Resolve the native run's IPv6 v2 negotiated-encryption µTP upload timeout
  under deliberate SYN-ACK loss. The eight-request candidate records 273 native
  passes before failing, with zero payload traffic and no disk error. Preserve
  the full failed run. The isolated fixture, a declared twelve-case stress run
  and the revised representation's full native suite pass with unchanged
  deadlines. The original full-sequence failure's cause remains unexplained.

- Identify the native run's temporary-path disappearance: the first run exits 1
  with its log, fixture and module cache missing; a workspace-directory rerun
  passes all 466 checks. Evidence remains in `.build/diagnostics/piece-buffer`.


- Reproduce the earlier combined-contract six-second deadline under controlled
  CPU load and identify its wait point using the new diagnostics. Serial checks
  pass; the original stalled condition remains unknown in the retained log.

## Native interaction and appearance
- Automate real drag/drop, blocklist import/export dialogs, destination-folder
  pickers and the remaining Settings controls.
- Verify keyboard and VoiceOver navigation across every view, populated peer and
  tracker lists, very long paths and resizing.
- Compare inspector spacing with the original visual reference when available;
  no reference was supplied with the audit plan.

## macOS services and network hardware
- Verify real notification-permission changes, default-handler registration and
  router port mapping in a controlled user session. Automation deliberately stubs
  these integrations; no hardware/service acceptance pass is claimed.
- Verify private-torrent discovery restrictions with packet observation. Tests
  cover private tracker retention, inherited discovery-disable flags, native LSD
  suppression, DHT send suppression and PEX rejection on loopback wire fixtures;
  actual interface packet observation remains outstanding.
- Run a longer cancellation/shutdown/removal stress campaign with concurrent
  creation and filesystem operations. Current export tests settle every request
  and repeat without retries; they are not a long-running stress campaign.
