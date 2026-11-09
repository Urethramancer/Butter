# Butter

A native macOS BitTorrent client built with SwiftUI and an embedded libtorrent
2.1.2 engine. Targets Apple Silicon and macOS 26; requires Xcode 27.2 or later.
The standalone, non-sandboxed app needs no Homebrew installation at runtime.

Butter supports torrent files and magnets, TCP and µTP, selective downloads,
hybrid torrent creation, local file renames, resume recovery, grouped transfers,
priority scheduling and a searchable inspector. Settings include watched imports,
completion moves, queue limits, blocklists, discovery and favourite trackers.

## Build

Install CMake 3.20+ and the Xcode command-line tools. The bootstrap also uses
Make, Perl, curl, tar and shasum.

```sh
Scripts/bootstrap-engine.sh
Scripts/build-bridge.sh
xcodebuild -project Butter.xcodeproj -scheme Butter -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Use `-configuration Release` for a Release build, or open `Butter.xcodeproj`.
Run `Scripts/build-bridge.sh` after changing engine sources. Xcode checks its
freshness and fails with instructions if it is missing or stale. Both Xcode
script phases retain script sandboxing. Bootstrap is an explicit separate step.

Dependencies are static: [libtorrent 2.1.2](https://github.com/arvidn/libtorrent/releases/tag/v2.1.2),
Boost 1.88.0 headers, OpenSSL 3.5.9 and libtorrent's pinned try_signal submodule.
`Scripts/bootstrap-engine.sh` pins source revisions/releases and verifies SHA-256
checksums before extraction. Sources and products stay in ignored `.dependencies`.
Licence notices are included in `Butter/Licences` and copied into the app bundle.
An explicit iterator include works around a missing upstream standard-library
include with Xcode 27's libc++.

## Use and storage

Open a torrent with `⌘O`, add a magnet with `⌘L`, or drop a file onto the window.
Create a torrent with `⌘N`; open Settings with `⌘,` and toggle the inspector with
`⌥⌘I`. The transfer list supports multiple selection and context actions.

App state is stored in `~/Library/Application Support/Butter`: atomic `state.json`,
imported torrent metadata, resume data and path journals in `Engine/`. Local
renames keep the original info dictionary. Interrupted rename journals are
reconciled against disk and require review before resuming. Moves record their
destination before starting; recovery selects a location containing all files
that existed before the move, rechecks them and pauses for review. Retained copies
in the other location are kept for the user to inspect. Keep the whole
support folder together when backing up or restoring it.

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

```sh
Scripts/verify.sh all
Scripts/verify.sh coverage after
Scripts/verify.sh sanitizers audit
```

`Scripts/verify.sh` also accepts `client`, `storage`, `engine`, `lifecycle`,
`disk`, `interruption`, `interface`, `ui`, `build` and `version`. Existing test commands remain supported.
Use `BUTTER_TEST_CASE=parser-invariants Scripts/verify.sh client` for a named
client case. Engine cases are `engine-validation`, `concurrent-exports`,
`filesystem-failures`, `metadata-variants` and `transfer-integration`; lifecycle
cases are `store-regressions` and `lifecycle-integration`. UI accepts Xcode's
`-only-testing:` arguments. Unknown case names fail.

Coverage uses Apple LLVM and instruments first-party Swift and Objective-C++
code in separate products. Native XCUITests launch the real Debug application
with disposable storage; system registration, notifications, discovery, router
mapping and public port checks are stubbed. Production builds ignore the test
launch configuration. `.build/coverage/<label>` contains per-file line/region
reports, separate Swift and bridge reports, C++ branches, annotated uncovered
source, JSON, suite status and a before/after comparison when a baseline exists.
Dependencies, tests, SDK sources and generated asset code are excluded explicitly.
The `disk` suite mounts and detaches a disposable 16 MB image under `/tmp` to
verify real ENOSPC and read-only recovery without filling the user’s disk.
Sanitizers cover the bridge with uninstrumented dependencies. Full verification
also checks unsigned Debug/Release builds, static linkage, bundled licences and
repeat-build cleanliness. See [the audit record](docs/audit.md) for findings,
measurement scope and [remaining checks](TODO.md).

Client checks cover persistence, watcher stability, group rules, priority
inheritance, admission, Force Start, bandwidth fairness/redistribution/recovery,
ratio/idle stopping, blocklist formats/merging/export and unavailable port-check services.

Engine checks include 192 overlapping export requests, shared-file refusal,
resume/export-write failure and recovery, unsafe journal/symlink rejection,
and independent v1-only/v2-only loopback transfers. They generate temporary fixtures for a verified **µTP-only transfer
with TCP disabled on both peers**, TCP magnet metadata, corruption/retry,
selective files, blocklists, nested rename identity, hash-preserving export,
resume recovery and interrupted rename reconciliation, resolved v1/v2 magnet
duplicates, creation cancellation, hard peer limits, occupied-port recovery,
collisions, move failure, ordinary removal and Trash isolation. Trash tests clean
up their own receipts and need normal access to the user's Trash. Lifecycle checks cover watched copying
and deletion, duplicate selection, completion moves, auto-removal retaining data,
source seeding, private trackers, explicit favourite selection and orderly saves.

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

Butter's code uses the MIT licence; embedded dependencies retain their own terms.
