# Scoped piece verification

The [six-pair source comparison](raw/scoped-verification-source/summary.json)
validates all 28 trials for many-file hybrid downloads. It measures `eb5f77c`
against `ceb9d29`, independently of deferred opening and background verification.
The pinned reference and production limits remain unchanged. No builds or tests
ran during timing.

| Current / parent | Median | 95% interval |
| --- | ---: | ---: |
| Swift CPU/GiB | 0.7824 | 0.7570–0.8165 |
| Verified throughput | 1.3098 | 1.2527–1.3504 |
| Peak RSS | 1.0050 | 0.9535–1.0539 |
| Counterpart CPU/GiB | 0.9411 | 0.8413–1.0155 |

CPU falls 21.8% and throughput rises 31.0%. Memory and counterpart CPU remain
inconclusive. This focused result does not establish full-matrix acceptance.

The separate [before-change diagnostic](raw/verification-before-diagnostics/trials.jsonl)
validates both engines. Swift's transfer-through-durable phase inspects 1,147,763
leaves in 16,899 scans and executes 12,618 disk jobs. It reads and hashes exactly
1 GiB of payload, feeding that same amount to each of SHA-1 and SHA-256; the
hybrid path already shares its read buffers. These instrumented counts are not
timing acceptance evidence.

All 65 storage tests pass after updating the scoped-check contract. The initial
test run's six failures were the previous unrelated-file expectation; the
updated test also replaces a dependent file during checkpoint publication and
requires rejection. Original failure output remains in the workspace build logs.
