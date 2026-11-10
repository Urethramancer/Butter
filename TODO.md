# Remaining audit and acceptance checks

## Swift torrent engine replacement
- Phase 11: complete Swift adapter, displays, counters, lifecycle and dual-engine scenarios.
  Complete native router-mapping settings (currently rejected by the adapter).
  Coordinate mapping lifecycles in that session.
  Verify interruption and disk-failure recovery during repository publication/discard.
  Resolve inherited PCP-before-NAT-PMP behaviour from the pinned reference;
  the Swift mapping clients currently implement UPnP and NAT-PMP.
  Hybrid magnets with only legacy v1 providers need reconstruction of missing v2 piece layers from
  SHA-1-verified file data; the current harness requires a v2 hash provider or
  complete `.torrent` piece layers.
- Phase 12: consolidated acceptance and measurements, cut-over and dependency removal.
  Measure web-seed request overhead; current bounded downloads request 16 KiB
  blocks and open a connection for each HTTP request, without range coalescing.
  Preserve `v0.3.0`; commit, create an annotated minor tag and push after phase 11,
  then do the same for phase 12. Details and gates are in
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
  cover private tracker retention, inherited discovery-disable flags, native LSD
  suppression, DHT send suppression and PEX rejection on loopback wire fixtures;
  actual interface packet observation remains outstanding.
- Run a longer cancellation/shutdown/removal stress campaign with concurrent
  creation and filesystem operations. Current export tests settle every request
  and repeat without retries; they are not a long-running stress campaign.
