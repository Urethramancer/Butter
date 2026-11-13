# Verification, repair and format badge checks

The final production candidate passes the serial package suite: 77 storage,
100 networking, 24 metadata and 183 engine tests (384 total). A subsequent
parameterised engine test also passes for individual/folder repair while network
writes are already queued; the old transfer drains before staging, the repaired
bytes survive, and running state is restored. No production code changed after
the full package run.

Focused address/thread sanitizer runs pass 76 storage and 18 engine tests each.
Those precede the final missing/replaced-repair-file error guard; its focused
repair tests and full package run pass. Native storage checks pass real ENOSPC
and read-only staging, source/destination preservation, retries after freeing
space, and killed-process recovery at journal, backup, publication, receipt and
checkpoint boundaries, including partially published folders. Recovery does not
need the source copy. The final guard has additional destination-replacement
coverage both before and after publication.

Native interoperability passes 312 direct peer fixtures, six legacy-hybrid
fixtures, twelve local-discovery fixtures, the DHT protocol checks, 36 session
transfers, 32 hybrid tracker cases, 24 session-DHT cases, 24 PEX/PORT cases and ten
web-seed cases. The initial full run stopped at an obsolete tracker expectation:
lazy seeds can start with verified `left > 0`, then announce completion. The
tracker and all remaining suites passed a separate continuation with unchanged
deadlines; this is not represented as one uninterrupted passing run.

Native/reference command contracts, application lifecycle and Light/Dark
interface checks pass. Unsigned Debug/Release builds, native-only linkage,
retained licences and unchanged repeat builds pass. The new v1/v2/Hybrid badge
has classification coverage, tooltip/VoiceOver text and inspected row rendering;
pending magnets remain unlabelled. This is not a full manual accessibility audit.
User Xcode project/scheme edits are retained and excluded from commits.

[Retained failures](raw/local-repair/) show the tracker expectation, missing-file
recovery error and a test that incorrectly waited for shutdown completion before
releasing the disk blocker. The corrected test waits for shutdown admission.
Full passing logs remain under `.build/` (`final-repair-package.log`,
`repair-final-native-storage.log`, `repair-remaining-reference.log`,
`repair-queued-network-writes-drain.log`, `final-repair-build.log` and the focused
sanitizer/contract/lifecycle/interface logs). Performance acceptance is recorded
separately; correctness passes do not establish throughput or CPU parity.
