# ButterTorrent

The Swift engine used by Butter's macOS app. The package uses Apple frameworks
without bundled third-party dependencies; the repository's MIT licence applies.
Libtorrent is an optional interoperability and benchmark reference.

| Product | Responsibility |
| --- | --- |
| `ButterTorrentMetadata` | Bencoding, identities, magnets, v1/v2/hybrid metadata and torrent creation |
| `ButterTorrentNetworking` | TCP/µTP, encrypted streams, HTTP/UDP, trackers, discovery, web seeds and router protocols |
| `ButterTorrentStorage` | Piece/file mapping, virtual padding, selection, hashing, checkpoints and recoverable file operations |
| `ButterTorrentEngine` | Transfer/session ownership, peer scheduling, upload admission and discovery integration |

## Metadata and creation

Identities hash the exact original info bytes. Binary dictionary keys remain
binary; duplicate keys and non-canonical numbers/lengths are rejected. Default
bencoding limits are 32 MiB, depth 100 and one million values. Inspection never
marks payloads verified, and magnet hints cannot authorise private discovery.

`TorrentCreator` emits hybrid metadata with v1 hashes, v2 Merkle layers, canonical
file ordering and padding. It preserves empty files, rejects changed sources and
refuses symlinked descendants. Sources must contain at least one byte. Piece sizes
up to 32 MiB are supported; automatic sizing targets about 2,048 pieces and caps
at 16 MiB. Progress and cancellation callbacks are synchronous; callers own the worker.
Adapted path sanitisation is attributed in [THIRD_PARTY_NOTICES.txt](THIRD_PARTY_NOTICES.txt).

## Networking

Transports bound requests, framing, decoded bodies, queues and deadlines. HTTP/TLS
uses numeric endpoints after validating all DNS answers; TLS authenticates the
original hostname. Unsafe local redirects, mixed public/local answers, URL
credentials and HTTPS downgrades are rejected. Responses use no cookie jar,
credential store or cache. `FoundationHTTPTransport` aliases `NetworkHTTPTransport`.

`ListeningPort` owns TCP and IPv4/IPv6 UDP on one port. Shared dispatchers match
UDP replies by endpoint and transaction. Trackers manage tiers, intervals and
started/completed/stopped events; web seeds retain original remote path bytes and
validate response ranges. Fetched bytes require storage authentication before
advertisement. Private torrents suppress discovery; blocklists cover peers and trackers.

## Storage and lifecycle

Storage defaults rehash restored claims and verified reads. The app may explicitly
select `.trustCompleted` after a durable clean shutdown and `.trustedVerified`
reads; both retain synchronous filesystem checks. Explicit `verify(piece:)` and
`validate(piece:)` always read and hash storage. Launch validation is serial and
includes paused unfinished transfers.

Descriptor-relative operations reject unsafe descendants and destructive access
to hard-linked files. A shared coordinator protects live paths; each checkpoint
directory has an OS lock. Journals and exclusive claims make import, rename,
selection, move and Trash recoverable. Unexpected replacements are preserved;
unfinished recovery blocks ordinary I/O and verified advertisements.

Commands are serial per storage owner, with four shared workers and bounded
queues. Contiguous download writes share a 1 MiB transient budget. Concurrent
upload requests join one piece load; the default 64 MiB session cache retains at
most eight immutable pieces per transfer. Protocol requests remain 16 KiB and
production windows remain bounded.

Hosts own listeners and final storage shutdown. Stop peer I/O before filesystem
operations. Session shutdown drains networking and disk work and checkpoints
counters; failed publication permits a retry. Application shutdown must not claim
a clean exit while owned work remains unfinished.

## Tests

From the repository root:

```sh
swift test --no-parallel --package-path Packages/ButterTorrent --scratch-path .build/ButterTorrent
Scripts/verify.sh native-storage
Scripts/verify.sh peer
Scripts/verify.sh peer-reference
```

Package tests need no libtorrent installation. `peer-reference` requires the
optional reference bootstrap. Fixtures use temporary files and local listeners;
TLS tests use disposable identities without changing keychain trust. Native
storage tests include killed processes, ENOSPC and a read-only disposable volume.

See [architecture](../../docs/swift-engine.md), [validation](../../docs/validation.md)
and [performance](../../docs/performance/README.md) for integration details and limits.
