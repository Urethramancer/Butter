# Remaining audit and acceptance checks

## TCP performance parity

- Meet the unchanged per-case targets: at least 90% of libtorrent throughput,
  at most 1.25× CPU/GiB through durable completion, and peak RSS within 10% of
  the original fresh Swift baseline. The current
  [full matrix](docs/performance/repair-final-full-results-2026-11-13.md)
  passes throughput 11/18, CPU 0/18 and memory 18/18. No parity claim is justified.
- Resolve source uncertainty in grouped uploads/request bursts, including RSS,
  counterpart CPU and many/concurrent throughput. Preserve the historical
  many-file v1 seeding CPU/throughput and concurrent v2 seeding throughput losses:
  balanced source comparisons did not establish their cause. Do not infer a
  source regression from separate full runs or treat inconclusive intervals as
  proof of no cost.
- Reduce remaining filesystem inspection and disk scheduling costs without
  weakening integrity or increasing request/cache limits. Keep rejected UTF-8
  lookup, character-index, raw-name bulk scan, vector-write and autorelease
  experiments rejected unless new measurements explain their costs.
  Three further [descriptor experiments](docs/performance/descriptor-results-2026-11-13.md)
  validate all 84 source trials but remain inconclusive and reverted. Obtain
  stronger CPU attribution before adding further cache machinery.
- Establish reproducible installed-reference compiler/Boost provenance. The
  archive exposes Boost 1.92 ABI while cached Apple-build flags name 1.88;
  preserve archive fingerprints and existing comparisons. See the
  [native probe findings](docs/performance/restart-and-native-diagnostics-2026-11-13.md).
- Obtain quiet-host timing evidence where earlier intervals remain wide. Retain
  Instruments startup failures and loaded-host captures as diagnostics only.

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
