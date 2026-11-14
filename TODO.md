# Remaining work

## Performance

- Complete single-file/concurrent download and seeding regression checks for
  bounded write coalescing. Full-transfer and fixed-rate comparisons establish
  lower CPU within the agreed retention gates.
- Complete the approved summary/detail snapshot and bounded private staging
  experiments. Preserve integrity observations, filesystem guards, the 1 MiB
  transient budget and 64 MiB staging ceiling.
- Meet the unchanged per-case targets: at least 90% of libtorrent throughput,
  at most 1.25× CPU/GiB through durable completion, and peak RSS within 10% of
  the original fresh Swift baseline. Re-run the final matrix after retained
  changes. The [current results](docs/performance/README.md) retain the latest
  baseline and qualification limits.
- Resolve grouped-upload/request-burst source uncertainty and earlier many-file
  and concurrent seeding losses with controlled comparisons.
- Establish installed-reference compiler/Boost provenance: archive ABI indicates
  Boost 1.92 while cached flags name 1.88. Retain archive fingerprints.

## Validation diagnostics

- Explain the full native sequence's IPv6 v2 encrypted µTP upload handshake
  timeout under deliberate SYN-ACK loss. Isolated and stress fixtures pass;
  the original zero-payload failure remains unexplained.
- Explain temporary-path disappearance in the earlier native run; a workspace
  rerun passes. Evidence remains in `.build/diagnostics/piece-buffer`.
- Reproduce the combined-contract six-second deadline under controlled CPU load
  and identify its wait point. Serial checks pass; the original stall is unknown.

## Native interaction and appearance

- Automate drag/drop, blocklist import/export dialogs, destination pickers and
  remaining Settings controls.
- Verify keyboard and VoiceOver navigation, populated peer/tracker lists, very
  long paths and resizing.
- Compare inspector spacing with the original visual reference when supplied.

## macOS services and network hardware

- Verify real notification-permission changes, default-handler registration and
  physical router mapping; automated checks stub or simulate these integrations.
- Observe private-torrent discovery restrictions on actual interfaces. Loopback
  tests cover tracker retention, discovery flags and DHT/LSD/PEX suppression.
- Run longer cancellation/shutdown/removal stress with concurrent creation and
  filesystem operations.
