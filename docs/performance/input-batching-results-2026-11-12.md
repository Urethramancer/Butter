# Available TCP input batching — 12 November 2026

A fresh many-file v2 download comparison reduces CPU from 12.845 to 12.304
seconds/GiB through durable completion: independent ratio 0.958 [0.932–0.996]
at 95%, with 10,000 median bootstrap resamples. Verified throughput rises from
91.4 to 95.3 MB/s: 1.042 [1.005–1.080]. Both runs accepted all fourteen trials,
with one warm-up per engine and six balanced measured pairs. Cross-commit
samples are not paired with each other.

Unrestricted TCP reads now request up to 256 KiB of already available bytes,
feeding the decoder in slices of at most 64 KiB. Payload batches can span these
slices, but still stop at sixteen blocks/256 KiB. Controls flush preceding
payload before processing; short batches flush before the next network wait.
No code waits to fill a production batch. Rate-limited TCP and µTP retain the
64 KiB read size. Request windows, queue caps, disk admission and caches remain
unchanged, as do stored-byte verification and filesystem ownership checks.

The preceding decoder regression fix includes the four-byte frame prefix in
the buffer calculation while retaining message/feed limits. A deterministic
integration fixture forces a read spanning multiple decoder feeds and verifies
control ordering and bytes for plaintext/RC4 and limited/unlimited traffic.
All 331 package tests passed serially. All 37 focused reader, framing,
cancellation, completion, encryption and µTP tests passed under each sanitizer.

## Memory and seeding checks

The original fresh-baseline memory gate passes. Relative to the immediate
before-run, median peak RSS rises about 4.5%, with interval 1.002–1.104 and an
observed maximum ratio of 1.042. That stricter incremental comparison remains
inconclusive at 10%; it is not labelled as a pass or substituted for the
unchanged original-baseline gate. The additional read buffer remains bounded.

A separate many-file v2 seeding check accepts all fourteen trials and passes
memory. CPU is 7.642 versus 7.920 s/GiB: 0.965 [0.937–1.056], inconclusive.
Throughput rises from 206.6 to 251.5 MB/s: 1.218 [1.019–1.274]. Its comparison
retains all twelve preceding measured samples and all six new samples.

Download CPU remains 6.714 [6.665–6.796] times native, so the goal is unmet.
The latest [full matrix](tcp-batching-results-2026-11-12.md) remains the earlier
candidate. Focused timing does not establish other workloads. All nine contract, lifecycle,
storage/interruption, native reference and application/linkage suites subsequently
passed for committed source `38499ec`: [integration records](raw/available-input-integration/results.jsonl).

## Raw evidence

- [Fresh before-run](raw/available-input-before/summary.json), [candidate download](raw/available-input-after/summary.json), [candidate seeding](raw/available-input-seeding/summary.json).
- [Download CPU/throughput intervals](raw/available-input-after/before-after.json), [incremental memory uncertainty](raw/available-input-after/memory-versus-immediate-before.json), [seeding intervals](raw/available-input-seeding/before-after.json).
- [Every before trial](raw/available-input-before/trials.jsonl), [every download trial](raw/available-input-after/trials.jsonl), [every seeding trial](raw/available-input-seeding/trials.jsonl), [source/environment hashes](raw/available-input-after/environment.json) and [verification evidence](raw/available-input-after/checks.json).

No failed trial was retried or removed, and no tag was created.
