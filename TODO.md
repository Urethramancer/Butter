# Remaining audit and acceptance checks

## Swift cut-over audit findings

- Apply blocklists to HTTP/HTTPS and UDP tracker destinations, including changes
  during running announces. See A09 in [the audit](docs/audit-2026-11-11.md).
- Close the file-identity race between storage preflight and destructive pathname
  operations, including cross-volume source deletion and repository discard (A10).
- Bound watch-folder reads and aggregate retained import data (A11).
- Enforce the quit deadline across polling drain, persistence and engine shutdown (A12).
- Preserve original remote filename components for BEP 19 web-seed requests (A13).
- Reduce repeated piece-candidate sorting and unchanged verified-layout scans,
  then rerun the 32/256 MiB CPU comparisons and recovery tests (A15–A16).

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
