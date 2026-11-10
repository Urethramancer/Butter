# Remaining audit and acceptance checks

## Swift torrent engine replacement
- Phase 5: shared TCP/UDP transport, UDP trackers, discovery and router mapping.
  Connect DNS-resolved address policies/pinning to HTTP services before enabling
  them in production, including DNS rebinding and public-to-local redirects.
- Phase 6: safe storage, selective layout, verification, checkpoints and interruption recovery.
- Phase 7: v1 TCP downloads and seeding, both libtorrent interoperability directions.
- Phase 8: metadata exchange, PEX, v2/hybrid transfers and private discovery enforcement.
- Phase 9: negotiated peer encryption and plaintext fallback interoperability.
- Phase 10: µTP with deterministic network-failure fixtures and TCP-disabled transfers.
- Phase 11: complete Swift adapter, displays, counters, lifecycle and dual-engine scenarios.
- Phase 12: consolidated acceptance and measurements, cut-over and dependency removal.
  Preserve `v0.3.0`; create an annotated minor tag after each completed phase;
  do not push. Details and gates are in
  [the migration record](docs/swift-engine.md).

## Filesystem interruption and failure matrix
- Interrupt a real multi-file Trash operation and verify remaining files and Trash
  receipts across relaunch.

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
  cover private tracker retention and the implementation sets discovery-disable
  flags, but no network-level discovery assertion has been made.
- Run a longer cancellation/shutdown/removal stress campaign with concurrent
  creation and filesystem operations. Current export tests settle every request
  and repeat without retries; they are not a long-running stress campaign.
