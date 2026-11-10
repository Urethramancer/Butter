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
Scripts/verify.sh http
Scripts/verify.sh network
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

`ButterTorrentNetworking` provides TCP streams/listeners, shared IPv4/IPv6 UDP,
HTTP/HTTPS and UDP trackers, BEP 17/19 web seeds, local discovery and UPnP/NAT-PMP.
These services are connected to the package's headless integration tests;
production transfers still use libtorrent. `http` and `network` run the networking
tests; the ordinary package test command includes both libraries.

The HTTP transport bounds concurrent requests, redirects, response headers and
decoded body bytes; defaults are eight requests, five redirects, 32 KiB response
headers and 1 MiB bodies. Requests have a 30-second overall and ten-second idle
deadline. With the approved phase 5 design change, Network handles HTTP/TLS through
numeric endpoints; Foundation retains URL and XML parsing. Each hop resolves once,
validates all answers and connects to those addresses. TLS verifies the original
hostname using platform trust. Mixed public/local answers, public-to-local
redirects, unsafe loopback tracker paths, URL credentials and HTTPS downgrades are
rejected. HTTP/1 framing handles fragmented, chunked and close-delimited responses;
system zlib bounds gzip/deflate decoding. No cookies, credential store or cache is
used. `FoundationHTTPTransport` remains a compatibility alias for
`NetworkHTTPTransport`.

`ListeningPort` owns TCP and IPv4/IPv6 UDP on one port, rolls back partial binds
and releases the port on shutdown. Incoming and outgoing TCP peers share a hard
budget; streams permit one read and one write, each bounded to 1 MiB. DNS allows
four outstanding system jobs per resolver and sixteen answers; cancelled libc
lookups retain their worker slot until they finish. UDP queues, subscriptions
and transactions are bounded. The dispatcher matches replies by source and
transaction and routes DHT/µTP packets to future protocol implementations.

UDP trackers implement BEP 15/41, connection expiry and exponential retries.
`TrackerClient` connects HTTP/UDP tiers to the same lifecycle manager. Local
discovery advertises only explicitly registered public metadata, with cookies,
rate limits and IPv4/IPv6 multicast interfaces. UPnP discovery validates the
description origin against the responding address; bounded XML rejects entities.
Mapping clients support lease renewal, reboot detection and removal. UPnP checks
existing mappings before changing or deleting them. Callers drive discovery,
announce and renewal ticks and explicitly shut down owned transports.

Tracker services encode binary identifiers without text conversion, parse compact
IPv4/IPv6 and dictionary peers, retain tracker IDs, honour intervals, shuffle and
promote tier members, and send started/completed/stopped events. The caller ticks
an injectable monotonic clock. Failure delays double from 30 seconds to a maximum
of 30 minutes; cancellation does not count as tracker failure. A torrent that
starts complete does not send a completed event. A session admits one command at
a time and stops every tracker it successfully contacted.

Web seeds admit three simultaneous requests and 128 distinct sources per client.
BEP 19 checks byte ranges, response lengths and Content-Range; whole-file HTTP 200
is accepted only for a complete requested file. Paths use separately escaped
original metadata components. BEP 17 supports whole pieces and contiguous ranges.
503 retry hints use the BEP 17 response body or Retry-After seconds/HTTP dates.
Retries are bounded and use an injectable clock. The caller verifies piece hashes
and reports corruption to ban a seed, including its in-flight responses; fetched
bytes are never automatically treated as verified. Padding and file-to-piece
mapping remain storage/engine responsibilities.

Tests use temporary loopback HTTP/TLS listeners and injected failures. On macOS
15+, the negative TLS test uses `/usr/bin/openssl` to generate a disposable identity
imported only into memory; no keychain or trust settings change. No public service
or third-party dependency installation is needed. Package Release tests verify
the same harness; the native UI suite is reserved for later integration.
