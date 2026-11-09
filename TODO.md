# Remaining audit and acceptance checks

## Filesystem interruption and failure matrix
- Kill actual cross-volume completion moves and multi-file folder renames at
  several filesystem-operation boundaries; verify recovery on a second volume.
  Current tests cover interrupted rename journals and process death during state
  writes, not partial cross-volume operations.
- Extend actual ENOSPC/read-only volume tests from saved state to imports, path
  journals and exports. State preservation/recovery now passes on a disposable
  full/read-only image; resume/export failure uses a conflicting output directory.
- Stress watched-file replacement at every claim/restore boundary, including a
  replacement arriving while the original is restored. Current regression covers
  replacement before claiming, unchanged deletion and symlink refusal.
- Verify interrupted deletion and failed final metadata cleanup. Retained orphan
  metadata is safe but has no automatic garbage-collection workflow.

## Native interaction and appearance
- Automate multi-selection, drag/drop, queued multi-file Add sheets, valid local
  file/folder rename dialogs and all Settings editors. Backend tests cover queued
  requests and local renames; native tests cover display rename and selected files.
- Complete compositor review of the transfer window, every inspector tab and all
  Settings tabs in Light/Dark, with keyboard/VoiceOver navigation and long text.
  General Settings captures have been inspected; layer smoke captures do not
  establish visual acceptance for other views.
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
