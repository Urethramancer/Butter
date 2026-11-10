# Swift engine replacement

Production still uses libtorrent. Cut-over requires all twelve phases and the
complete acceptance suite; completing a utility does not enable Swift transfers.
Keep layouts, `EngineOperations`, scheduling and completion policies unchanged.

## Reference and comparison boundary (phase 1)

Completed and tagged `v0.4.0`.

The immutable application reference is `v0.3.0`, commit
`e2268d90f7bd4960d100ab0b9da5997572c6651b`. Do not move the tag. Its bootstrap
pins libtorrent `6da363d2994f17c0b3c0450d124cf73a31a73847` (2.1.2), Boost
1.88.0, OpenSSL 3.5.9 and try_signal
`105cce59972f925a33aa6b1c3109e4cd3caf583d`. Build the reference in a separate
checkout when production no longer includes it; reference dependencies remain
optional developer tooling after cut-over. Following the updated release
instruction, create an annotated minor tag after each completed phase, beginning
with `v0.4.0` for phase 1. Keep tags local; preserve `v0.3.0`.

`EngineOperations` in `Butter/Engine/EngineClient.swift` is the app boundary:
immutable JSON commands return `Data`; snapshots decode into `EngineSnapshot`;
creation progress and cancellation remain callable during hashing. The bridge
serialises commands and alert draining on its private queue. Each completion must
settle once, including overlapping exports, removal, failure and shutdown.
Swift errors currently become `NSError(domain: "Butter.Engine", code: 1)` with a
human-readable description. Compare error categories and effects, not upstream
error wording, transient rates, peer order or timing-dependent progress.

### Commands

All payloads are objects. String fields reject null characters. IDs contain only
ASCII letters, digits, hyphens and underscores, with length 1–128. Numeric fields
must be finite whole numbers within signed 32-bit bounds. Path mappings require
an index and a path. Wrong types must reject without publishing a transfer.

| Command | Payload and result/effect |
| --- | --- |
| `inspect` | `source` torrent path → name, private flag, indexed files (path, size, pad), hashes |
| `create` | `id`, `source`, `private`, `trackers` → stored torrent `source`, source parent `destination`; hybrid, excludes symlinks; private requires trackers; cancellation writes no metadata |
| `add` | `id`, `source`, absolute `destination`; optional `restore`, `selected`, `tracker`, review fields → id, duplicate, hashes (hashes omitted for duplicate); always initially paused; copies metadata before publication |
| `settings` | `port` (0 selects a port), `peers`, `torrentPeers`, `utp`, optional `tcp`, `dht`, `lsd`, `pex`, optional `mapping`, `allowSameIP` → requested port; observed binding arrives in snapshot |
| `blocklist` | ordered, same-family inclusive `ranges` of `first`/`last` → replace IP filter |
| `run` | `id`, `running`, optional byte/s `downloadLimit`/`uploadLimit` → resume only without pending filesystem work or errors; otherwise pause |
| `pause`, `save` | `id` → request durable resume data (`pause` also pauses) |
| `retry`, `recheck` | `id` → clear errors; persist journal or force verification respectively |
| `connect` | `id`, `address`, `port` → explicit peer connection |
| `select` | `id`, ordered 0/1 `selected` → priorities 0/4, request save |
| `tracker` | `id`, `tracker` → append and save; reject private/unresolved metadata |
| `magnet` | `id` → magnet with known v1/v2 hashes, current name and trackers |
| `export` | `id` → raw torrent bytes after asynchronous resume save; original info identity retained despite local renames; reject unresolved metadata |
| `rename` | `id`, `changes` of index/path → journal before async renames; reject duplicate indices, unsafe paths, collisions, shared sources and competing filesystem work |
| `move` | `id`, absolute `destination` → flush, validate all files, journal then async move; completion via event, retain source copies on ambiguous recovery |
| `remove` | `id`, optional `trash`, `retainState` → trashed receipt paths; ordinary removal retains data; reject pending filesystem work; Trash only contained regular unshared managed files |
| `forget` | non-live `id` → delete retained engine state only |
| `shutdown` | empty → pause all, flush/save with 15 s deadline; errors are retryable; does not destroy session or forget transfers |

Other successful mutations return `{}`. Missing live IDs fail. Unknown commands
fail (a missing ID can fail before command dispatch). Private torrents ignore
favourite trackers and disable DHT, PEX and LSD both on import and metadata arrival.

### Snapshots and persistence

The precise Codable schema lives in `Butter/Core/Models.swift`; use that schema
in comparisons, avoiding a second copy. Top-level fields are transfers, events,
port, udp, networkError and creationProgress. Events are drained on each snapshot:
`moved` (path), `moveFailed`, and `duplicate` (existingID). Transfers include
identity, name, save path, state/error, metadata/private/complete flags, progress,
wanted/done/total, payload rates, lifetime byte counters, remote demand, hashes,
pieces, files, trackers and peers. Hash order is v1 then v2, lowercase hex.
File indices include padding; original paths remain separate from local paths.
Piece display codes: 0 missing, 1 verified, 2 downloading, 3 available, 4 unavailable.
State precedence is downloading/resolving/checking/seeding, then paused, moving,
renaming. Completion means all *selected* data is complete, not every file.

`state.json` belongs to the app. Engine files are `<id>.torrent`, `<id>.resume`
and `<id>.paths.json`. The journal stores destination, original/current paths,
pending renames and pending move destination/file manifest. Atomic writes precede
publishing imports or filesystem operations. Restore reconciles journals against
disk, rechecks interrupted moves and pauses for review. Removal can retain state
until the app commits its record deletion. A shutdown save is the disk flush
barrier. Swift checkpoints will be versioned validated Codable records plus
compact verified-piece data and atomic operation journals. No legacy resume
importer is required; retain old state rather than silently rewriting it.

### Inherited protocol inventory

Verified against the pinned source (`src/settings_pack.cpp`, session constructor,
and the bridge), rather than assumed from the visible preferences:

- TCP and µTP incoming/outgoing are enabled by default. IPv4 and IPv6 share the
  requested port; no bind retries or system-port fallback. Hard peer limits have
  zero connection slack. DHT/LSD/router mapping stay off until settings are loaded.
- Default plugins are `ut_metadata`, `ut_pex` and `smart_ban`. Extensions include
  extension handshake, metadata exchange, PEX, fast extensions and v2 hash exchange.
  WebTorrent is disabled at build time.
- Both incoming/outgoing encryption policies are `pe_enabled`, allowed levels
  `pe_both`, `prefer_rc4=false`, with crypto-support announces. Preserve negotiated
  encryption/plaintext fallback, including legacy DH and RC4 interoperability.
- HTTP/HTTPS and UDP trackers, tracker tiers/failover, announce lifecycle and
  backoff are inherited. HTTPS tracker certificates are validated; tracker limits
  are 30 s completion, 10 s receive, 1 MiB response. Announcing to all trackers or
  all tiers defaults off. SSRF mitigation defaults on.
- BEP 17 HTTP seeds and BEP 19 URL seeds, ranges, redirects and retry/ban handling
  are inherited even though the UI does not configure them. Default maximum is
  three web-seed connections; name lookup retry is 1800 s.
- DHT (including bootstrap), LSD, UPnP and NAT-PMP are inherited. Private discovery
  flags are covered structurally; packet-observation acceptance remains required.
- v1, v2 and hybrid identities, padding, piece layers, selection, corruption
  recovery, upload serving, rate limits and resume/export behaviour are inherited.

