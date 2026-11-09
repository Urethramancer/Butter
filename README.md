# Butter

A macOS app built with SwiftUI. Requires Xcode 27.2 or later and macOS 26 or later.

Open `Butter.xcodeproj` and build the Butter scheme, or run:

```sh
xcodebuild -project Butter.xcodeproj -scheme Butter -configuration Debug -destination 'platform=macOS' build
```

Each build runs `Scripts/git-version.sh` with script sandboxing enabled. It combines the version keys and `Butter-Info.plist` in Xcode’s derived build directory. Xcode then expands the app settings and adds platform and build metadata before signing. Builds do not modify source files.

The metadata template preserves the app’s existing generated keys. Automatic plist generation is disabled because Xcode 27 overwrites supplied version keys with empty values when the fixed version settings are removed.

- `CFBundleVersion` is `git rev-list --count HEAD`, counting all commits reachable from HEAD.
- `CFBundleShortVersionString` comes from the nearest ancestor tag matching `vMAJOR.MINOR.PATCH`, with the `v` removed. Both annotated and lightweight tags are supported. Before the first release tag, it is `0.1.0`.

Build from a complete Git checkout with release tags available. Archives without Git history and shallow clones cannot produce reliable versions and fail the build. For a shallow clone, run `git fetch --unshallow --tags` before building. Release commits and annotated tags remain local until explicitly pushed.

Run the versioning regression checks with `sh Tests/git-version.sh`.

## Embedded engine

Butter targets Apple Silicon and macOS 26. Build the pinned static dependencies with
`Scripts/bootstrap-engine.sh`, then run `Scripts/build-bridge.sh` before building
in Xcode. CMake 3.20+, a C++ compiler, Perl, Make, curl and the Xcode command-line
tools are required. Downloaded sources, caches and static libraries stay in the
ignored `.dependencies` directory. The app links libtorrent 2.1.2, Boost 1.88.0
(headers), OpenSSL 3.5.4 and try_signal statically; it needs no Homebrew installation
at runtime. Their notices are included in `Butter/Licences` and the app bundle.
The bootstrap verifies SHA-256 checksums before extraction. An explicit iterator
include works around a missing standard-library include in upstream libtorrent
with Xcode 27’s libc++.

Run `Scripts/test-engine.sh` for isolated generated-fixture engine checks. These
use loopback sessions and temporary data, including a transfer with TCP disabled
on both peers. They do not contact a tracker or discovery network.
