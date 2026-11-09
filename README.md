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