These are replacement requirements, not claims of new Swift implementation.
Protocol sources: [BEP 3](https://www.bittorrent.org/beps/bep_0003.html),
[BEP 9](https://www.bittorrent.org/beps/bep_0009.html),
[BEP 52](https://www.bittorrent.org/beps/bep_0052.html) and
[BEP 29](https://www.bittorrent.org/beps/bep_0029.html).

### Headless comparisons

`Scripts/verify.sh contract` runs `EngineContractCases` against a supplied
`EngineOperations` factory. Its fixture is generated deterministically and covers
validation, hybrid inspection, duplicate identity, paused imports, selections,
magnet/export identity, retained-state restoration and ordinary removal. The
same scenarios must run against the Swift adapter when it exists. This is an
addition to the existing regression suites, not a replacement for them.

Keep `engine-validation`, `concurrent-exports`, `filesystem-failures`,
`metadata-variants`, `transfer-integration`, lifecycle, disk and interruption cases.
Port their shared assertions to the factory boundary as relevant Swift subsystems
arrive. Run both interoperability directions; Swift-only peers are insufficient.
Use bounded waits, disposable fixtures and no retries that hide failures. Record
throughput, CPU and memory on equivalent fixtures before cut-over; no performance
improvement is assumed. Reserve the full native UI suite for final integration.

## Metadata utilities (phase 2)

Completed and tagged `v0.5.0`.

`Packages/ButterTorrent` now provides the separately tested
`ButterTorrentMetadata` library: bounded binary bencoding, original info ranges,
incremental CryptoKit SHA-1/SHA-256, full identifiers, magnets and v1/v2/hybrid
inspection. The app compiles that target's source directory directly, as do the
existing headless builds; standalone consumers use the SwiftPM product. No
AppKit/SwiftUI or new bundled dependencies are introduced in the package.

`EngineClient` sends preview reads through a serial metadata actor and generates
magnets in Swift from current bridge-provided hashes, name and trackers. The
internal `magnetFields` command avoids draining snapshots or changing event
delivery. Transfer and creation commands still use libtorrent. The original
bridge `inspect`/`magnet` commands remain available to the reference harness.

`Scripts/verify.sh metadata` tests canonical/binary encoding, malformed inputs,
resource bounds, original info bytes, standard hash vectors (including a million
bytes), query escaping, Base32, invalid/conflicting identifiers, metadata layouts
and bounded disk reads. `metadata-reference` generates twelve independent cases
with libtorrent: six single/multifile v1/v2/hybrid cases plus six path-sanitisation
cases. It compares files, padding, private flags and full hashes, then imports
Swift-generated magnets into libtorrent. `contract` runs the same scenarios on
both the raw bridge and the Swift utility adapter. Existing lifecycle checks
exercise native previews and private tracker rules. Debug/Release build checks
include bundled notices and unchanged repeat-build checks. No native UI suite is
required at this stage.

Path sanitisation is adapted from the pinned implementation; attribution and BSD
terms live in the package's `THIRD_PARTY_NOTICES.txt` and the app's
`Butter/Licences/ButterTorrent.txt`. Retain these when removing the dependency.
Inspection checks piece-layer structure and retains its bytes; payload and Merkle
verification belong to creation/transfer phases. It never treats data as verified.
See the package README for explicit bounds and supported integer sizes.

## Hybrid creation (phase 3)

Completed and tagged `v0.6.0`.

`TorrentCreator` now builds hybrid metadata with bounded sequential hashing,
v1 piece hashes, v2 Merkle roots/piece layers, canonical ordering, padding,
private flags and tracker lists. Traversal includes empty and hidden files but
excludes symlinks. Descriptor-relative reads reject symlinked subdirectories and
files; size/timestamp changes during hashing fail the operation. It reads 16 KiB
blocks and bounds source counts, depth and retained hash lists before encoding.

`EngineClient` routes creation through one serial worker. Progress is observable
without blocking snapshots. Explicit and task cancellation settle once; failed
or cancelled hashing publishes no metadata. An atomic write under the worker
state lock orders cancellation against publication. Output collisions fail
without overwriting metadata. Publication failure releases the worker for retry.
Shutdown waits for an active creation result to settle. The response still
returns the source parent so the existing store seeds in place.

`Scripts/verify.sh creation` checks response/progress, cancellation before work,
publication failure and retry, then transfers eight generated fixtures through
libtorrent and verifies every file byte after shutdown's flush barrier. Cases
cover single/multifile layouts, empty files and 16/32/64 KiB pieces; v2-only
derivatives force independent Merkle verification as well as hybrid transfers.
Package tests additionally cover fixed payload hashes, symlink/cycle exclusions,
private trackers, cancellation during hashing and source mutation. Existing
contract and lifecycle suites cover creation in place, completion policies and
private tracker restrictions. Debug/Release, linkage, bundled notices and
unchanged repeat-build checks are required before tagging the phase.

Creation emits both identities; transfer traffic still belongs to libtorrent.
Throughput/CPU/memory comparisons and full UI acceptance remain later gates.

## Contained HTTP services (phase 4)

Completed and tagged `v0.7.0`.

The package's `ButterTorrentNetworking` product provides a bounded Foundation
HTTP transport, HTTP/HTTPS trackers, tier/lifecycle management and BEP 17/19 web
seeds. The app and its transfer backend are unchanged. The package integration
harness creates native metadata, announces to a local tracker, downloads through
both web-seed protocols (including redirects, Unicode paths and padding), verifies
every piece against its v1 hashes and only then announces completed/stopped.

Transport limits apply while receiving data, including chunked responses. TLS
certificate validation stays with Foundation. Redirects have a fixed count, reject
non-HTTP schemes, embedded credentials and HTTPS downgrades, strip authentication,
and retain range headers. Request counts, headers, timeouts and decoded response
bodies are bounded. Cancellation cancels the underlying URLSession and settles
the continuation once. Reserved announce query fields cannot be supplied by a
tracker URL; unrelated passkeys retain their original escaping.

Tracker responses support compact IPv4/IPv6 and dictionary peers, failure/warning
messages, interval/minimum interval, tracker IDs and counts. Tiers shuffle once,
promote a successful member and fail over in order. Announce lifecycle includes
initially complete seeds, completed events after verification, and stopped events
for all contacted trackers. Busy commands reject explicitly. Cancellation does
not trigger failure backoff. Web-seed errors use bounded retry delays and 503
retry hints; corrupt sources are banned and pending responses discarded. Clock
and transport injection make state/failure cases deterministic without sleeping.

`Scripts/verify.sh http` runs twenty focused service tests. Ordinary package tests
run forty tests across both products. Tests cover real loopback HTTP and untrusted
TLS, malformed/oversized responses, redirect loops and unsafe schemes, deadline
and in-flight cancellation, peer formats, lifecycle, tier promotion/failure,
range validation, retry hints, bans and the integrated metadata-to-HTTP scenario.
Concurrency-sensitive cases additionally run five times without retries. Release
package tests/builds are the build gate; no app/UI change requires native UI tests.

At the phase 4 boundary, the library checked literal local addresses and loopback announce paths.
DNS-result policy and connection pinning (including DNS rebinding) belong to the
shared networking foundation in phase 5, and remain a production-enablement gate.
The TLS fixture proves untrusted certificates are rejected; no successful
public-CA HTTPS interoperability or network hardware pass is claimed. Phase 5
below supersedes the Foundation transport and closes the DNS-pinning gate.

Protocol references: [BEP 3](https://www.bittorrent.org/beps/bep_0003.html),
[BEP 12](https://www.bittorrent.org/beps/bep_0012.html),
[BEP 17](https://www.bittorrent.org/beps/bep_0017.html) and
[BEP 19](https://www.bittorrent.org/beps/bep_0019.html).

## Shared networking foundations (phase 5)

Completed and tagged `v0.8.0`.

`ListeningPort` owns TCP and both UDP families on one port. Partial binding rolls
back, incoming/outgoing TCP share a hard peer budget, and shutdown closes opening
and established peers and waits for listener/socket release. Streams bound reads
and writes, prohibit overlapping same-direction I/O and settle cancellation,
deadline and callbacks once. Numeric endpoints preserve IPv6 scopes. Interface
and gateway discovery use system APIs without sending probes. DNS has four
bounded system workers per resolver and sixteen answers; cancellation releases
the caller but retains the worker slot until libc returns.

The user explicitly chose Network for HTTP/TLS instead of the planned Foundation
transport with a local CONNECT relay. `NetworkHTTPTransport` resolves once per
hop, validates every answer and connects to numeric endpoints. TLS retains the
original hostname and system certificate validation. Mixed public/local answers,
public-to-local redirects and unsafe resolved loopback tracker paths fail before
connection. HTTP/1 framing handles fragmented headers, informational responses,
fixed/chunked/EOF bodies and bounded gzip/deflate via Apple's system zlib. The old
`FoundationHTTPTransport` name remains an alias. No bundled dependency was added.

The UDP dispatcher bounds transactions and subscribers, checks source endpoints
and transaction identifiers, and routes DHT/µTP packets for their later protocol
phases. UDP trackers implement BEP 15/41, connection expiry and retransmission;
the combined client uses existing HTTP tier/event management. BEP 14 discovery
uses explicit multicast interfaces, public-metadata registration, cookies and
rate limits. Private or unknown metadata does not authorise advertisements.

NAT-PMP and UPnP clients provide external-address queries, mapping, renewal,
reboot detection and removal. SSDP description URLs must match the responding
numeric address. XML bounds reject entity declarations and external resolution;
control URLs retain the gateway origin. UPnP checks ownership before replacing,
renewing or deleting mappings. Callers drive periodic operations explicitly.
The pinned reference also attempts PCP before NAT-PMP; matching that inherited
behaviour remains recorded for complete-engine integration.

`Scripts/verify.sh network` (also available as `http`) runs the headless networking
harness. Debug and Release package suites cover 46 networking and 20 metadata/
creation tests. Real loopback fixtures cover both IP families, HTTP/TLS rejection,
UDP trackers, HTTP-to-UDP failover with started/completed/stopped events on the
owned port, and UPnP SOAP. Injected packets/clocks cover loss, retries, connection
expiry, source filtering, discovery restrictions, router errors and reboot/lease
recovery. Framing tests cover malformed and compressed responses. Concurrency
cases run five independent times without retries, including cancellation, shared
peer limits, concurrent shutdown, partial-bind rollback, immediate port reuse and
simultaneous SSDP ticks. Discovery reserves its throttle before subscription
suspends; concurrent initial LSD registrations reject as busy.

Production transfers remain on libtorrent. No LAN multicast, real router,
successful public-CA HTTPS, UI or throughput/CPU/memory acceptance pass is claimed.
Storage, transfer protocols and final engine integration remain phases 6–12.

Protocol references: [BEP 15](https://www.bittorrent.org/beps/bep_0015.html),
[BEP 41](https://www.bittorrent.org/beps/bep_0041.html),
[BEP 14](https://www.bittorrent.org/beps/bep_0014.html),
[RFC 6886](https://www.rfc-editor.org/rfc/rfc6886) and
[UPnP WANIPConnection v2](https://upnp.org/specs/gw/UPnP-gw-WANIPConnection-v2-Service.pdf).

## Storage and recovery foundations (phase 6)

Completed and tagged `v0.9.0`.

`ButterTorrentStorage` supplies piece-to-file mapping, virtual padding, selective
storage, verification and durable recovery without AppKit or SwiftUI. Opening and
all I/O run on one shared serial disk/hash worker, bounded to eight pending
commands per session and sixty-four globally. Commands settle once; cancellation
is checked between bounded blocks and filesystem transaction steps. Reads/writes
are at most 1 MiB; hashing/copying uses 64 KiB blocks. Layout limits are 50,000
files, 400,000 pieces and 16 MiB pieces. Selected empty files are retained.

Skipped-file bytes use private per-file spill storage so a piece spanning a file
boundary can still be verified. Selecting a spilled file journal-moves it to its
normal path. Deselecting an already materialised file retains its bytes. Path
components, normalisation/case collisions and file/directory conflicts are
validated before I/O. Descendant traversal uses descriptor-relative `O_NOFOLLOW`
opens; nonregular files and destructive access to hard links fail. A shared
coordinator reserves paths, including absent files, across live transfers. An OS
lock protects each checkpoint directory. Payload and checkpoint paths cannot
overlap.

The version 1 Codable binary-property-list checkpoint retains standard torrent
metadata, selections, renamed paths, destination, counters, Trash receipts, file
identity/timestamps and a compact verified-piece bitset. Record versions, counts,
paths, identities, spare bits and counters are validated on restore. Cached pieces
are rehashed before opening finishes: filesystem stamps alone cannot establish
integrity on coarse filesystems. Changed or missing bytes invalidate affected
progress. Verified reads hash the whole piece while retaining only the requested
range, so returned bytes belong to the checked content. V1 and hybrid verification
uses incremental SHA-1; pure v2 verification remains phase 8, and these bytes
cannot be advertised as verified. Previously verified progress is durably
invalidated before overwriting payload bytes. Failed invalidation does not touch
those bytes and must succeed before a later write. File and directory flushes
precede checkpoint publication; atomic replacement retains the previous record
on failure. Existing libtorrent state files are not imported or rewritten.

Imports copy and verify content without deleting their sources. Rename, move,
selection and Trash operations first validate all targets and persist a bounded
journal. Publication is exclusive; moves across volumes copy, flush and verify
SHA-256 before publishing. Source copies are removed only after the destination
checkpoint is durable. Journals record root/file identities and receipts and
survive failures at every operation boundary. Recovery suppresses ordinary I/O
and verified-piece advertising until reconciliation finishes. A copy published
before its durable receipt requires explicit `acceptMatchingCopies` review;
both paths remain intact until then. Conflicts, changed roots/content and unknown
journal versions fail conservatively without discarding files.

`Scripts/verify.sh native-storage` runs ten focused package tests plus a
disposable-image harness linked to the current library build. It kills real
children at 18 rename/import/selection/move/Trash boundaries, including partial
multi-file operations, cross-volume publication and source deletion. Every managed
byte is checked before recovery and every file/Trash receipt after recovery. Four
additional child interruptions verify atomic checkpoint generations. An actually
full HFS+ image proves ENOSPC preserves the prior checkpoint and verified payload;
freeing space restores writes. A read-only remount proves EROFS preserves state.
An edit after publication cannot inherit verified progress; corruption of a
cross-volume destination blocks original-file deletion. The complete Debug/Release
package suites cover 76 tests; storage cancellation and
worker-limit cases run five independent times without retries.

Production storage and transfers remain on libtorrent. Trash fixtures exercise
the real journal/copy/rename/removal path using disposable destinations; native
system destination selection and Finder interaction remain integration checks.
The next gate is v1 TCP transfers in both reference interoperability directions.
Cached-data rehashing and per-read piece checks trade throughput for a conservative
foundation. Immutable engine caches and disk scheduling need repeatable performance
measurement during transfer integration. No UI, sustained throughput or power-loss
hardware acceptance is claimed.

## TCP peer transfers (phase 7)

Completed and tagged `v0.10.0`.

`ButterTorrentEngine` exposes a headless `TCPTransfer` actor for v1 plaintext
downloads and seeding. Storage identity is checked before starting. Hosts own
listening ports and attach accepted streams; outgoing connections can share the
listening owner's peer budget. The application adapter and production backend
remain unchanged. No implicit tracker/discovery traffic is generated.

The bounded incremental codec handles fragmented/coalesced handshakes, keepalives,
choke/interest messages, bitfields, HAVE, requests, pieces and cancellation. It
validates frame lengths, indices, offsets, block sizes and spare bits, rejects
late/repeated bitfields and unnegotiated extension IDs, and enforces the expected
info hash and distinct peer identities. Handshakes advertise no extensions yet;
Fast/extended messages remain part of phase 8's negotiated capabilities.

Peers maintain request pipelines and upload-slot state. Rarest-first selection
prefers partially requested pieces, caps active pieces at eight and duplicates
only the final bounded endgame tail. Receipts cancel duplicate owners, tolerate
one late response per cancelled/expired request, and write through selective
storage before hashing. Only successful verification emits HAVE/completion.
Corrupt pieces reset; contributors close and known peer IDs are retained in a
bounded ban set. Chokes, disconnects and deadlines release reservations. Timeout
cooldowns let responsive peers make progress. Upload slots include rotation and
payload-contribution scoring; request and control floods have explicit bounds.

Uploads use a bounded immutable cache loaded through the storage layer's complete
piece hash check. At most eight pieces/32 MiB are retained, with four in-flight
loads of at most 16 MiB each. This avoids rehashing a disk piece for every block.
Per-transfer defaults are fifty peers, eight requests per pipeline and four upload
slots; hard maxima are two hundred peers, thirty-two pipeline requests, sixty-four
upload jobs and four disk permits. Peer output is bounded to 128 messages/512 KiB.
Payload token buckets share a monotonic injectable clock and allow a one-second
burst. Cancellation reaches rate waits, queued I/O, socket reads/writes and upload
jobs. Concurrent shutdown shares one operation, drains work, then checkpoints
counters; failed publication can be retried without erasing another retry's state.
Callers then close their storage and port owners.

`Scripts/verify.sh peer` runs eighteen cases covering framing, ranges, availability,
rarest-first/endgame behaviour, expiry, bidirectional loopback transfers, selective
file boundaries, malformed peers, corruption recovery, chokes, late replies,
queued-write cancellation, rate limits, peer/handshake limits, immutable caching
and concurrent/retryable shutdown. `peer-reference` additionally runs sixteen
independent v1 fixtures generated by the pinned libtorrent implementation. These
cover both directions, single/multifile layouts, 16/64 KiB pieces, selected files,
and byte-fragmenting relays over IPv4 and IPv6. Byte comparisons follow both
shutdown/flush barriers. Reference encryption and µTP are explicitly disabled;
no public network or discovery fixture is used.

Debug and Release package suites cover 94 tests. Concurrency-sensitive engine
cases run five times without retries, and a separate Thread Sanitizer run checks
the new engine paths. Production/UI integration remains phase 11; metadata/PEX/
DHT/Fast/v2, encryption and µTP remain phases 8–10. Aggregate memory/disk policy
and repeatable throughput/CPU/memory acceptance remain later gates; these small
fixtures establish correctness and interoperability, without a speed claim.

Wire references: [BEP 3](https://www.bittorrent.org/beps/bep_0003.html) and the
negotiation boundary in [BEP 6](https://www.bittorrent.org/beps/bep_0006.html).

## Metadata, discovery and v2/hybrid transfers (phase 8)

Completed and tagged `v0.11.0`.

The headless engine negotiates Fast, extension and v2 capabilities before decoding
their messages. Fast availability, allowed pieces, suggestions, explicit rejection
and cancellation share the bounded picker and upload queues. A cancelled request
receives either its already-started payload or one rejection, including cancellation
during a payload rate wait. Hybrid uploads accept the pinned reference's padded v1
request lengths after its handshake upgrades to v2; pure v2 requests retain file
boundary checks. Hosts can select v1 identities for legacy hybrid connections.

Extension handshakes support directional IDs, additive remapping and disabling,
with a cumulative map bound. Metadata exchange retains the exact original info
dictionary, verifies every supplied full magnet hash, bounds assembly to 32 MiB
per peer and runs at most four providers per resolver. A good provider cancels and
drains its competitors. Malformed, unsolicited, resized and poisoned metadata
fail before storage creation. Unknown metadata message types are ignored.

`MagnetDownload` owns resolution, storage, transfer and shutdown. The identity
registry aliases v1/v2 only after authenticating the complete info dictionary.
Reservations become visible duplicates only after the owning transfer opens;
failed storage releases its reservation so a waiting arrival can take ownership.
Cancelled publication waiters drain without taking ownership. Connection failures
remain available to the host. Metadata arrival never authorises DHT/PEX/LSD for
private torrents, and untrusted explicit magnet hints are not reconnected after
the metadata proves private. Private metadata providers suppress `ut_metadata`,
matching the pinned reference.

PEX handles bounded compact IPv4/IPv6 additions, removals and flags, with per-peer
memory and minute update limits. It advertises confirmed connected peers, preserves
unsent removals and exposes bounded discovery streams. Private PEX is neither
advertised nor accepted. DHT PORT hints also require negotiated, known-public
metadata. Discovery consumers and listening/UDP owners remain host responsibilities.

`DHTNode` implements BEP 5/32/42 on a shared dispatcher, one address family per
instance. Only registered public metadata can start searches or announces.
Routing buckets retain responsive, address-validated contacts; referrals must
answer a source/transaction-matched challenge before entering routing. Iterative
lookups have three parallel queries, at most 32 visited nodes, a 30-second budget,
four simultaneous searches and sixteen outstanding queries. Node/peer caches,
datagrams, subscriptions and incoming query rates have explicit bounds. Announce
tokens bind the source address, expire across two five-minute windows and cannot
register another address. Unknown external addresses require matching reports
from three independent network prefixes before replacing the node ID. Bootstrap
uses the pinned reference's `dht.libtorrent.org:25401`, with injectable endpoints,
DNS and clocks; tests send no public traffic. Shutdown cancels/drains DHT work
without closing the shared UDP transport.

The metadata/storage layers authenticate sparse SHA-256 Merkle proofs against
info-dictionary file roots before making pieces eligible. Hash responses are
solicited, geometry checked and bounded. Piece-layer and available leaf proofs can
be served to peers. Received hashes are atomically checkpointed before use;
restored records revalidate their root chains and identity. V2 downloads verify
16 KiB leaves and subtree padding; hybrid verification also checks SHA-1. Export
reconstructs complete authenticated piece layers while retaining original info
bytes. Missing hashes and poisoned proofs never become verified progress.

Debug and Release package suites cover 119 tests. Thirty-eight engine/DHT cases
run five times without retries, and an isolated Thread Sanitizer build covers
those paths. Native failure fixtures cover competing providers, private arrival,
publication handoff, corrupt proofs, recovery and cancellation during rate waits.
The real storage matrix still passes 18 killed-operation boundaries, four atomic
checkpoint interruptions, cross-volume corruption, ENOSPC and read-only volumes.

`peer-reference` now generates independent v1/v2/hybrid metadata with the pinned
libtorrent creator. Its 48 transfers cover both directions, single/multifile
layouts, 16/64 KiB pieces, selective files and fragmented IPv4/IPv6 streams.
Public magnets exchange metadata in both directions; native v2/hybrid downloads
start without piece layers and fetch authenticated hashes. Private transfers use
supplied metadata because the reference disables private metadata exchange. Two
additional DHT cases verify tokens, announces and returned peer endpoints in both
directions with libtorrent. Byte checks follow both engines' shutdown barriers.

Production remains on libtorrent. Automatic hybrid identity fallback and hybrid
magnets served exclusively by legacy v1 peers remain integration work in TODO.md;
the current native harness needs complete piece layers or a v2 hash provider.
No UI, public DHT, sustained throughput, CPU or memory comparison is claimed.
Encryption and µTP remain phases 9 and 10; aggregate policies, adapter integration
and final performance/dependency acceptance remain phases 11 and 12.

Protocol references: [BEP 5](https://www.bittorrent.org/beps/bep_0005.html),
[BEP 6](https://www.bittorrent.org/beps/bep_0006.html),
[BEP 9](https://www.bittorrent.org/beps/bep_0009.html),
[BEP 10](https://www.bittorrent.org/beps/bep_0010.html),
[BEP 11](https://www.bittorrent.org/beps/bep_0011.html),
[BEP 27](https://www.bittorrent.org/beps/bep_0027.html),
[BEP 32](https://www.bittorrent.org/beps/bep_0032.html),
[BEP 42](https://www.bittorrent.org/beps/bep_0042.html) and
[BEP 52](https://www.bittorrent.org/beps/bep_0052.html).

## Peer encryption compatibility (phase 9)

Completed and tagged `v0.12.0`.

`PeerStream` negotiates MSE beneath existing peer framing for incoming/outgoing
TCP transfers and magnet metadata. The engine still has one reader and one writer
per connection; cipher updates occur inside those owners, and failed writes close
the connection. Cancelled queued uploads do not consume stream-cipher bytes.
Shutdown cancels and drains outgoing negotiations, accepted peer sessions and arithmetic work before
checkpointing. Peer snapshots distinguish raw plaintext, negotiated plaintext and
RC4 payloads. Magnet resolution carries its configured encryption policy into
both metadata exchange and the resulting transfer.

The implementation uses the protocol's specific 768-bit modulus with 24 fixed
32-bit limbs and a 160-bit ephemeral secret from `SecRandomCopyBytes`. Montgomery
arithmetic is confined to this group, and rejects remote public values outside
`[2, p-2]`. Exponentiation performs both candidate multiplications for each secret
bit; this is a compatibility implementation, without a constant-time assurance.
Four global workers and 64 cancellable queued jobs bound arithmetic admission.
Handshake deadlines include queueing and computation, and expired/cancelled jobs
are drained before releasing their worker slots.

SHA-1 derivation uses CryptoKit; RC4 uses Apple's public CommonCrypto API and
discards the initial 1,024 bytes in each direction. No third-party cryptographic
library is introduced. Synchronisation scans and all four padding fields have
512-byte bounds. Initial application data is bounded to the protocol's 65,535
bytes, decrypted independently of the selected payload mode and retained for
normal framing. Candidates for either verified hybrid wire identity can select
the swarm. Unsupported methods, multiple selected methods, bad verification
constants, unknown swarms, oversized padding and truncated streams fail closed.

Defaults match the pinned reference: incoming/outgoing encryption enabled, both
payload methods allowed, and plaintext preferred when both are offered. Enabled
outgoing policy first attempts MSE, reserving half the remaining connection budget
for negotiation and allowing one fresh plaintext connection after failure.
Required policy never falls back, and cancellation or worker-admission exhaustion
does not downgrade. Incoming disabled policy rejects MSE; incoming required policy
rejects an ordinary plaintext handshake. Required negotiation may select a
plaintext payload when permitted; requiring RC4 also requires `.levels = .rc4`.
MSE provides legacy protocol obfuscation, not authenticated modern encryption.

The Debug/Release package suites cover 128 tests. Forty-seven engine, MSE,
arithmetic-worker and DHT cases run five independent times without retries.
Thread Sanitizer covers those paths in an isolated build. Fixed DH and RC4 vectors
were cross-checked with Go's standard library; only vector data is embedded, with
no Go runtime or build dependency. Fixtures check degenerate public values,
fragmented maximum-padding handshakes, initial payloads, both negotiated methods,
illegal selections, exact malformed-message errors, queue exhaustion, queued
deadlines, cancellation and shutdown. An encrypted Fast fixture cancels a payload
already waiting for rate tokens, observes exactly one rejection and then reads a
second successful response to prove cipher alignment is preserved.

The expanded reference harness passes 156 independent transfers: 48 ordinary
plaintext, 48 required RC4, 48 negotiated plaintext, six preferred-RC4 and six
plaintext-fallback cases. Both initiator directions and all v1/v2/hybrid identities
are represented. Public metadata exchange, sparse hash exchange, private/public
layouts, selective files and 16/64 KiB pieces remain covered. IPv4/IPv6 relays split
the first 2,048 encrypted-handshake bytes into individual writes, followed by
fragmented payloads. Assertions inspect both engines' negotiated modes as well as
payload counters and bytes after their shutdown barriers. Reference fixtures keep
completed connections open for those mode assertions. Both DHT interoperability
directions also still pass. A final 30-case subset rechecks all policies after the
deadline/admission changes.

Sanitizer instrumentation exposed fixture timing assumptions: three-second fake
peer deadlines were too short for concurrently instrumented arithmetic, and
legacy fixed-connection fixtures could consume their accept allowance on an MSE
fallback. Fake peers now allow ten seconds and require the exact invalid-protocol
error; legacy plaintext fixtures choose plaintext explicitly. Separate required
encryption and fallback fixtures retain coverage of the new paths.

Wire behaviour is checked against the pinned reference's
[peer handshake implementation](https://github.com/arvidn/libtorrent/blob/6da363d2994f17c0b3c0450d124cf73a31a73847/src/bt_peer_connection.cpp)
and [key exchange implementation](https://github.com/arvidn/libtorrent/blob/6da363d2994f17c0b3c0450d124cf73a31a73847/src/pe_crypto.cpp).
The fixed-width arithmetic and framing are native Swift implementations; the
reference remains optional comparison tooling. Production transfers still use
libtorrent. µTP, application integration and consolidated performance/dependency
acceptance remain phases 10–12. No UI or throughput/CPU/memory comparison is claimed.

## µTP (phase 10)

Completed and tagged `v0.13.0`.

`UTPTransport` owns one µTP subscription on an existing UDP dispatcher. TCP and
µTP implement `PeerByteStream`, so the same peer framing, metadata exchange,
encryption, uploads and verification run over either transport. Explicit µTP
connections and their encryption fallback never open TCP. Peer snapshots and
PEX flags report the observed transport. Production still uses libtorrent;
automatic transport selection and the application adapter belong to phase 11.

The BEP 29 state machine handles wrapping sequence numbers, cumulative and
selective acknowledgements, duplicate suppression, reordered data, reliable FIN,
fast retransmission, bounded exponential timeout and receive-window probes. Delay
history drives LEDBAT-style window adjustment; timeout reduces the window and
packet size. Retransmissions preserve each packet's sequence and payload. Payloads
are at most 1,180 bytes; this phase does not implement path-MTU discovery.

Defaults allow 50 connections, with a configurable ceiling of 200, and share the
existing peer-budget leases. Receive buffers are bounded to 256 KiB per connection
and 16 MiB per owner, including reordered data. A write is at most 1 MiB, with one
pending writer per stream. Aggregate admission reserves twice each pending write's
size, bounded to 16 MiB, covering retained input and packet copies. Reordering is
limited to 128 packets, outstanding packets to 256 and sequence distance to 16,384.
The accept queue holds 32 connections; the outgoing queue holds 512 packets. The
owned UDP subscription buffers 256 datagrams, each bounded to 4,096 bytes, with
at most eight extension headers. Queue overflow becomes packet loss handled by
retransmission. Invalid or unmatched traffic cannot create unbounded state or
reset reflection; reset output is rate-limited.

Cancellation, deadlines, reset, dispatcher failure and engine shutdown settle
pending reads, writes, opens and accepts. Shutdown drains transport tasks, releases
leases and removes the owned subscription while preserving other UDP services.
Ownership release also removes a subscription that was cancelled before iteration
began. A completed stream retains EOF after its protocol record expires. Magnet
metadata sessions drain before opening payload connections, permitting a hard
one-peer limit without leaking the metadata slot.

Deterministic injected-packet fixtures cover SYN/SYN-ACK/data/FIN loss, delay,
duplication, reordering, sequence wrap, stale window updates across timestamp wrap,
zero-window recovery, blackholes, spoofed endpoints, receive and aggregate write
bounds, cancellation and stable EOF. Real IPv4/IPv6 UDP fixtures share the port
with DHT transactions and verify ownership replacement. Headless v1/v2/hybrid
metadata and payload transfers run with plaintext and required RC4, including
one-peer limits and shutdown during an unanswered SYN.

The independent reference harness disables TCP on both peers for its µTP cases.
Its relay loses an initial SYN in one initiator direction and an initial SYN-ACK
in the other, then drops selected data and injects delay, duplication and
reordering. The pinned reference abandons an unconfirmed handshake and
may reconnect with a new connection ID; fixtures accept continuously and inject
one initial control loss, rather than rejecting every reconnect. Both engines'
transport and encryption modes, counters and final bytes are checked.

Packet traces exposed an interoperability difference: libtorrent emits selective
ACK bitmaps shorter than BEP 29's four-byte minimum. The reader accepts nonempty
bitmaps through the extension's 255-byte length limit, while outgoing bitmaps
remain padded to four-byte units. A wire regression checks compact and maximum
lengths, cumulative progress and selective removal. Dropping those ACKs had caused
repeated retransmission of bytes already received; the failure is recorded rather
than treated as a timing retry. Delayed window advertisements also cannot replace
a newer timestamped advertisement.

Debug and Release suites pass 148 package tests. The 68-test µTP, engine, MSE and
DHT subset passes five independent fail-fast runs and an isolated Thread Sanitizer
build. An initial sanitizer run overlapped other builds and exceeded existing
five/eight-second encryption-fixture deadlines; those two fixtures now allow a
bounded 15 seconds. Production deadlines are unchanged. The adjusted fixtures
also pass under the sanitizer.

Reference acceptance totals 312 peer comparisons: 156 TCP cases and 156
TCP-disabled µTP cases, including 36 impaired µTP cases. All five encryption
policies, both transfer directions, v1/v2/hybrid identities, magnets, selective
files, IPv4/IPv6 and 16/64 KiB pieces are represented. Both independent DHT
announce/lookup directions also pass. The µTP matrix was rerun in full after the
compact-ACK fix; the TCP baseline passed separately before that µTP-only change.

Protocol references are [BEP 29](https://www.bittorrent.org/beps/bep_0029.html)
and the pinned reference's
[µTP stream implementation](https://github.com/arvidn/libtorrent/blob/6da363d2994f17c0b3c0450d124cf73a31a73847/src/utp_stream.cpp).
This is an independent Swift implementation. No throughput, CPU, peak-memory,
public-network or UI acceptance is claimed. Consolidated measurements and
dependency removal remain phase 12.

## Session integration foundations (phase 11, in progress)

`TransferResources` now shares disk admission and immutable upload-cache capacity
across native transfers. Defaults admit eight disk operations and bound cached
bytes plus reserved loads to 64 MiB. Per-transfer disk admission remains four;
closing one scope does not close the shared budget. A global LRU evicts cache
entries across owners, and capacity waits are bounded and cancellable. Owner
closure cancels its loads and wakes its waiters while retaining other owners'
data. Borrowed immutable pieces and outbound peer buffers are separate from the
cache accounting; no process peak-memory measurement is claimed.

`ManagedTransfer` owns storage and the current peer controller. It serialises
storage commands, drains negotiations, readers, uploads, rate waits and disk work
before mutation, then reopens a controller from the resulting verified checkpoint.
Selection, rename, move, recovery and recheck use that boundary. A rejected
preflight can resume safely; a pending journal or failed pause keeps I/O stopped.
Failed checkpoints prevent mutation and remain retryable. Exports retain the
original identity and serialize with filesystem commands. Removal can quiesce
before Trash and release storage ownership through an idempotent close.

Headless integration fixtures exercise a rename during a real rate-limited
upload, verified seeding afterwards, overlapping exports/rename/move/selection,
checkpoint-path failure and retry, and pause during an unanswered MSE negotiation.
Controlled real disk reads verify cache-memory admission, queued cancellation and
independent owner closure. The application adapter, service/session orchestration
and remaining phase 11 TODOs are unfinished; production remains on libtorrent and
no phase 11 tag has been created.

Verification for these foundations: all 155 package tests pass in Debug and
Release. The 12 ownership/resource cases pass under Thread Sanitizer and five
independent fail-fast runs. Twenty-four representative reference transfers pass
in both directions across TCP and TCP-disabled µTP, plaintext, required RC4 and
negotiated plaintext, including fragmented/impaired IPv6 paths. This is focused
regression evidence, not the complete phase 11 acceptance suite.

### Native command adapter

`SwiftEngineClient` now translates the existing `EngineOperations` boundary into
typed `TorrentSession` operations. The shared headless contract runs against
libtorrent, the production utility adapter and this native adapter. It covers
import defaults, validation, duplicate IDs and identities, selection, magnet
generation, exports, rename, move events, retained-state restore and ordinary
removal. The native adapter is compiled when the package module is available;
the application still constructs its existing libtorrent client.

Native imports reserve repository publication before opening isolated checkpoint
directories, recheck available bytes and publish only after storage opens.
Prepared checkpoints retain their directory descriptor. Publication and cleanup
check directory identities and use nonblocking filesystem leases; a second
session cannot discard a live checkpoint. Unknown files, substituted directories
and pending payload journals are retained for review. Legacy resume files are
not imported or deleted. Native creation shares the publication lease and uses
exclusive publication for a new torrent file. Caller cancellation drains cleanup;
cleanup failures are reported, and a visible published checkpoint is retained
even if publication's final directory flush failed.

Session snapshots map verified file/piece progress, selections, paths, counters,
peer endpoints/client names, transport flags and demand into the existing app
models. Rates use bounded counter deltas. External file invalidation retires the
old peer controller before reopening from verified storage, preventing stale
completion advertisements. Sparse v2/hybrid imports can save checkpoints before
piece layers arrive; exports reject incomplete layers, then succeed after hash
exchange. Restarts retain downloaded counters and authenticated hashes. Tracker
edits retain exact info bytes and persist without changing the torrent identity.

Verification passes 165 package tests in Debug and Release, 22 focused ownership
and session tests under Thread Sanitizer and five independent fail-fast runs,
the expanded three-backend contract, and the existing creation checks including
eight independent libtorrent transfers. Passing test logs now delete automatically;
failed and interrupted runs retain diagnostics. These are incremental phase 11
checks. Subsequent settings, blocklist, peer routing and tracker work is recorded
below. Magnet-import commands, remaining network-service orchestration,
responsive long-running operations and repository
interruption/disk-failure acceptance remain in TODO.md. No phase 11 tag, UI
acceptance, production cut-over or performance claim is made.

### Shared peer ownership and tracker lifecycles

The native session now owns a dual-stack listening port and shared UDP dispatcher,
routes TCP and µTP connections to running swarms, and selects encrypted swarms
through an indexed MSE catalogue. Incoming negotiation, unidentified connections,
same-address admission and total peers have explicit bounds. Settings and
blocklists drain affected peers before rebuilding controllers; unchanged fixed-port
settings preserve pending handshakes. At this stage the adapter rejected enabled
DHT, LSD and mapping; DHT integration follows below.

Automatic port allocation checks both TCP and UDP ownership. A TCP ephemeral port
can already be occupied by an unrelated UDP socket. Only this automatic-port
collision selects another candidate, with eight attempts and one overall deadline;
explicit port conflicts still fail. A deterministic occupied-UDP fixture verifies
that the abandoned TCP listener is released.

Each running torrent now owns a tracker lifecycle using the session peer ID and
listening port. HTTP/HTTPS clients and UDP trackers share tier failover, backoff,
started/completed/stopped events and per-URL messages. Replies feed a bounded peer
queue with two concurrent connection attempts. Private torrents accept peers from
their verified metadata's trackers. Appending a tracker preserves info bytes and
the existing announce lifecycle. Pause, settings changes, removal and shutdown
cancel and drain active announces and peer connection attempts. Final announces
share four slots and a three-second deadline including admission.

Tracker `left` counts all unverified pieces, including unselected files; completing
a selection does not announce a complete torrent. Persistent totals survive
restart, while announce counters subtract the session import baseline. Counter
accounting for corrupt/redundant bytes and hybrid dual-identity announces remain
unfinished. Discovery and router mapping still need session wiring. Web-seed
integration follows below.

Session interoperability adds 36 independent libtorrent transfers: TCP/µTP,
disabled/required RC4/negotiated plaintext, v1/v2/hybrid metadata and both
directions. The complete reference harness now contains 348 peer cases plus two
DHT comparisons; `BUTTER_REFERENCE_FILTER=session` selects the new session cases.

Verification passes 182 package tests in Debug and Release, 33 focused session,
peer-admission and tracker tests under Thread Sanitizer and five independent
fail-fast runs, the three-backend app contract and all 36 session/libtorrent
comparisons. These checks do not complete phase 11; no new tag or production
backend switch is made.

### Session-owned web seeds

Native transfers now fetch BEP 19 file ranges and BEP 17 piece ranges through
the same picker, storage admission and hash verifier as TCP/µTP blocks. URL seeds
support v1, v2 and hybrid metadata; HTTP piece seeds require a v1 identity and
therefore support v1/hybrid torrents. Sparse v2 downloads wait for authenticated
piece hashes. Original metadata paths form remote URLs even after local renames.
Padding is generated locally for URL seeds, and selective boundary data uses the
existing storage safeguards. Only verified pieces are advertised or checkpointed
as complete. Corrupt contributors are disabled, with bans retained by the managed
owner across pause and storage/controller changes.

One worker per transfer uses at most three shared HTTP request slots and a
bounded admission queue. It requests at most 16 KiB per range, honours source
backoff and consumes the existing download rate limiter after releasing the HTTP
slot. Counters include each successful response even when a later file range
fails, and exclude locally generated padding. Pause, removal, storage changes and
shutdown cancel and drain HTTP, rate waits and disk writes before changing files.
Active web seeds appear in the existing peer display; package snapshots also
expose per-source errors and ban state. Native HTTP transports apply the current
address filter to pinned DNS endpoints at every redirect hop, after draining old
requests on settings changes.

The local interoperability harness now downloads through real HTTP redirects and
chunked responses, then seeds those verified files into libtorrent using metadata
without web-seed URLs. Ten cases cover single/multi-file layouts, all three
metadata formats for URL seeds and v1/hybrid piece seeds. Select them with
`BUTTER_REFERENCE_FILTER=webseed`. The complete reference harness now contains
358 transfer cases plus two DHT comparisons. HTTP connections currently close
after each range; request coalescing and performance measurements remain phase 12
work. Source failure/ban state is runtime state and is not stored in checkpoints.

Verification passes 190 package tests in Debug and Release, 39 focused HTTP,
session and storage/peer tests under Thread Sanitizer and five independent
fail-fast runs, the shared three-backend command contract and all ten new
HTTP/native/libtorrent comparisons. The entire 358-case reference matrix has not
been rerun for this slice. Phase 11 remains in progress, with no new tag or
production cut-over.

### Session-owned DHT discovery

The native DHT setting now owns one node per address family on the session's
existing UDP dispatchers. Running public transfers announce the actual owned
listening port and feed discovered endpoints into the existing TCP/µTP admission
path. Private identities remain forbidden even when their imports are paused
beside running public transfers. Empty and private-only sessions perform no
outgoing DHT searches. Loopback-only sessions use an empty bootstrap by default;
tests inject disposable local routers instead of using the public DHT.

At most two searches run per family. Successful searches recur after five
minutes; failures back off from 30 seconds to 15 minutes. The node retains its
15-minute announce interval. Unchanged Run commands preserve in-flight searches.
Pause, removal, settings changes and shutdown cancel and drain lookups, responder
work and connection attempts before changing discovery policy. The DHT metadata
registration bound now matches the session's 10,000-transfer limit. Endpoint
filters cover outgoing nodes, incoming queries, returned peers and referrals.
Discovery registration failures disable DHT with a diagnostic while leaving the
shared listening port available to the other services.

Trackers and DHT now reuse a bounded candidate queue, with at most 2,000 pending
items and two active connection attempts per queue. Session snapshots report DHT
contacts, searches and errors; the adapter maps failures into the existing network
diagnostic. Managed-controller PEX/PORT hints, local discovery, mapping and magnet
imports remain in TODO.md. The session does not enable the peer PORT extension
by default while its hint-consumption path is unfinished.

Twelve independent session/libtorrent transfers cover v1/v2/hybrid metadata,
TCP/µTP and both directions without explicit peer connections. The reference
fixture enables DHT only when given a local bootstrap, disables its public
bootstrap and records DHT-sourced peers. `BUTTER_REFERENCE_FILTER=session-dht`
selects these transfers and the two existing DHT protocol comparisons. The full
reference harness now contains 370 transfer cases plus those two comparisons.

Verification passes 199 package tests in Debug and Release, 26 focused tests under
Thread Sanitizer and five independent fail-fast runs, the three-backend app
contract, 12 DHT-discovered session transfers, both DHT protocol comparisons and
the existing 36 session peer transfers. Reference DHT cases use IPv4; native
loopback fixtures also cover IPv6. The full 370-case transfer matrix, UI and
performance acceptance have not been rerun for this slice. No phase 11 tag,
production switch or push is made.

## Managed peer discovery hints (phase 11)

Managed controllers now consume PEX and peer PORT streams through a generation
that changes whenever the peer engine is replaced. Pending work is cancelled and
drained on pause, storage changes, settings changes and shutdown. Session admission
rechecks the current owner, generation, running state, privacy and address filter
before opening a connection. The shared candidate queue bounds pending contacts
and simultaneous connection attempts. A missing PEX µTP flag does not prohibit
trying µTP when TCP is disabled.

PORT hints challenge the advertised DHT endpoint before using it, deduplicate
recent hints and trigger a new lookup through the resulting route. Only running
public torrents advertise the owned DHT port. Private torrents and disabled
discovery settings never send the hinted traffic. Native fixtures cover IPv6,
settings changes, stale generations and missing PEX capability flags.

The reference harness adds 24 PEX/PORT transfers across all metadata formats,
both transports and both directions. The introducer supplies no payload; PORT
cases have no external DHT bootstrap. All 24 pass against the unmodified pinned
reference. The complete harness now contains 394 transfers plus two DHT protocol
comparisons. This integration also exposed the active-piece starvation and crossed
µTP connection failures recorded in the audit. Package session suites share one
serial parent to respect the process-wide disk admission bound; individual cases
continue to exercise concurrent transfers and commands.

Verification passes 209 package tests in Debug and Release, nine focused tests
under Thread Sanitizer, the three-backend app contract, five fail-fast concurrent
engine-suite runs and five isolated reference runs of the previously failing
pure-v2 µTP case. Subsequent fixture work replaces its controlled MSE wait with a
gated µTP acknowledgement and aligns the reference provider's wait with the
metadata deadline. Five fail-fast runs in each of Debug, Release and Thread
Sanitizer pass all 94 engine tests with those configurations running concurrently.
The audit retains the earlier failures and explains the fixture changes. Failed
logs remain available; successful logs are removed automatically.

Magnet imports, local discovery, mapping and the
remaining phase 11 acceptance work stay in TODO.md. Production still uses
libtorrent. The user's latest release instruction authorises committing, tagging
and pushing each of phases 11 and 12 once its complete gate passes.

Private tracker integration now drains old peers and pending connections before
contacting a replacement, and keeps its successful tracker until failure across
tier boundaries. The failover audit records wire, cancellation, Debug, Release and
Thread Sanitizer verification.

Tracker payload accounting now persists corrupt and redundant byte totals alongside
raw traffic counters. HTTP/UDP download reports exclude unusable data, while UI
traffic totals remain raw. Checkpoints validate both counters against received
bytes, accept older records without the optional fields and preserve the totals
through pause and restart. The audit records padding, partial HTTP, corruption,
late-reply and malformed-checkpoint cases, all 215 Debug package tests, 62 focused
Release/Thread Sanitizer checks, the shared app contract and 36 exact-payload
reference comparisons. The reference's late-metadata redundancy is checked
separately from file payload.

Hybrid tracker announces now cover the v1 SHA-1 and truncated v2 SHA-256 identities.
Each identity retains its own tracker ID, minimum interval, failure backoff and
completion event. Partial acceptance keeps the working swarm available; private
torrents use one shared tracker selection and drain peers once when switching
endpoints. Fresh responses share a bounded, interleaved peer list. Oversized lists
are sampled so neither swarm permanently excludes the other, and cached responses
never replay stale peer contacts.

Sixteen new private hybrid/libtorrent transfers use HTTP/UDP trackers as their only
peer source, across TCP/µTP and both directions. Half the trackers reject v2
registration; the v1 swarm still transfers successfully. Native port ownership,
both identifiers, completed/stopped events and flushed file bytes are verified.
`BUTTER_REFERENCE_FILTER=session-trackers` selects these cases, with an optional
`BUTTER_TRACKER_FILTER` substring. The harness now contains 410 transfers plus two
DHT protocol comparisons. All 223 Debug package tests pass, along with focused
Release/Thread Sanitizer tracker tests and the shared app contract. These are
incremental checks; the complete phase 11 acceptance gate remains open.

The updated magnet policy permits DHT lookup for unresolved magnets when DHT is
enabled. Discovery must be cancelled and drained when private metadata arrives,
before the resolved transfer is published to the app. Session magnet integration
and its race tests remain in TODO.md.

### Hybrid peer identity fallback

Outgoing hybrid transfers try the other wire identity once when the remote closes
or times out before its handshake. Required MSE encryption is retained across the
second connection; malformed identities and resource/admission errors do not
trigger a retry. Private tracker changes, pause and shutdown cancel and drain
opening retries. A v1 retry advertises the BEP 52 upgrade capability when enabled.

Focused real TCP/µTP tests cover plaintext and required RC4 transfers, both rejected
identities, single-identity torrents and cancellation during alternate plain/MSE
handshakes. Four new libtorrent comparisons force v1 framing for hybrid multi-file
torrents at two piece sizes, checking all file bytes after shutdown in both
directions. Select these with `BUTTER_REFERENCE_FILTER=identities`. The reference
harness now contains 414 transfers plus two DHT protocol comparisons.

The broader engine run passed 100 tests before a subsequent run exposed a session
DHT deadline failure and an ephemeral TCP bind collision. These retained failures
remain acceptance work; they are not hidden by automatic retries. Phase 11 remains
in progress and production still uses libtorrent.

### Explicit unresolved-magnet DHT lookup

`DHTNode.setTorrents(_:unresolved:)` accepts bounded, explicit unknown identities.
`getPeers(for: Magnet)` permits lookup without announcing an unresolved transfer.
Registered private metadata overrides unresolved registrations, cancels and drains
outstanding queries, and clears cached peers before returning. The default remains
no unknown discovery unless the owner registers it; session settings must opt in.

IPv4/IPv6 fixtures now discover an announced peer through an unresolved magnet.
An injected pending lookup verifies that private metadata prevents a second send,
drains the dispatcher and denies later lookups even if the unknown registration
is retained. The optional headless libtorrent DHT comparisons use this API too.
Session pending rows and metadata publication remain separate integration work.

The session-discovery deadline exposed a crossed TCP admission race under the
single-address policy. Incoming sockets can arrive before both outgoing hellos;
rejecting the outgoing sockets at that point can close both directions. The
per-address check now runs after handshake identity and duplicate-direction
selection. Distinct peers at the same address are still rejected and the shared
connection budget bounds unidentified sockets. A deterministic reproduction fails
with the old check and transfers successfully with the new one. The full package
suite, focused Release/Thread Sanitizer cases and five fail-fast engine suite
repetitions pass after the fix; no automatic test retry is used.

### Session local discovery

The Swift adapter now accepts enabled LSD. The native session owns interface
membership, announcements, bounded discovered-peer connections and shutdown.
Only running public metadata is advertised; private and paused rows remain
absent. Withdrawing a target cancels and drains its connection attempts. Service
generations reject buffered hints from an earlier registration. Interface services
share a self-filter cookie and retain the inherited 32-hop multicast limit.
Failure to start discovery reports an error while leaving TCP/µTP operational.

Darwin multicast port sharing requires both `SO_REUSEADDR` and `SO_REUSEPORT`.
The first real libtorrent comparison exposed the missing latter option; raw BSD
socket tests cover both address families. The reference fixture also requests its
initial LSD announce after file checking, avoiding a skipped initial announcement
followed by the normal five-minute timer. Neither change adds a peer shortcut.

Twelve independent transfers use real IPv4 loopback multicast as their only peer
source, across v1/v2/hybrid metadata, TCP/µTP and both payload directions. Exact
flushed files match. Select them with `BUTTER_REFERENCE_FILTER=lsd`, optionally
`BUTTER_LSD_FILTER`. The reference harness now contains 426 transfers plus two DHT
protocol comparisons. Package tests, focused Release/Thread Sanitizer checks and
the shared app contract pass. Physical-interface and router acceptance remain
separate checks, and phase 11 is still in progress.

### Responsive storage commands and snapshots

Commands now hold a cancellable lease for their transfer. Settings, blocklist
changes and shutdown retain exclusive barriers. Waiting barriers cannot be
overtaken by later commands. Repository writes, listener setup and routing
updates have separate serial ownership so unrelated operations can overlap
without creating duplicate imports or competing listeners.

Snapshots reuse the last storage state for a busy row, with the existing Moving,
Renaming and Checking labels, and refresh idle rows independently. They drain
events once after sampling. The durable-move fixture holds one or four actual
filesystem operations while another transfer snapshots, pauses and exports.
Shutdown waits for the moves to finish, and exact bytes and one event per move
are verified afterwards.

The fixture exposed a second blocking point in the global serial disk queue.
The disk pool now runs four workers with strict FIFO order per storage owner,
retaining the eight-per-owner and 64-total admission limits. At most three
workers run bulk jobs, reserving capacity for shorter disk work. Tests verify
that an ordinary job cannot bypass a blocked bulk job for its own owner.
Package tests, focused Release/Thread Sanitizer checks, the complete storage
target under Thread Sanitizer, the shared app contract and 36 independent
libtorrent session transfers pass. No production transfer backend is changed.
The disposable-volume recovery harness also passes its journal/checkpoint child
interruptions, real ENOSPC and read-only remount cases with the new scheduler.

### Hybrid magnet metadata on a legacy wire

Metadata exchange now tries the v1 identity once when the preferred v2 opening
closes or times out before its handshake, within the same request deadline and
encryption policy. Wrong identities and failures after the handshake do not
trigger another opening. Both full hashes still authenticate the received
`info` bytes. The resulting envelope retains tracker and web-seed hints from
the magnet without changing its identity.

Four native TCP/µTP cases cover plaintext and required RC4, with a separate
wrong-identity case. Two public libtorrent fixtures supply metadata over the
v1 wire and then transfer exact multi-file payloads. The four original private
hybrid transfer cases remain. The reference harness now contains 428 transfers
plus two DHT protocol comparisons. Sparse v2 layer reconstruction from legacy
payloads remains in TODO.md.

### Pending magnet rows and DHT publication barrier

The Swift adapter accepts magnet imports and shows paused or resolving rows
without claiming file metadata or progress. Numeric peer hints and enabled DHT
feed a bounded metadata resolver. The shared DHT owner queries unresolved
identities without announcing them; private metadata overrides a stale pending
registration and drains both queries and peer delivery.

Verified metadata is published only after pending discovery and connections have
stopped. Private rows do not reconnect DHT or explicit hints. Disjoint v1/v2
aliases resolve to the older row and destination, with one duplicate event for
each removed alias. Standard metadata and checkpoints restore resolved magnets
without their original source files. An invalid destination retains verified
metadata for an explicit retry and leaves the original file untouched.

The shared command contract checks pending add, duplicate, run, pause and safe
removal against both engines. Six native trackerless cases cover IPv4/IPv6,
v1/v2/hybrid and TCP/µTP. Twelve new libtorrent comparisons resolve magnets
using DHT alone in both directions and verify exact flushed payloads. The harness
now contains 440 transfers plus two DHT protocol comparisons. Package tests and
focused Release/Thread Sanitizer checks pass. Tracker-only pending discovery,
incoming metadata, unresolved persistence and waiting exports remain in TODO.md.

### Pending tracker announces and incoming metadata

Running magnet rows announce to HTTP and UDP trackers using their known wire
identities, the session's bound port and the reference engine's placeholder
remaining byte count. Metadata promotion drains pending announces and sends a
fresh started event for the verified transfer. Private payload connections use
the verified tracker response. Incoming TCP and µTP peers can also supply BEP 9
metadata without tracker or DHT discovery. The verified public transfer can
reconnect to the listening port advertised by the peer.

The focused magnet and tracker suites pass, including both incoming transports
and six native tracker-only cases. Sixteen new libtorrent tracker-only magnet
comparisons cover both directions over TCP and µTP, HTTP and UDP trackers, and
hybrid identity registration. The reference matrix now contains 456 transfers
and two DHT protocol comparisons.

Unresolved magnets retain a versioned, bounded record with the full magnet URI
and destination. Restore validates the requested identity and reapplies the
saved destination and discovery hints. Pending tracker additions and moves are
written before they take effect in memory. A live row holds an exclusive lease,
and resolved transfers restore from the published torrent and checkpoint.

Exports of running sparse v2 and hybrid transfers wait up to 15 seconds for
authenticated piece layers. Durable hash updates wake overlapping requests
without holding the transfer command gate while they wait. Removal, shutdown
and caller cancellation settle waiting requests. Unresolved magnets still return
the reference engine's metadata-resolving error.

Repository publication records a staged checkpoint directory before opening
storage. A retry can retire that directory by its recorded identity until the
locator commits, then restore the published checkpoint. The standard torrent
remains readable across the handoff. Killed-child fixtures cover four durable
publication boundaries, and the disposable volume verifies failed publication
under ENOSPC followed by a successful retry.
