# Butter

A native macOS BitTorrent client built with SwiftUI and the local
[ButterTorrent](Packages/ButterTorrent/README.md) Swift engine. Requires Apple
Silicon, macOS 26 and Xcode 27.2 or later.

Supports torrent files and magnets, v1/v2/hybrid metadata, TCP/µTP, selective
downloads, torrent creation, local renames, resume recovery, grouped transfers
and priority scheduling. Settings include queue limits, watched imports,
completion moves, blocklists, discovery and favourite trackers.

## Build

From a complete Git checkout:

```sh
xcodebuild -project Butter.xcodeproj -scheme Butter -configuration Debug \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Use `-configuration Release` for a Release build, or open `Butter.xcodeproj`.
The app uses the local Swift package and Apple frameworks; Homebrew and reference
engine dependencies are unnecessary for app builds.

## Use

| Action | Shortcut |
| --- | --- |
| Open torrent | `⌘O` or drop a file onto the window |
| Add magnet | `⌘L` |
| Create torrent | `⌘N` |
| Settings | `⌘,` |
| Toggle inspector | `⌥⌘I` |

The transfer list supports multiple selection and context actions. Torrents show
a v1, v2 or Hybrid badge once metadata is available.

**Repair from local file…** replaces a missing or damaged file from a separate
copy. **Repair from Folder…** accepts the original root or its parent, including
partial folders. Repair preserves sources, renames and selection, pauses peer
I/O and journals publication. Pieces requiring neighbouring files remain pending.
**Verify Local Data** always hashes stored bytes, including shared boundary pieces.

## Storage and recovery

State lives in `~/Library/Application Support/Butter`. Back up the whole directory:
`Engine/` contains metadata, native checkpoints and filesystem journals. Existing
libtorrent resume files are retained; local renames preserve torrent identities.

After a clean shutdown, completed checkpoints are trusted only while metadata,
paths, hashes and file stamps match. Unfinished torrents are checked on every
launch, including paused transfers; an unclean launch also checks completed
payloads. Validation runs serially before each affected torrent can resume.
Detected external changes retire stale advertisements and trigger rechecking.

Ordinary removal retains payloads. Delete asks for confirmation and moves managed
files individually to Trash, rejecting shared files and unsafe paths. Completion
moves must succeed before auto-removal; created torrents seed their source in place.
Watch-folder automation, original deletion, auto-removal and ratio/idle stopping
are disabled by default. Private torrents suppress discovery and keep their trackers.

The manual port check uses [Transmission's checker](https://github.com/transmission/transmission/blob/main/libtransmission/rpcimpl.cc).
External TCP reachability and local UDP binding are separate results; service
failures report unknown status. Bandwidth estimates come from observed traffic
and probes, rather than an ISP connection measurement.

## Verification and performance

`Scripts/verify.sh final` runs serial package tests, recovery checks, sanitizers,
Debug/Release linkage checks and native UI automation. Run it when the computer
is available for UI tests. Focused suites include `contract`, `creation`, `peer`,
`network`, `native-storage`, `lifecycle` and `ui`.

Optional libtorrent comparisons require `Scripts/bootstrap-engine.sh` and CMake.
Use `Scripts/verify.sh reference` for reference checks, `peer-reference` for
interoperability and `benchmark` for the complete Release matrix. Add
`benchmark --smoke` for smaller correctness fixtures. `storage-benchmark` needs
no reference installation.

See [performance results](docs/performance/README.md),
[validation scope](docs/validation.md), [architecture](docs/swift-engine.md),
[audit results](docs/audit.md) and [remaining work](TODO.md).
Passing verification logs are removed automatically; failures print their path
under `.build/test-logs`. Generated captures and reports belong under `.build/`.

## Versions and licence

To set up local releases, install the GitHub CLI, run `gh auth login`, then run
`Scripts/release.sh setup` in Terminal. This stores notarisation credentials in
the `Butter-notary` Keychain profile. Enter your Developer Apple ID and an
[app-specific password](https://support.apple.com/102654) at the prompts;
credentials are never stored in the repository. Xcode's saved account alone
does not configure this profile. The Mac also needs the project's Developer ID
Application certificate and private key (team `ZWL2A2VN43`).

After verification, create the chosen annotated `vMAJOR.MINOR.PATCH` tag, then
run `Scripts/release.sh TAG`. It builds that exact tag in a disposable full
checkout, exports a signed Release app, notarises it, staples and checks the
ticket, and packages an Apple Silicon ZIP with SHA-256 checksums. It then pushes
the tag and uploads a GitHub draft, checks the downloaded assets and publishes.
Local changes are excluded. Existing releases and conflicting remote tags are
rejected; nothing is overwritten. If publication stops after creating a draft,
inspect that draft before retrying. This command does not replace release testing.

Use `Scripts/release.sh TAG --prepare` to produce verified local assets without
pushing or publishing. Use `Scripts/release.sh --prepare` to build the latest
commit: when it has no annotated release tag, the ZIP name includes the version
and `-dev-<commit>`; development builds stay local. Set `BUTTER_NOTARY_PROFILE`
to use an existing profile.
Artifacts and build/notarisation logs remain under `.build/releases/`; failed
submissions retain Apple's response and log when available. After a timeout,
Apple may still be processing the saved submission ID. The workflow follows
[Apple's command-line notarisation guidance](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Builds derive versions from Git without changing source files. `CFBundleVersion`
counts commits reachable from HEAD; the marketing version uses the nearest
ancestor `vMAJOR.MINOR.PATCH` tag, defaulting to `0.1.0` before a release tag.
Shallow checkouts require `git fetch --unshallow --tags`.

Butter uses the MIT licence. Adapted code and optional reference dependencies
retain their notices in `Butter/Licences`, `Packages/ButterTorrent` and
`Tests/Reference/Licences`.
