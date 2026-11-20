# Remaining work

## Performance

- Measure cold-start magnet discovery and connection-queue latency across swarms.
- Reduce download CPU/GiB and improve single/many-file throughput against
  libtorrent. Downloads miss the CPU target in the
  [latest matrix](docs/performance/README.md), which ran under competing host load.
  Targets remain ≥90% throughput, ≤1.25× CPU/GiB and peak RSS within 10% of the
  original Butter baseline.
- Identify a per-peer signal that distinguishes a latency-limited download
  before increasing its request window. The [window comparisons](docs/performance/peer-experiments-20261120.json)
  show a gain with delayed peers and mixed ordinary-download results.
- Investigate guarded path opens/closes and peer transport overhead while
  preserving fresh filesystem observations and production resource limits.
- Resolve the single-file sender CPU increase before promoting bounded v1 write
  coalescing (`refs/archive/experiment/bounded-v1-write-policy`). The revised candidate passes
  its hybrid throughput guard and reduces v1 client CPU, but single-file combined
  CPU has a higher median; see the [results](docs/performance/bounded-v1-policy-20261119.json).
  Preserve the separate earlier experiment and do not extend fixed runs.
- Repeat release performance validation on a quiet host. For the fairness-batch
  comparison use `refs/archive/experiment/fairness-batch-retention`.
- Locate the remaining verification/worker delay in descriptor-cache experiments;
  direct baseline timing shows checkpoint execution is a small target.
- Resolve grouped-upload/request-burst uncertainty with matched source comparisons.
- Establish reference compiler/Boost provenance: archive ABI indicates Boost 1.92,
  while cached flags name 1.88. Installed object payloads match 178/179 cached
  Apple-build objects; `bt_peer_connection.cpp.o` differs. Establish the origin
  of that object and the headers actually used. Retain archive fingerprints.

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
