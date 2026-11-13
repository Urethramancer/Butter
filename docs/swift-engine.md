# Swift engine architecture

Butter runs the local Swift package in production. The Objective-C++ bridge and
pinned libtorrent installation are optional reference-test tools, excluded from
the production binary. The immutable application reference is `v0.3.0`, commit
`e2268d90f7bd4960d100ab0b9da5997572c6651b`.

| Layer | Responsibility |
| --- | --- |
| `Butter/Core` and `TransferStore` | Preferences, saved app state, queue decisions, lifecycle and presentation |
| `Butter/Engine` | `EngineOperations` command boundary, Swift session adapter and snapshot mapping |
| `ButterTorrentMetadata` | Bencode, torrent/magnet identities, v1/v2/hybrid metadata and creation |
| `ButterTorrentNetworking` | TCP/µTP, encrypted peer streams, HTTP/UDP, trackers, discovery and router protocols |
| `ButterTorrentStorage` | Guarded payload access, hashing, selection, checkpoints and recoverable filesystem operations |
| `ButterTorrentEngine` | Session/transfer ownership, peer scheduling, upload admission and discovery integration |

## Application boundary

`EngineOperations` is defined in `Butter/Engine/EngineClient.swift`. Commands
accept validated payloads and return JSON `Data`; failures return Swift errors.
Creation progress and cancellation remain available while hashing. Snapshot
schemas live in `Butter/Core/Models.swift`, with package-to-app mapping in the
adapter. Keep schemas in source rather than duplicating their field lists here.

The store owns application `state.json`; the engine owns its transfer repository,
metadata, native checkpoints and operation journals. Invalid state must not be
overwritten by default state on failed startup. Asynchronous commands and exports
must settle exactly once across cancellation, timeout, removal and shutdown.

## Integrity and ownership

Payload access uses descriptor-relative traversal, component validation and
regular-file/identity checks. Publication, deletion and cross-volume moves use
durable journals and exclusive ownership claims; recovery preserves unexpected
replacement bytes. File selections and virtual padding participate in verification.
Explicit validation reads stored bytes and bypasses upload caches.

Package storage defaults remain strict. The app explicitly selects trusted
verified uploads and chooses restore policy from clean-shutdown state; interrupted
or uncertain data still requires validation. Checkpoint publication follows
payload flush barriers. Unfinished work must prevent an eligible clean shutdown.

Each storage owner is serial, while the shared worker pool admits independent
owners. Session resources bound disk admission and immutable upload caches.
Concurrent peer requests for one piece share its read. Production request-window,
cache and output-admission ceilings remain source-defined; experiments must not
silently increase them.

## Protocol and lifecycle coverage

The implementation supports v1, v2 and hybrid transfers, TCP/µTP, negotiated peer
encryption, metadata exchange, trackers, DHT/LSD/PEX and web seeds. Private torrents
suppress discovery even when metadata arrives after magnet import. Blocklists
apply to peer and tracker transports, including redirects and resolved endpoints.
Remote web-seed paths retain their original bytes separately from safe local names.

Session shutdown drains owned networking, storage and filesystem work. The
application's deadline covers polling, persistence and engine shutdown; expiry
refuses termination while unfinished work remains owned and recoverable.

See the root [README](../README.md) for build/test commands,
[audit results](audit.md) for resolved safety findings,
[validation scope](validation.md) for correctness limits, and
[performance results](performance/README.md) for current measurements.
