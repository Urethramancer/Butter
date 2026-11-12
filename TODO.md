# Remaining audit and acceptance checks

## TCP performance parity

- Meet the unchanged per-case targets: at least 90% of libtorrent throughput,
  at most 1.25× CPU seconds/GiB through durable completion and peak RSS within
  10% of baseline. The [full results](docs/performance/piece-buffer-full-results-2026-11-12.md)
  pass memory in all eighteen cases and throughput in eleven, but fail CPU throughout.
- Investigate the many-file v1 seeding regression against the preceding full
  candidate: CPU rises 5.1% and throughput falls 23.5%. A balanced old/current
  source comparison does not reproduce the loss as a source effect; retain the
  original runs and isolate the sequence/runtime conditions.
- Investigate the concurrent v2 seeding throughput loss of 20.0% despite lower
  CPU. The source comparison is inconclusive around a ratio of one; it still
  meets native throughput, but the full-run regression remains open.
- Complete remaining release acceptance; the latest matrix and both-engine
  profiles are `b328472` (276 timing and ten profile trials accepted).
- Reduce repeated whole-layout stamp inspection (40.0% inclusive in many-file
  seeding), file opening, allocation and Network.framework scheduling costs in
  the profiles, preserving stored-byte hashing, ownership checks, cancellation
  and queue caps.

## Validation diagnostics

- Identify the native run's temporary-path disappearance: the first run exits 1
  with its log, fixture and module cache missing; a workspace-directory rerun
  passes all 466 checks. Evidence remains in `.build/diagnostics/piece-buffer`.

- Reproduce the initial full-package network bind errors/timeouts during the
  queued-read experiment. Isolated network tests, the second full candidate
  run and restored-source full run pass; the cause remains unknown in
  `docs/performance/raw/verified-read-batches/package-first-failure.log`.

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
