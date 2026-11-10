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
harness. Debug and Release package suites cover 45 networking and 20 metadata/
creation tests. Real loopback fixtures cover both IP families, HTTP/TLS rejection,
UDP trackers, HTTP-to-UDP failover with started/completed/stopped events on the
owned port, and UPnP SOAP. Injected packets/clocks cover loss, retries, connection
expiry, source filtering, discovery restrictions, router errors and reboot/lease
recovery. Framing tests cover malformed and compressed responses. Concurrency
cases run five independent times without retries, including cancellation, shared
peer limits, concurrent shutdown, partial-bind rollback and immediate port reuse.

Production transfers remain on libtorrent. No LAN multicast, real router,
successful public-CA HTTPS, UI or throughput/CPU/memory acceptance pass is claimed.
Storage, transfer protocols and final engine integration remain phases 6–12.

Protocol references: [BEP 15](https://www.bittorrent.org/beps/bep_0015.html),
[BEP 41](https://www.bittorrent.org/beps/bep_0041.html),
[BEP 14](https://www.bittorrent.org/beps/bep_0014.html),
[RFC 6886](https://www.rfc-editor.org/rfc/rfc6886) and
[UPnP WANIPConnection v2](https://upnp.org/specs/gw/UPnP-gw-WANIPConnection-v2-Service.pdf).
