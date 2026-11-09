# ButterTorrent

Apple-first Swift libraries for Butter's staged engine replacement. The metadata
library uses Foundation and CryptoKit and has no AppKit, SwiftUI or bundled
third-party dependencies. The parent repository's MIT licence applies.

`ButterTorrentMetadata` provides bounded binary bencoding, exact original info
bytes, incremental SHA-1/SHA-256, full v1/v2 identifiers, magnet parsing/generation
and v1/v2/hybrid metadata inspection and hybrid creation. Binary dictionary keys remain binary.
Out-of-order dictionary keys are tolerated for interoperability, but duplicate
keys and non-canonical numbers/lengths are rejected. Identity always hashes the
original info section, including its original key order.

Default bounds are 32 MiB of input/output, 100 nested values and one million
values (including dictionary keys). Integers are limited to signed 64-bit values.
Metadata reads are bounded even if a file grows while being read. Path components
use the reference's Apple sanitisation rules without changing info bytes. See
`THIRD_PARTY_NOTICES.txt` for the adapted implementation's attribution. Piece-layer
bytes are retained and structurally inspected; transfer-time Merkle verification
belongs to later creation/transfer phases. Inspection never marks payload data
verified. Magnet hints do not authorise discovery for private torrents.

`TorrentCreator` hashes files in 16 KiB blocks, constructs v1 piece hashes and v2
Merkle trees/piece layers, and emits hybrid metadata with canonical file ordering,
padding, private flags and trackers. Empty files are retained, symlinks excluded
and changed source files rejected. Descriptor-relative reads refuse symlinks in
source subdirectories. Limits include 50,000 source files, depth 90, fewer than
400,000 pieces and 16 MiB maximum piece size, in addition to encoding limits.
Creation needs a source containing at least one byte. Progress and cancellation
callbacks are synchronous; callers choose the worker. Butter uses one serial
worker, atomic publication, explicit cancellation and shutdown settlement.

```sh
swift test --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent
Scripts/verify.sh metadata-reference
Scripts/verify.sh creation
```

The first command works without libtorrent installed. The second uses the parent
repository's optional reference dependencies to compare twelve cases covering
single/multifile v1/v2/hybrid layouts, identities, magnets and sanitised paths. It uses
temporary files and does not contact public peers or discovery services.

Butter currently compiles the metadata target's source directory into its app
and headless executables, using the same files that SwiftPM tests. This keeps the
existing Xcode project and shell-based test builds aligned without introducing
binary artefacts. Consumers of the standalone package can import the
`ButterTorrentMetadata` product normally.
