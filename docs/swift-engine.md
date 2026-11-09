# Swift engine replacement

Production still uses libtorrent. Cut-over requires all twelve phases and the
complete acceptance suite; completing a utility does not enable Swift transfers.
Keep layouts, `EngineOperations`, scheduling and completion policies unchanged.

## Reference and comparison boundary (phase 1)

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
