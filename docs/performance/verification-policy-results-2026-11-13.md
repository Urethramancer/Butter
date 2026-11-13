# Verification policy and isolated storage experiments

The application now clears a durable clean-shutdown marker before restoring
transfers, trusts checkpointed completion only after clean shutdown and matching
metadata/hashes/paths/stamps, and validates unfinished torrents on every launch.
An unclean launch validates all restored torrents containing payload. The launch
worker is serial, includes paused transfers and retains their intended state.
Run/pause intent stays responsive during checks, allowing other completed
torrents to seed. Magnets with existing payload enter this queue when metadata
arrives and retain their metadata peer for subsequent transfer.
Restored claims whose authenticated hashes are missing are pruned, including
unselected pieces; a still-authenticated selected subset can remain trusted.
Uploads use explicit trusted verified reads; direct storage consumers remain
strict by default. Normal downloads retain stored-byte authentication. Torrent and file-row **Verify Local Data** always read storage,
including whole shared boundary pieces, without changing selection.

State replacement fsyncs the temporary file, atomically renames it and fsyncs its
directory. Quit drains work, flushes checkpoints and obtains fresh eligibility
without hashing completed payloads. Ineligibility leaves the marker false;
timeouts retain ownership through late marker clearing. Shutdown cancels new
validation admission and drains admitted work, leaving interrupted checks
ineligible; an aborted quit can restart that queue. Successful quit keeps
new transfers stopped until termination. Recovery journals remain actionable and
make the marker ineligible without adding an eligibility-only quit blocker.
Known paused validation failures remain visible without hiding healthy transfers.

## Experiments

1. **Received-byte proofs — rejected.** Eight streaming SHA-1/SHA-256 contexts
   retained hash state and compact leaf digests; explicit verification stayed
   strict. Format, padding, interleaving, cancellation, invalidation, corruption,
   checkpoint-failure and eviction tests passed, as did sanitizers and native
   checks. Diagnostic traffic produced only 134 proof hits out of 3,139 attempts
   (4.3%); discontinuities forced 3,005 stored-byte checks. Bytes hashed rose
   from 823,132,160 to 973,537,280 in the separate diagnostic samples. All 28
   fixed comparison samples validated their partial payloads and reopened
   checkpoints. The previous Swift warm-up reached only 36.95 MB/s and failed
   the unchanged saturation gate. No retention inference or timing repeat for that candidate was
   made. Five of six measured CPU/GiB source ratios exceeded one.
2. **Kernel root-relative resolution — rejected at permission preflight.**
   `O_NOFOLLOW_ANY` works on the test host, but a checked ancestor changed to
   mode 0300 still permits full-path file opening while the existing directory
   walk rejects it. A separate ancestor access check does not preserve the
   existing permission boundary across that race. The original traversal stays
   in place; no unsafe candidate was timed. The probe and result are preserved.
3. **Completed-data watching — rejected.** A macOS FSEvents prototype
   coalesced affected files, forced validation through the serial queue, rebound
   subscriptions after root moves and kept synchronous upload checks. Dropped,
   coalesced and uncertain events required conservative reconciliation, following
   [Apple's FSEvents guidance](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).
   Notification, fallback, root-move, release, paused-validation and sanitizer
   tests passed before testing a ten-second completed-data scan fallback. Both
   comparison drivers modelled one-second application polling; capability
   adapters and selected policies were recorded. The partial-download workload
   created no watcher subscriptions because its torrents remained unfinished.
   All 28 comparison samples passed data validation and saturation checks.
   The CPU/GiB ratio was 1.030 (paired 95% interval 0.972–1.074): lower CPU
   was not established. Throughput and counterpart CPU showed no established
   regression; the RSS interval stayed within the 10% allowance. The complete
   prototype was reverted. No candidate qualified for focused follow-up trials.

## Evidence and limits

Raw samples, environment fingerprints, operation counts, validation logs and
rejected candidate sources/patches are retained in
[raw results](raw/verification-policy/), with complete validation logs and local
profiling artifacts in `.build/experiments/verification-policy/`. Comparisons use identical native
controls and the fixed six balanced source pairs: four warm-ups and 24 measured
samples at 500 Mbps. No automatic repetitions or combined candidates were used.
Independent partial validation and checkpoint reopening always used strict
storage reads. No new five-rate sweep or full acceptance matrix was run.

Serial package checks passed: 79 storage tests and 189 engine tests, with final
focused checks covering launch/magnet/cache changes. The native app contract,
60 fresh bidirectional libtorrent interoperability cases, eight state-writer
process interruptions, actual ENOSPC and read-only persistence tests passed.
Address Sanitizer covered durable state buffers and experimental storage paths;
Thread Sanitizer covered launch cancellation, queued intent and callbacks.
Final unsigned Debug/Release builds, native linkage and unchanged repeat builds
passed. The user's existing Xcode project and scheme edits were left untouched.

The separate [Time Profiler diagnostic](raw/verification-policy/retained-profile/cpu.json)
at `26fedd1` captured 5,179 Running samples: metadata/open/close accounted for
39.2% of disjoint executing-leaf weight, hashing 15.2% and payload I/O 9.7%.
These are sampled weights, not measured kernel residency or additive inclusive
CPU durations. Subsequent guards affect restoration and known paused-error snapshots; neither
path executes in that transfer capture. The binary trace remains local; exported counts and
source/environment fingerprints are retained. No 500 Mbps CPU improvement or
parity claim is justified.
