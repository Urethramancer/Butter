# Remaining work

## Performance

- Reduce download CPU/GiB and improve single/many-file throughput against
  libtorrent. The [current matrix](docs/performance/README.md) passes all nine
  seeding cases; downloads miss the CPU target. Targets remain ≥90% throughput,
  ≤1.25× CPU/GiB and peak RSS within 10% of the original Butter baseline.
- Investigate guarded path opens/closes and peer transport overhead while
  preserving fresh filesystem observations and production resource limits.
- Separate verification/checkpoint execution from worker/actor waits; the
  receive profile locates most of the descriptor-cache regression there.
- Resolve grouped-upload/request-burst uncertainty with matched source comparisons.
- Establish reference compiler/Boost provenance: archive ABI indicates Boost 1.92,
  while cached flags name 1.88. Retain archive fingerprints.

## Unexplained validation failures

- Locate the native sequence's IPv6 v2 encrypted µTP handshake timeout under
  deliberate SYN-ACK loss; isolated and stress fixtures pass.
- Explain earlier temporary-path disappearance; a workspace rerun passes.
  Evidence: `.build/diagnostics/piece-buffer`.
- Locate the wait behind the combined-contract six-second deadline under CPU
  load; serial checks pass.

## Native interaction and appearance

- Automate drag/drop, blocklist import/export, destination pickers and remaining
  Settings controls.
- Review keyboard/VoiceOver navigation, populated peer/tracker lists, long paths
  and resizing.
- Compare inspector spacing with the original visual reference when supplied.

## macOS services and network hardware

- Test real notification permissions, default-handler registration and physical
  router mapping; current checks stub or simulate them.
- Observe private-torrent discovery restrictions on actual interfaces.
- Run longer cancellation, shutdown, removal and concurrent filesystem stress.
