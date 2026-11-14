# Swift engine architecture

Production transfers use the local Swift package. The Objective-C++ bridge and
pinned libtorrent build exist only for optional reference tests and benchmarks.
The original application reference is `v0.3.0` (`e2268d9`).

| Layer | Responsibility |
| --- | --- |
| `Butter/Core` and `TransferStore` | Preferences, saved state, scheduling, lifecycle and presentation |
| `Butter/Engine` | `EngineOperations` commands, Swift session adapter and snapshot mapping |
| `ButterTorrentMetadata` | Bencode, identities, magnets, metadata and creation |
| `ButterTorrentNetworking` | Peer transports, HTTP/UDP, trackers, discovery and router protocols |
| `ButterTorrentStorage` | Guarded payload access, hashing, selection, checkpoints and file operations |
| `ButterTorrentEngine` | Sessions, transfers, peer scheduling and upload admission |

## Commands and state

`EngineOperations` in `Butter/Engine/EngineClient.swift` accepts validated commands,
returns JSON `Data` and reports Swift errors. Snapshot models live in
`Butter/Core/Models.swift`; field definitions stay in source. Creation exposes
progress and cancellation while hashing.

The store owns `state.json`; the engine owns metadata, checkpoints and journals.
Failed startup must not overwrite invalid state with defaults. Commands and
exports settle exactly once through cancellation, timeout, removal and shutdown.

## Integrity and resources

Payload access validates path components, file types and identity through
anchored descriptors. Filesystem changes use durable journals and exclusive
claims; recovery preserves unexpected replacement bytes. Selection and virtual
padding participate in verification. Checkpoints follow payload flush barriers.

Storage defaults remain strict. The app opts into trusted verified uploads and
chooses restore policy from clean-shutdown state. Explicit validation always
hashes stored bytes and bypasses upload caches. Uncertain or interrupted data
requires validation before advertisement.

Each storage owner is serial; a bounded shared worker pool admits independent
owners. Session budgets bound disk work, download buffers and immutable upload
caches. Peer requests for one piece share its read. Limits stay source-defined;
experiments must preserve production request windows and filesystem observations.

## Protocols and shutdown

The engine supports v1/v2/hybrid transfers, TCP/µTP, peer encryption, metadata
exchange, trackers, DHT/LSD/PEX and web seeds. Private torrents suppress discovery,
including after magnet metadata arrives. Blocklists cover peers, trackers,
redirects and resolved endpoints. Remote web-seed names remain separate from safe
local paths.

Session shutdown drains owned networking, storage and filesystem work. The app's
single deadline includes polling, persistence and engine shutdown; expiry refuses
termination while recoverable work remains owned.

See [package APIs](../Packages/ButterTorrent/README.md), [audit results](audit.md),
[validation](validation.md), [performance](performance/README.md) and [TODO](../TODO.md).
