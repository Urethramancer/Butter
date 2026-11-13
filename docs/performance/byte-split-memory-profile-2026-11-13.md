# UTF-8 separator memory diagnostics

The new `--profile-source` mode captures both engines for the retained scanner
and rejected `c643c61`, with one diagnostic trial per source/engine. All four
trials validate independent payload digests and saved-state reopening. All 24
heap/VM reports complete at ready, verified and durable gates. Retained Swift
source hashes match all 94 files in the completed write-refill matrix; the
rejected source differs only in `StorageDirectory.swift`.

| Swift gate | Retained live heap bytes | Rejected live heap bytes | Retained VM physical footprint, KiB | Rejected VM physical footprint, KiB |
| --- | ---: | ---: | ---: | ---: |
| Ready | 1,991,552 | 1,991,616 | 5,377 | 5,393 |
| Verified | 2,217,216 | 2,217,232 | 8,305 | 8,625 |
| Durable | 2,216,400 | 2,217,232 | 8,305 | 8,593 |

Live allocated heap is nearly equal. At durable, rejected-source dirty empty
small-allocation arenas are 1,216 versus 1,008 KiB, malloc metadata is 416
versus 384 KiB, and stack dirty memory is 272 versus 224 KiB (six versus five
resident stack regions). Text resident size is the same at this gate. This is
consistent with allocator/scheduling high-water differences rather than a large
retained payload cache, but does not establish source causation.

Snapshots are intrusive, sequential, and limited to one capture per source.
VM physical footprint is not whole-process peak RSS. Gate snapshots do not
measure transient allocation churn or observe the original RSS peak. Untyped
heap labels do not identify allocation sites without stack logging. These
diagnostics do not overturn the six-pair RSS regression or justify restoring
the rejected scanner. The per-job autorelease experiment remains a null result.

The installed Instruments Allocations recorder did not start on either a tiny
launch probe or a bounded attach probe. The first target remained suspended
in dyld before main; its own recorder/target required forced cleanup. The attach
probe hit its ten-second readiness deadline and cleaned both children. Failure
logs and the stack sample remain. Bounded `heap` and `vmmap` probes succeed;
temporary binaries are removed.

The harness now supports stdout reports with deadlines, validates snapshot
contents, retains bounded UTF-8-safe stderr on child exit failure, and labels
source profiles as diagnostic-only without acceptance ratios. All 21 harness
tests pass (138 assertions). The initial sandboxed test failure is retained:
`time -l` could not read `kern.clockrate`; the suite passes with the process
accounting access used for benchmarks. Successful integration was captured at
`1a34405`; the subsequent stderr encoding fix is separately covered by unit tests.

[Observations, source checks, tool outcomes and raw hashes](byte-split-memory-profile-2026-11-13.json)
retain evidence. Raw source snapshots remain in
`.build/benchmarks/byte-split-memory-profile`. Production still matches the
write-refill full matrix; CPU parity remains unmet.
