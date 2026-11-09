# Remaining acceptance checks

## Native interaction and appearance
- Exercise keyboard shortcuts, file/magnet drops, multiselection, context menus,
  file-tree checkboxes, rename dialogs and Settings interactively in Light and Dark.
  Native-view smoke checks pass; compositor captures are unavailable in this session.
- Compare inspector spacing with the original visual reference when available;
  that reference was not included with the implementation plan.

## Failure and integration stress
- Interrupt cross-volume completion moves and multi-file folder renames during
  process termination; verify recovery with partial filesystem operations.
- Inject disk-full and folder-permission failures during state saves and exports.
- Verify notification permission changes, default-handler registration and router
  mapping against real macOS settings and network hardware.
