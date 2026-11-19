# Repository rules

- Do not create or retain audit logs, audit reports or audit diaries.
- Never log or commit credentials or process environment dumps.
- Never commit raw profiler captures or exports. Keep temporary profiling data
  under ignored `.build/` and delete it after extracting compact measurements.
- Raw profiler retention must remain disabled, including when requested through
  an environment variable. Preserve only concise test and benchmark results.
