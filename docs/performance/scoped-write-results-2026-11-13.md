# Scoped write inspection

The separate [parent comparison](raw/scoped-write-parent-repeat/summary.json)
validates all 28 trials, including warm-ups, for many-file hybrid downloads.
It compares `0551a42` with `5b0f3b2` using six balanced source pairs and the
unchanged pinned native counterpart. Binaries were built before subsequent
32 MiB piece support edits; recorded source fingerprints identify the measured
code. No compilation or test workload ran during timing.

| Current / parent | Median | 95% interval |
| --- | ---: | ---: |
| Swift CPU/GiB | 0.8535 | 0.8103–0.8623 |
| Verified throughput | 1.1879 | 1.1756–1.2421 |
| Peak RSS | 1.0147 | 0.9688–1.0619 |
| Counterpart CPU/GiB | 1.0024 | 0.9550–1.0279 |

CPU falls 14.7% and throughput rises 18.8%. Memory and counterpart CPU remain
inconclusive. Native CPU and throughput control intervals include one.
Current Swift throughput is 35.1% of native and CPU/GiB is 2.50× native;
this focused comparison does not establish performance parity or full-matrix
acceptance.

The [interrupted comparison](raw/scoped-write-interrupted/paused.json) remains
separate: all 24 records, 23 accepted trials and the interrupted trial's logs
are retained unchanged. Its samples were neither replaced nor pooled with the
new run.
