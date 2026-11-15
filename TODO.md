# Remaining work

## Performance

- Reduce download CPU/GiB and improve single/many-file throughput against
  libtorrent. Downloads miss the CPU target in the
  [latest matrix](docs/performance/README.md), which ran under competing host load.
  Targets remain ≥90% throughput, ≤1.25× CPU/GiB and peak RSS within 10% of the
  original Butter baseline.
- Validate a per-torrent byte-window policy using the 32/48/64 calibration;
  cover latency and multiple peers before generalising the 1 MiB-piece result.
- Investigate guarded path opens/closes and peer transport overhead while
  preserving fresh filesystem observations and production resource limits.
- Repeat release performance validation without competing builds and heavy
  background work; include isolated fairness-batch candidate `99afd53` in a
  separately predeclared comparison. Current runs remain contended-host evidence.
- Locate the remaining verification/worker delay in descriptor-cache experiments;
  direct baseline timing shows checkpoint execution is a small target.
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
