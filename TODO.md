# Remaining audit and acceptance checks

## Swift torrent engine replacement
- Phase 8: extension negotiation (including inherited Fast extensions), metadata
  exchange, PEX, DHT, v2/hybrid transfers and private discovery enforcement.
- Phase 9: negotiated peer encryption and plaintext fallback interoperability.
- Phase 10: µTP with deterministic network-failure fixtures and TCP-disabled transfers.
- Phase 11: complete Swift adapter, displays, counters, lifecycle and dual-engine scenarios.
  Quiesce peer I/O before storage mutations and coordinate aggregate disk/cache
  admission across simultaneous transfers.
  Resolve inherited PCP-before-NAT-PMP behaviour from the pinned reference;
  the Swift mapping clients currently implement UPnP and NAT-PMP.
- Phase 12: consolidated acceptance and measurements, cut-over and dependency removal.
  Preserve `v0.3.0`; create an annotated minor tag after each completed phase;
  do not push. Details and gates are in
  [the migration record](docs/swift-engine.md).

## Filesystem integration
- Verify native system Trash destination selection and Finder receipt behaviour
  when connecting the Swift adapter. Multi-file interruption recovery and receipt
  bytes pass with disposable Trash directories, including cross-volume copies.

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
  cover private tracker retention, inherited discovery-disable flags and native
  LSD suppression with injected datagrams; actual interface packet observation
  remains outstanding.
- Run a longer cancellation/shutdown/removal stress campaign with concurrent
  creation and filesystem operations. Current export tests settle every request
  and repeat without retries; they are not a long-running stress campaign.
