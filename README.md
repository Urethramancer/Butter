# Butter

A native macOS BitTorrent client built with SwiftUI and the local
`Packages/ButterTorrent` Swift engine. Targets Apple Silicon and macOS 26 and
requires Xcode 27.2 or later.

Butter supports torrent files and magnets, TCP and µTP, selective downloads,
hybrid torrent creation, local file renames, resume recovery, grouped transfers,
priority scheduling and a searchable inspector. Settings include watched imports,
completion moves, queue limits, blocklists, discovery and favourite trackers.

## Build

Build from a complete Git checkout with Xcode and its command-line tools.

```sh
xcodebuild -project Butter.xcodeproj -scheme Butter -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Choose `-configuration Release` for a Release build, or open `Butter.xcodeproj`.
The app links the local Swift package and Apple system frameworks. The build
requires no Homebrew packages or dependency bootstrap. `Butter/Licences`
contains the retained notice for adapted path sanitisation code.

## Use and storage

Open a torrent with `⌘O`, add a magnet with `⌘L`, or drop a file onto the window.
Create a torrent with `⌘N`; open Settings with `⌘,` and toggle the inspector with
`⌥⌘I`. The transfer list supports multiple selection and context actions.

App state is stored in `~/Library/Application Support/Butter`. The `Engine/`
directory keeps standard torrent metadata, versioned Swift checkpoints and
atomic filesystem journals. Local renames preserve the original info dictionary.
Interrupted operations reconcile the managed files and may require review before
resuming. Existing libtorrent resume files are retained. Keep the whole support
folder together when backing up or restoring it.


Ordinary removal retains data. The separate delete action asks for confirmation,
waits for engine disk activity, and moves existing managed files individually to
Trash. Shared files and unsafe paths are rejected. Completion moves must succeed
before auto-removal; created torrents always seed their source in place.

Watch-folder automation, original deletion, auto-removal, ratio stopping and idle
stopping default to disabled. Private torrents disable discovery and retain their
trackers. Favourite trackers are appended only when explicitly selected. The
manual port check uses [Transmission's HTTPS checker](https://github.com/transmission/transmission/blob/main/libtransmission/rpcimpl.cc);
it reports external TCP reachability separately from local UDP binding. Service
failures are unknown results. Bandwidth estimates use observed rates with regular
upward probes; they are not measurements of an ISP connection limit.

## Verification

Run `Scripts/verify.sh final` for the native app and package checks. It runs the
UI suite once, checks Debug and Release linkage, exercises disposable-volume
and process-interruption recovery, and verifies the package with coverage and
sanitizers. Run it when the computer is available for UI automation.

Focused suites include `contract` for the app command boundary, `creation` for
source seeding and creation failure handling, `peer` for the Swift wire engine,
`network` for local network fixtures, and `native-storage` for file operations
and recovery. `Scripts/verify.sh contract --system-trash` moves a generated file
into the system Trash, checks the receipt and removes that test receipt.

The pinned libtorrent engine and bridge are optional developer tools under
`Tests/Reference`. Run `Scripts/bootstrap-engine.sh` once to build the reference
dependencies with CMake, then run `Scripts/verify.sh reference` for the reference
suite or `Scripts/verify.sh peer-reference` for transfer interoperability.
The matrix covers 456 transfers and DHT protocol comparisons, including
sparse hybrid magnets, discovery, web seeds and impaired TCP-disabled µTP.
`Scripts/verify.sh benchmark` runs the paired Release TCP download/seeding matrix,
with separate durable-completion, CPU and whole-process memory measurements.
Use `benchmark --smoke` for a smaller correctness run; see the
[comparison method and artifacts](docs/performance/README.md).
The [12 November results](docs/performance/results-2026-11-12.md) record the full
matrix, CPU regressions and remaining parity gap.
`Scripts/verify.sh storage-benchmark` measures many-file storage costs with
byte and restart checks; it requires no reference-engine installation.
The [migration record](docs/swift-engine.md) and [audit](docs/audit.md) document
the measurements, acceptance checks and remaining manual coverage.

Verification captures output under `.build/test-logs`. Passing logs are removed
automatically. Failures and interrupted runs retain their logs and print the
path. Coverage and diagnostic artifacts remain available. Use
`sh Scripts/test-log.sh label command [arguments...]` for direct commands.

Native XCUITests exercise torrent and magnet addition, keyboard shortcuts,
search typing/clearing, mixed file selection, context rename, inspector toggling,
removal confirmation, typed peer limits, Settings persistence and quit modes.
Default-size compositor captures of every Settings and inspector tab have been
inspected in Light and Dark. This review found and fixed a collapsed Groups
editor and duplicate peer-field labels; resizing and full accessibility acceptance
remain in TODO.md.

Interface smoke checks open isolated native test windows in Light and Dark appearance.
They write partial layer captures under ignored `.build/InterfaceChecks`; these
do not replace a compositor-based visual review. Remaining manual and stress
checks are listed in `TODO.md`.

## Git versions

Each build runs `Scripts/git-version.sh` to combine `Butter-Info.plist` and version
keys in Xcode's derived directory. Builds never rewrite source files.
`CFBundleVersion` counts all commits reachable from HEAD. The marketing version
comes from the nearest ancestor tag matching `vMAJOR.MINOR.PATCH`, with `v`
removed; before a release tag it defaults to `0.1.0`. Both annotated and lightweight
tags work. Build from complete Git history with release tags available; shallow
clones fail and require `git fetch --unshallow --tags`.

Butter's code uses the MIT licence. Adapted code and optional reference dependencies retain their own terms.
