module TransferBenchmarkHarness
	def self.pipeline_distribution(values, name)
		count = values.fetch(name + '.count', 0)
		return nil if count == 0
		buckets = values.map { |key, amount| [key.delete_prefix(name + '.power2.').to_i, amount] if key.start_with?(name + '.power2.') }.compact.sort
		percentile = lambda do |fraction|
			sum = 0; bucket = buckets.find { |_, amount| sum += amount; sum >= (count * fraction).ceil }
			2**bucket.first
		end
		{count: count, mean: values.fetch(name + '.sum', 0).to_f / count, p50_upper: percentile.call(0.5), p90_upper: percentile.call(0.9), p99_upper: percentile.call(0.99)}
	end
	def self.receive_pipeline_report(rows)
		return {status: 'failed', trials: rows.size} unless rows.size == 18 && rows.all? { |row| row[:accepted] }
		groups = rows.reject { |row| row[:warmup] }.group_by { |row| [row.fetch(:source_variant), row.fetch(:pipeline_mode)] }
		modes = groups.to_h do |(source, mode), trials|
			pipeline, storage, tail = Hash.new(0), Hash.new(0), Hash.new(0)
			trials.each do |trial|
				events = trial.fetch(:events).fetch('download')
				first, durable, last = %w[start durable stopped].map { |phase| events.find { |event| event['phase'] == phase } }
				[['receive_pipeline_diagnostics', pipeline], ['storage_diagnostics', storage]].each do |key, totals|
					last.fetch(key, {}).each { |name, value| totals[name] += value - first.fetch(key, {}).fetch(name, 0) }
				end
				%w[reader.samples reader.payloadBytes dispatch.samples dispatch.payloadBytes.sum].each do |name|
					tail[name] += last.fetch('receive_pipeline_diagnostics', {}).fetch(name, 0) - durable.fetch('receive_pipeline_diagnostics', {}).fetch(name, 0)
				end
			end
			reader = %w[readAdmission streamRead dispatch controlDispatch schedulerYield].to_h { |stage| [stage, pipeline.fetch("reader.stage.#{stage}.elapsedNs", 0) / 1e9] }
			dispatch = %w[actorEntry rateAdmission diskAdmission storageWrite verification diskRelease].to_h { |stage| [stage, pipeline.fetch("dispatch.stage.#{stage}.elapsedNs", 0) / 1e9] }
			timed = mode == 'timed'
			if mode != 'off'
				write_calls = pipeline.fetch('dispatch.stage.storageWrite.calls', 0)
				raise 'Missing receive pipeline instrumentation' unless pipeline.fetch('dispatch.blocks.count', 0) > 0 && write_calls > 0
				raise 'Write dispatch/queue/job counts do not reconcile' unless write_calls == storage.fetch('writeQueue.jobs', 0) && write_calls == storage.fetch('writeProfile.jobs', 0)
			end
			overlap = pipeline.select { |key, _| key.end_with?('.overlapErrors') }.values.sum
			raise 'Receive pipeline stage intervals overlap' if overlap > 0
			combined_verification = storage.fetch('storageSync.verificationInWrite.elapsedNs', 0)
			remainder = timed ? pipeline.fetch('dispatch.stage.storageWrite.elapsedNs', 0) - storage.fetch('writeQueue.elapsedNs', 0) - storage.fetch('writeProfile.job.elapsedNs', 0) - combined_verification : nil
			raise 'Storage await budget does not reconcile' if remainder && remainder < 0
			["#{source}/#{mode}", {trials: trials.size, timings_recorded: timed, pipeline_totals: pipeline, storage_totals: storage, after_durable: tail,
				reader_seconds: timed ? reader.merge('other'=>pipeline.fetch('reader.other.elapsedNs', 0) / 1e9) : nil,
				dispatch_seconds: timed ? dispatch.merge('other'=>pipeline.fetch('dispatch.other.elapsedNs', 0) / 1e9) : nil,
				storage_await_breakdown_seconds: timed ? {worker_admission_and_queue: storage.fetch('writeQueue.elapsedNs', 0) / 1e9, synchronous_write_jobs: storage.fetch('writeProfile.job.elapsedNs', 0) / 1e9, synchronous_verification_in_write: combined_verification / 1e9, actor_and_completion_remainder: remainder / 1e9} : nil,
				distributions: %w[reader.readBytes reader.blocksPerRead reader.durationNs reader.stage.readAdmission.durationNs reader.stage.streamRead.durationNs reader.stage.controlDispatch.durationNs reader.stage.schedulerYield.durationNs dispatch.blocks dispatch.payloadBytes dispatch.durationNs dispatch.stage.actorEntry.durationNs dispatch.stage.rateAdmission.durationNs dispatch.stage.diskRelease.durationNs dispatch.stage.diskAdmission.durationNs dispatch.stage.storageWrite.durationNs dispatch.stage.verification.durationNs].to_h { |name| [name, pipeline_distribution(pipeline, name)] },
				median_process_cpu: median(trials.map { |trial| trial[:engine_metrics][:cpu_seconds] }), median_transfer_seconds: median(trials.map { |trial| trial[:engine_metrics][:transfer][:wall] }),
				process_user_seconds: trials.sum { |trial| trial[:engine_metrics][:user_cpu_seconds] }, process_system_seconds: trials.sum { |trial| trial[:engine_metrics][:system_cpu_seconds] }, counterpart_cpu_seconds: trials.sum { |trial| trial[:counterpart_metrics][:cpu_seconds] }}]
		end
		overhead = %w[previous current].to_h do |source|
			off = modes.fetch("#{source}/off")
			[source, %w[counts timed].to_h { |mode| item = modes.fetch("#{source}/#{mode}"); [mode, {cpu_ratio_to_off: item[:median_process_cpu] / off[:median_process_cpu], duration_ratio_to_off: item[:median_transfer_seconds] / off[:median_transfer_seconds]}] }]
		end
		{status: 'diagnostic-only', trials: rows.size, modes: modes, overhead: overhead,
			clock_calibration: rows.select { |row| row[:pipeline_mode] == 'timed' }.map { |row| {source: row[:source_variant], warmup: row[:warmup], clocks: (row[:events]['download'].find { |event| event['phase'] == 'ready' } || {}).fetch('storage_diagnostics', {}).select { |key, _| key.start_with?('clock.') }} },
			limitations: 'Two measured trials per source/mode; no timing acceptance. Process CPU and overhead use through-durable metrics. Aggregate snapshots run from start through stopped; after_durable exposes tail samples. Reader and dispatch budgets are nested and must not be added together. All stage times are elapsed, summed over peers, not CPU or transfer duration. Stream reads return decrypted PeerStream bytes, not necessarily individual TCP callbacks. Failed/empty reads are excluded from positive-read budgets. actorEntry includes diagnostic prelude and actor entry; storage awaits include fused verification, reported separately; storage remainder includes actor admission, completion and recording overhead. Histograms give power-of-two upper bounds. Final histogram/merge work lies outside sample timers and is included in measured process overhead. No estimated timer costs are subtracted.'}
	end
end
