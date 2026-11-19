# Validation scope

Serial package tests cover metadata, networking, storage and engine behaviour.
Native interoperability exercises both directions, TCP/µTP, encryption, hybrid
identities, discovery, trackers and web seeds. Storage fixtures check byte
preservation through ENOSPC, read-only volumes, replacement, killed processes and
interrupted publication/discard.

The retained write coalescer passes storage/engine tests, focused Address and
Thread Sanitizer checks, 48 bidirectional native TCP fixtures and unsigned
Debug/Release builds with linkage and licence checks. Its source comparison,
500 Mbps comparison and focused cases independently validate bytes and reopen
checkpoints.

Worker fusion passes 425 package tests, 98 focused tests under each sanitizer,
native storage recovery/ENOSPC/read-only checks and 33 controller tests. Its source
comparisons establish a concurrent-v2 gain. The latest full matrix validates
**252/252 trials**: throughput passes 12/18 cases, CPU 5/18 and memory 18/18.
Competing builds and other CPU load were observed; quiet-host release performance
validation remains pending. All nine downloads still miss the CPU target.
See [measurements and methodology](performance/README.md).

Repair checks cover queued network writes, individual files/folders, source
preservation, interrupted recovery and destination replacement. Application
contracts, lifecycle checks, native UI automation and Light/Dark reviews cover
common workflows. They do not replace complete keyboard/VoiceOver acceptance.

Inspector file controls announce full paths while retaining their automation
identifiers. Native checks exercise accessibility activation through mixed, on,
off and disabled checkbox states; the file-selection/removal UI workflow passes.
Peer rows expose spoken download/upload labels and folder controls expose their
expanded state. Piece accessibility summaries count statuses in one pass.

[TODO](../TODO.md) retains unexplained failures: a native-sequence µTP handshake
timeout, an earlier temporary-path disappearance and a combined-contract deadline.
Passing isolated checks do not explain them. Platform permissions, default-handler
registration, physical routers, interface discovery captures and long-duration
cancellation stress also remain open.

Generated logs and captures belong under ignored `.build/`. Correctness results
and partial platform coverage are not release certification.
