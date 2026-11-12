# Explicit ephemeral TCP binding

Outgoing Network.framework connections now request a wildcard local address for
the destination's IP family and port zero. Address/port selection remains automatic;
listener exclusivity, peer budgets, cancellation and deadlines are unchanged.
There are no added connection or benchmark retries. The parameter's role is
specified in [Apple's documentation](https://developer.apple.com/documentation/network/nw_parameters_set_local_endpoint(_:_:)).

The vector-writer interoperability wrapper initially stops in its preliminary
engine suite with 11 bind/timeout issues. The TCP table has 21 listeners,
16 TIME_WAIT entries and 36 established connections; no test child remains.
All eleven failing cases pass in isolation. A standalone probe linked only to
Networking/Metadata reproduces the outgoing bind failure without storage calls:

| Probe configuration | Result |
| --- | --- |
| Default implicit bind | EADDRINUSE after 347 completed connections |
| Outgoing endpoint reuse | EADDRINUSE after 649; rejected and removed |
| Default bind, second control | EADDRINUSE after 119 |
| Explicit wildcard/zero bind | 1,000 IPv4 connections pass |
| Explicit wildcard/zero bind, final code | 2,000 IPv4 and 2,000 IPv6 connections pass |

Each iteration creates a fresh listener/connection, exchanges one byte and drains
the listener. It stops at the first failure. Explicit binding avoids the reproduced
failure on this host; this does not establish the OS-internal cause. Earlier failures
remain recorded, rather than replaced by the successful runs.

All 351 package tests pass, including a new bounded 256-cycle test per IP family
that checks shared-budget release. Existing occupied-port exclusivity also passes.
Thirty focused tests under each of Address and Thread Sanitizer pass, covering
TCP/TLS, deadlines, peer admission and transfers. The raw probe outputs, failed
engine-suite log and source/binary diagnostics remain locally under
`.build/diagnostics/piece-buffer/tcp-*`, `vector-native-peer-first-failure.log`
and `explicit-bind-*`. The native rerun passes all 466 checks, including encrypted TCP, µTP, session discovery and web seeds.

The earlier [vector-write comparisons](vector-write-results-2026-11-12.md) predate
this connection fix. No CPU/throughput improvement is claimed for explicit binding;
CPU parity and final-candidate matrix acceptance remain open.
