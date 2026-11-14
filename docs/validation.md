# Validation scope

The Swift implementation has serial package coverage for metadata, networking,
storage and engine behaviour. Native interoperability exercises both directions,
TCP/µTP, encryption, hybrid identities, session discovery, trackers and web seeds.
Filesystem fixtures check byte preservation and recovery across ENOSPC, read-only
volumes, replacement, killed processes and interrupted publication/discard.
Correctness checks do not establish CPU or throughput parity.

The latest write-coalescing candidate passed the storage and engine suites,
focused Address/Thread Sanitizer checks, 48 bidirectional native TCP fixtures,
and unsigned Debug/Release app builds with native linkage, retained licences and
an unchanged repeat build. Its 28 comparison samples independently checked payload
bytes and reopened checkpoints. A further 28 fixed-rate samples validate and meet
saturation; focused regression checks remain pending. See
[performance](performance/README.md).

Repair tests cover individual files and folders while network writes are queued:
the old transfer drains before staging and running state is restored afterwards.
Native disk tests cover recovery without the source copy and destination
replacement before and after publication. Application contracts, lifecycle and
Light/Dark interface checks passed at the repair baseline.

Known limits remain in [TODO](../TODO.md): a full native-sequence µTP handshake
failure that does not reproduce in isolation, temporary-path disappearance in an
earlier native run, and a six-second combined-contract deadline without a confirmed
wait point. Passing reruns do not explain those original failures.

Automated UI checks do not replace complete keyboard/VoiceOver review. Notification
permissions, default-handler registration, physical routers, private-discovery
packet capture and long-running cancellation stress still require acceptance work.
Generated passing logs and diagnostic captures belong under ignored `.build/`.
