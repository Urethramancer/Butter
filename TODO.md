# Remaining audit and acceptance checks

## TCP performance parity

- Meet the unchanged per-case targets: at least 90% of libtorrent throughput,
  at most 1.25× CPU seconds/GiB through durable completion and peak RSS within
  10% of baseline. The [full results](docs/performance/tcp-batching-results-2026-11-12.md)
  pass memory throughout but fail CPU in all eighteen cases. Refresh the full
  matrix with the filesystem, input, cache-admission, upload-window and batch
  cancellation improvements.
- Reduce repeated whole-layout stamp inspection and per-block upload,
  allocation and Network.framework scheduling costs identified in the profiles,
  preserving stored-byte hashing, ownership checks, cancellation and queue caps.

## Validation diagnostics


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
