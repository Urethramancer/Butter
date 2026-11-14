# Aggregate bounded storage diagnostics; individual payloads and job traces are never retained.
module TransferBenchmarkHarness
	WRITE_PROFILE_PHASES = %w[setup targetInspection progressInvalidation packing descriptorAcquisition prewriteChecks fullScan payloadSyscall postwriteStamping cleanup].freeze
	def self.write_distribution(values, name)
		count = values.fetch(name + 'Count', 0)
		return nil if count == 0
		buckets = values.map { |key, value| [key.delete_prefix(name + 'Power2_').to_i, value] if key.start_with?(name + 'Power2_') }.compact.sort
		quantile = lambda do |fraction|
			cumulative = 0
			bucket = buckets.find { |_, amount| cumulative += amount; cumulative >= (count * fraction).ceil }
			2**bucket.first
		end
		{count: count, mean: values.fetch(name + 'Sum', 0).to_f / count, p50_upper: quantile.call(0.50), p90_upper: quantile.call(0.90), p99_upper: quantile.call(0.99)}
	end
	def self.aggregate_write_profile(rows)
		measured = rows.reject { |row| row[:warmup] }
		return {status: 'failed', trials: rows.size} unless rows.size == 9 && rows.all? { |row| row[:accepted] }
		modes = measured.group_by { |row| row.fetch(:write_mode) }.transform_values do |trials|
			values = Hash.new(0)
			trials.each do |trial|
				events = trial.fetch(:events).fetch('download')
				first = events.find { |event| event['phase'] == 'start' }.fetch('storage_diagnostics', {})
				last = events.find { |event| event['phase'] == 'durable' }.fetch('storage_diagnostics', {})
				last.each { |key, value| values[key.delete_prefix('writeProfile.')] += value - first.fetch(key, 0) if key.start_with?('writeProfile.') }
			end
			jobs = values.fetch('jobs', 0)
			timed = values.key?('job.cpuNs')
			phases = WRITE_PROFILE_PHASES.to_h do |name|
				calls = values.fetch("phase.#{name}.calls", 0)
				cpu, elapsed = %w[cpuNs elapsedNs].map { |unit| values.fetch("phase.#{name}.#{unit}", 0) / 1e9 }
				[name, {scope_entries: calls, cpu_seconds: timed ? cpu : nil, elapsed_seconds_sum: timed ? elapsed : nil, cpu_seconds_per_entry: timed && calls > 0 ? cpu / calls : nil, cpu_seconds_per_job: timed && jobs > 0 ? cpu / jobs : nil, elapsed_seconds_per_entry: timed && calls > 0 ? elapsed / calls : nil, elapsed_seconds_per_job: timed && jobs > 0 ? elapsed / jobs : nil}]
			end
			process_cpu = trials.sum { |trial| trial.fetch(:engine_metrics).fetch(:cpu_seconds) }
			{trials: trials.size, timings_recorded: timed, totals: values, phases: phases,
				write_job_cpu_share: timed && process_cpu > 0 ? values.fetch('job.cpuNs', 0) / 1e9 / process_cpu : nil,
				process_user_seconds: trials.sum { |trial| trial[:engine_metrics][:user_cpu_seconds] }, process_system_seconds: trials.sum { |trial| trial[:engine_metrics][:system_cpu_seconds] },
				counterpart_cpu_seconds: trials.sum { |trial| trial[:counterpart_metrics][:cpu_seconds] },
				scan_files_per_job: jobs > 0 ? values.select { |key, _| key.start_with?('scan.') && key.end_with?('.filesVisited') }.values.sum.to_f / jobs : nil,
				distributions: %w[blocksPerJob bytesPerJob contiguousBytes syscallBytes jobDurationNs].to_h { |name| [name, write_distribution(values, name)] },
				median_cpu_seconds: median(trials.map { |trial| trial[:engine_metrics][:cpu_seconds] }), median_transfer_seconds: median(trials.map { |trial| trial[:engine_metrics][:through_durable][:wall] })}
		end
		off = modes.fetch('off')
		{status: 'diagnostic-only', trials: rows.size, modes: modes,
			overhead: %w[counts timed].to_h { |mode| [mode, {cpu_ratio_to_off: modes[mode][:median_cpu_seconds] / off[:median_cpu_seconds], duration_ratio_to_off: modes[mode][:median_transfer_seconds] / off[:median_transfer_seconds]}] },
			clock_calibration: rows.find { |row| row[:write_mode] == 'timed' }.fetch(:events).fetch('download').find { |event| event['phase'] == 'ready' }.fetch('storage_diagnostics').select { |key, _| key.start_with?('clock.') },
			limitations: 'Two measurements per mode; diagnostic ratios are not performance acceptance. Phase elapsed totals sum concurrent jobs, not transfer duration. Thread CPU combines user and kernel time. Scope entries include resumed phases. Power-of-two percentiles are upper bounds. Remainder includes unassigned work and transition accounting; final aggregation/merge and existing diagnostic counters also cost process CPU. Timer calibration is not subtracted.'}
	end
end
