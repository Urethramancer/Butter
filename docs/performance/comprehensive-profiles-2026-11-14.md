# Comprehensive CPU profiles

The retained implementation still has no established CPU improvement from the first two approved experiments. These profiles identify the next targets; they do not establish a performance gain.

## Coverage and method

Captured all 18 combinations of single-file, many-file and concurrent transfers; v1, v2 and hybrid metadata; download and seeding. Each has one Swift and one libtorrent CPU capture, plus a separate counter-only run: 36 CPU captures and 36 counter runs, all with independently checked payload and checkpoint reopening. Each transfer moves 1 GiB.

[Sanitised summaries](comprehensive-profiles-2026-11-14.json) retain executing-leaf categories, caller purposes and start-to-durable counter deltas. Categories partition the exported samples; they are neither kernel residence measurements nor measured CPU savings. Whole-process counters would incorrectly include source verification before seeding starts. Raw Instruments traces remain private local artefacts because Instruments can retain environment metadata. Exported environment metadata is redacted, and subsequent instrumented children receive an explicit environment allowlist.

The original all-case CPU wrapper failed after all 36 validated captures completed because its script changed during execution. The separate counter matrix exited successfully. Neither run is timing acceptance.

## Download targets

| Workload | v1 write jobs | v2 write jobs | Hybrid write jobs |
| --- | ---: | ---: | ---: |
| Single file | 53.3% | 58.8% | 49.1% |
| Many files | 60.9% | 59.9% | 57.2% |
| Concurrent | 68.2% | 67.8% | 68.4% |

Every download issued 65,536 logical payload writes: 16 KiB apiece. The many-file hybrid case used 8,284 batches and 12,391 disk jobs, with 95,273 directory opens, 112,009 descriptor duplications and 143,762 descriptor inspections. Its sampled leaves included `pwrite` (31.3%), `openat` (18.2%) and `close` (5.3%). Stored-byte authentication accounted for 17.1% by caller purpose, versus 57.2% for write jobs and 17.0% for peer transport.

This supports larger contiguous disk writes and reducing repeated guard setup within a safely bounded job. Increasing disk write size does not require increasing peer wire block size. Count actual syscall sizes when testing coalescing: larger logical batches alone do not prove fewer writes. Fresh filesystem guards, durable invalidation and strict verification remain required.

## Seeding targets

The single-file v1 capture attributed 33.5% of samples to peer transport, 22.7% to upload reads and 18.5% to upload admission/cache work. Existing cache entries share an in-flight piece read across peers and retain immutable bytes, with eight resident pieces per torrent and a 64 MiB session byte budget.

All nine counter-only seeding cases read exactly 1 GiB for 1 GiB uploaded, with zero hashing during the measured interval. They used 4,096 file opens and 4,097 disk jobs (4,100 for concurrent transfers). Cache hits ranged from 2,149 to 4,017. These sequential native-peer workloads do not demonstrate extra read amplification that a different popularity policy could remove. Multi-reader and changing-popularity probes are therefore needed before changing eviction behaviour.

An eight-reader cache probe confirmed 512 MiB delivered from 64 MiB of storage reads: 2,048 fresh loads and 14,336 joined loads. Every returned byte was checked. A bounded frequency/ageing candidate increased loads from 644 to 1,073 in the popular-piece case and from 672 to 774 with changing popularity. It was reverted without proceeding to timing acceptance. [Probe records](raw/upload-cache/probes.json) and the [rejected patch](raw/upload-cache/aging-candidate.patch) preserve the result. These are cache/read probes using warm storage and production's trusted-verified policy, not complete peer-transfer comparisons.

## Additional instruments

File Activity captures for many-file hybrid download and single-file v1 seeding both completed for Swift and libtorrent, with independent validation. Allocation captures failed to attach. System Trace attempts were interrupted or ran out of temporary disk space; Swift Concurrency attempts also failed. Those captures provide no accepted evidence and must not be presented as complete coverage. Do not repeat large System Trace acquisitions without sufficient temporary space.

The application fixtures exercise the production session/mapper separately from synthetic native rendering. They use disposable state, not the user's session. UI rendering captures include opening the window and twelve one-second updates; they are diagnostic, not steady-state timing acceptance. The visible inspector starts on Files through a test-only copy of the production view, preserving production source and layout.

All eight corrected native rendering captures completed. [Summaries](application-ui-profiles-2026-11-14.json) show 0.54–1.22 CPU seconds with the inspector hidden, 13.52–13.75 with 2,000 files visible, and 5.30–6.21 with 200 torrent rows and a 512-file inspector. Window creation is included, so these figures do not isolate polling cost. Screenshot inspection confirmed a populated Files view. Earlier empty-view and accessibility-selection attempts are excluded.

## Tool verification

The controller tests cover full-matrix scheduling, child cleanup, profiler failure and environment isolation. Attribution tests check sample-weight conservation and native hashing/syscall classification. Application smoke tests independently validated hidden many-file downloads and visible concurrent seeding. Cache diagnostics distinguish retained hits, joined loads, fresh loads and evictions; normal timing runs leave diagnostics disabled.
