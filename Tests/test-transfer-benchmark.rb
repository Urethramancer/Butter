require 'minitest/autorun'
require 'open3'
require_relative 'TransferBenchmarkHarness'
require_relative 'PeerWindowProbe'

class TransferBenchmarkHarnessTests < Minitest::Test
	H = TransferBenchmarkHarness
	def test_window_probe_counts_distinct_outstanding_requests_in_fragmented_streams
		probe = PeerWindowProbe.new
		H.stub(:now, 0.0) { probe.connected }
		hello = "\x13BitTorrent protocol".ljust(68, "\0")
		frame = ->(id, bytes) { [1 + bytes.bytesize, id].pack('NC') + bytes }
		key = ->(piece) { [piece, 0, 1].pack('N3') }
		H.stub(:now, 3.0) do
			probe.observe(0, hello[0,7]); probe.observe(0, hello[7..-1])
			probe.observe(1, hello)
			request = frame.call(6, key.call(1))
			probe.observe(0, request + request + frame.call(6, key.call(2)))
			reply = frame.call(7, [1, 0].pack('N2') + 'x')
			probe.observe(1, reply[0,4]); probe.observe(1, reply[4..-1])
			probe.observe(0, frame.call(8, key.call(2)))
			probe.observe(0, frame.call(6, key.call(3)))
			probe.observe(1, frame.call(16, key.call(3)))
			probe.observe(0, frame.call(6, key.call(4)) + frame.call(6, key.call(5)))
		end
		assert_equal 2, probe.peak
		assert_equal [{peak: 2, payload_bytes: 1}, {peak: 0, payload_bytes: 0}], probe.periods
	end
	def test_fixed_matrix_never_extends_uncertain_cases
		previous_signal = Signal.trap('TERM', 'DEFAULT')
		[6, 12].each do |count|
			Dir.mktmpdir('butter-fixed-matrix') do |out|
				runner = H::Runner.new('/swift', '/reference', out, '/unused', baseline: nil, fixed_pairs: count)
				runner.define_singleton_method(:trial) do |fixture, format, direction, engine, pair, warmup|
					@trials << {case: fixture['case'], format: format, direction: direction, engine: engine, pair: pair, warmup: warmup, accepted: true}
				end
				H.stub(:summary, {status: 'inconclusive', requires_more_pairs: true}) do
					runner.run([{'case' => 'many'}])
				end
				rows = runner.instance_variable_get(:@trials)
				assert_equal 6 * (2 + count * 2), rows.size
				rows.group_by { |row| row.values_at(:format, :direction) }.each_value do |trials|
					assert_equal 2, trials.count { |row| row[:warmup] }
					measured = trials.reject { |row| row[:warmup] }.group_by { |row| row[:pair] }.values
					assert_equal count, measured.size
					assert_equal count / 2, measured.count { |pair| pair.first[:engine] == 'Swift' }
				end
			end
		end
	ensure
		Signal.trap('TERM', previous_signal) if previous_signal
	end
	def test_fixed_matrix_rejects_other_modes_and_invalid_counts
		[{fixed_pairs: 7}, {fixed_pairs: 6, smoke: true}, {fixed_pairs: 6, profile: true}, {fixed_pairs: 6, previous: '/previous'}].each do |options|
			assert_raises(ArgumentError) { H::Runner.new('/swift', '/reference', '/unused', '/unused', baseline: nil, **options) }
		end
	end
	def test_selected_fixture_subset_requires_exact_full_baseline_matches
		Dir.mktmpdir('butter-baseline-fixtures') do |root|
			baseline, work = File.join(root, 'baseline'), File.join(root, 'work')
			FileUtils.mkdir_p(baseline); FileUtils.mkdir_p(File.join(work, 'fixtures'))
			fixtures = %w[single many concurrent].map { |name| {'case'=>name, 'bytes'=>32, 'files'=>[{'sha256'=>"payload-#{name}"}], 'torrent_sha256'=>{'hybrid'=>"metadata-#{name}"}} }
			rows = fixtures.map { |f| {case: f['case'], accepted: true, engine: 'Swift'} }
			original = rows.map { |r| JSON.generate(r) + "\n" }.join
			File.write(File.join(baseline, 'environment.json'), JSON.generate(mode: '--full'))
			File.write(File.join(baseline, 'fixtures.json'), JSON.generate(fixtures))
			File.write(File.join(baseline, 'trials.jsonl'), original)
			many = fixtures[1]
			changed_payload = JSON.parse(JSON.generate(many)); changed_payload['files'][0]['sha256'] = 'changed'
			changed_metadata = many.merge('torrent_sha256'=>{'hybrid'=>'changed'})
			[
				['full manifest', fixtures, true], ['selected workload', [many], true],
				['reordered workloads', fixtures.reverse, true], ['payload mismatch', [changed_payload], false],
				['metadata mismatch', [changed_metadata], false], ['size mismatch', [many.merge('bytes'=>64)], false],
				['unknown workload', [many.merge('case'=>'other')], false], ['duplicate workload', [many, many], false],
				['empty manifest', [], false]
			].each do |label, selected, valid|
				File.write(File.join(work, 'fixtures/manifest.json'), JSON.generate(selected))
				if valid
					runner = H::Runner.new('/swift', '/reference', root, work, baseline: baseline)
					assert_equal rows, runner.instance_variable_get(:@baseline), label
				else
					error = assert_raises(RuntimeError, label) { H::Runner.new('/swift', '/reference', root, work, baseline: baseline) }
					assert_match(/Baseline fixture hashes differ/, error.message, label)
				end
			end
			assert_equal original, File.read(File.join(baseline, 'trials.jsonl'))
			File.write(File.join(baseline, 'environment.json'), JSON.generate(mode: '--smoke'))
			error = assert_raises(RuntimeError) { H::Runner.new('/swift', '/reference', root, work, baseline: baseline) }
			assert_match(/representative full baseline/, error.message)
		end
	end
	def test_profile_environment_excludes_unrelated_secrets_and_redacts_toc_metadata
		Dir.mktmpdir do |root|
			secret_key = 'BUTTER_TEST_UNRELATED_SECRET'
			old_secret = ENV[secret_key]; old_diagnostics = ENV['BUTTER_STORAGE_DIAGNOSTICS']
			prefixed_key = 'BUTTER_BENCHMARK_UNRELATED_SECRET'; old_prefixed = ENV[prefixed_key]
			begin
				ENV[secret_key] = 'synthetic-test-value'; ENV['BUTTER_STORAGE_DIAGNOSTICS'] = '1'
				ENV[prefixed_key] = 'synthetic-test-value'
				refute H.process_environment.key?(secret_key)
				refute H.benchmark_environment.key?(secret_key)
				refute H.benchmark_environment.key?(prefixed_key)
				assert_equal '1', H.benchmark_environment['BUTTER_STORAGE_DIAGNOSTICS']
				assert_equal '1', H.process_environment['BUTTER_STORAGE_DIAGNOSTICS']
				output = File.join(root, 'output')
				assert H.run_bounded([RbConfig.ruby, '-e', 'puts [ENV.key?("BUTTER_TEST_UNRELATED_SECRET"), ENV["BUTTER_STORAGE_DIAGNOSTICS"]].join(" ")'], File.join(root, 'errors'), output: output)
				assert_equal "false 1\n", File.read(output)
				path = File.join(root, 'toc.xml')
				File.write(path, '<trace-toc><environment><item key="SECRET" value="synthetic-test-value"/></environment><table schema="time-profile"/></trace-toc>')
				H.redact_profile_environment(path)
				refute_includes File.read(path), 'synthetic-test-value'
				assert_includes File.read(path), 'schema="time-profile"'
				assert_equal 0600, File.stat(path).mode & 0777
			ensure
				ENV[secret_key] = old_secret; ENV['BUTTER_STORAGE_DIAGNOSTICS'] = old_diagnostics
				ENV[prefixed_key] = old_prefixed
			end
		end
	end
	def test_all_case_profiles_run_each_engine_once_without_warmups_or_repetitions
		Dir.mktmpdir do |root|
			previous = ENV['BUTTER_BENCHMARK_PROFILE_ALL']; ENV['BUTTER_BENCHMARK_PROFILE_ALL'] = '1'
			begin
				owner = self
				runner = H::Runner.new('/swift', '/reference', root, root, profile: true, baseline: nil)
				runner.define_singleton_method(:trial) do |fixture, format, direction, engine, pair, warmup, **_options|
					row = owner.source_trial(nil, engine, pair, warmup: warmup)
					@trials << row.merge(case: fixture.fetch('case'), format: format, direction: direction)
				end
				runner.run(%w[single many concurrent].map { |name| {'case'=>name} })
				rows = runner.instance_variable_get(:@trials)
				assert_equal 36, rows.size
				assert_equal 18, rows.group_by { |row| row.values_at(:case, :format, :direction) }.size
				assert rows.none? { |row| row[:warmup] }
				assert rows.all? { |row| row[:pair] == 0 }
			ensure
				ENV['BUTTER_BENCHMARK_PROFILE_ALL'] = previous
			end
		end
	end
	def test_memory_profile_cli_rejects_timing_and_missing_source_revision_before_building
		Dir.mktmpdir('butter-profile-cli') do |root|
			[['--full', 'with --profile'], ['--profile-source', 'PREVIOUS_REVISION']].each do |mode, message|
				output = File.join(root, mode)
				text, status = Open3.capture2e({ 'BUTTER_BENCHMARK_PROFILER' => 'heap', 'BUTTER_BENCHMARK_PREVIOUS_REVISION' => nil }, File.expand_path('../Scripts/test-benchmark.sh', __dir__), mode, output)
				assert_equal 2, status.exitstatus
				assert_includes text, message
				refute File.exist?(output)
			end
		end
	end
	def test_bounded_commands_capture_stdout_separately_from_errors
		Dir.mktmpdir('butter-command-output') do |root|
			output, log = File.join(root, 'stdout'), File.join(root, 'stderr')
			assert H.run_bounded([RbConfig.ruby, '-e', 'puts "report"; warn "diagnostic"'], log, timeout: 2, output: output)
			assert_equal "report\n", File.read(output)
			assert_equal "diagnostic\n", File.read(log)
		end
	end
	def test_memory_snapshots_use_bounded_tools_and_reject_incomplete_or_failed_reports
		Dir.mktmpdir('butter-memory-snapshots') do |root|
			[:success, :incomplete, :failed].each do |mode|
				calls = []
				capture = lambda do |command, log, timeout:, output:|
					calls << [command, timeout, output]
					File.write(output, mode == :incomplete ? '' : 'REGION TYPE; All zones:')
					mode != :failed
				end
				H.stub(:run_bounded, capture) do
					if mode == :success
						result = H.memory_snapshot(42, File.join(root, 'target'), 'verified')
						assert_equal %w[vmmap heap], result.keys
						assert_equal [['/usr/bin/vmmap', '-summary', '42'], ['/usr/bin/heap', '-s', '42']], calls.map(&:first)
						assert calls.all? { |_, timeout, output| timeout == 10 && output.include?('.verified.') }
					else
						assert_raises(RuntimeError) { H.memory_snapshot(42, File.join(root, 'target'), 'ready') }
						assert_equal 1, calls.size
					end
				end
			end
		end
	end
	def test_source_profiles_capture_both_engines_without_acceptance_statistics
		owner = self
		[true, false].each do |accepted|
			runner = H::Runner.new('/current', '/reference', '/unused', '/unused', profile: true, previous: '/previous', baseline: nil)
			runner.define_singleton_method(:trial) do |fixture, format, direction, engine, pair, warmup, source: nil|
				row = owner.source_trial(source, engine, pair, warmup: warmup)
				row[:direction] = direction; row[:accepted] = accepted || source != 'previous' || engine != 'Swift'; @trials << row
			end
			result = runner.profile_source_case({ 'case' => 'many' }, 'v1', 'download', 17)
			assert_equal accepted ? 'profile-source-only' : 'failed', result[:status]
			refute result.key?(:source_ratios)
			rows = runner.instance_variable_get(:@trials)
			assert_equal %w[previous current].product(%w[Swift libtorrent]).sort, rows.map { |r| r.values_at(:source_variant, :engine) }.sort
			assert rows.none? { |r| r[:warmup] }
		end
	end
	def source_trial(source, engine, pair, warmup: false)
		current = source == 'current'
		{ case: 'many', format: 'v1', direction: 'seed', source_variant: source, engine: engine, pair: pair, warmup: warmup, accepted: true,
			engine_metrics: { cpu_seconds_per_gib: engine == 'Swift' ? (current ? 4.0 : 2.0) : 1.0,
				verified_bytes_per_second: engine == 'Swift' ? (current ? 100.0 : 200.0) : 400.0,
				durable_bytes_per_second: 90.0, whole: { peak_rss: current ? 1050 : 1000 } },
			counterpart_metrics: { cpu_seconds_per_gib: current ? 0.8 : 0.7 } }
	end
	def source_trials
		6.times.flat_map { |pair| %w[previous current].flat_map { |source| %w[Swift libtorrent].map { |engine| source_trial(source, engine, pair) } } }
	end
	def test_source_comparison_pairing_accounts_for_native_control_and_ignores_warmups
		rows = source_trials
		warmup = source_trial('previous', 'Swift', -1, warmup: true); warmup[:engine_metrics][:cpu_seconds_per_gib] = 1000
		result = H.source_summary(rows + [warmup])
		assert_equal 'source-comparison-only', result[:status]
		assert_equal 6, result[:valid_pairs]
		assert_equal 2.0, result[:source_ratios][:cpu_seconds_per_gib][:median]
		assert_equal 0.5, result[:source_ratios][:verified_bytes_per_second][:median]
		assert_in_delta 1.05, result[:source_ratios][:peak_rss][:median], 1e-12
		assert_in_delta 8.0 / 7, result[:source_ratios][:counterpart_cpu_seconds_per_gib][:median], 1e-12
		assert_equal 1.0, result[:native_control_ratios][:cpu_seconds_per_gib][:median]
		assert_equal 1.0, result[:native_control_ratios][:verified_bytes_per_second][:median]
	end
	def test_failed_or_duplicate_source_trials_cannot_be_hidden
		[:failed_native, :duplicate_engine, :failed_warmup].each do |kind|
			rows = source_trials
			case kind
			when :failed_native; rows.find { |r| r[:engine] == 'libtorrent' }[:accepted] = false
			when :duplicate_engine; rows.find { |r| r[:engine] == 'libtorrent' }[:engine] = 'Swift'
			when :failed_warmup
				warmup = source_trial('current', 'Swift', -1, warmup: true); warmup[:accepted] = false; rows << warmup
			end
			assert_equal 'failed', H.source_summary(rows)[:status], kind.to_s
		end
	end
	def test_source_schedule_balances_both_orders_and_uses_one_reference_command
		runner = H::Runner.new('/current', '/reference', '/unused', '/unused', previous: '/previous', baseline: nil)
		assert_equal ['/current'], runner.command_for('Swift', 'current')
		assert_equal ['/previous'], runner.command_for('Swift', 'previous')
		%w[previous current].each { |source| assert_equal ['/reference'], runner.command_for('libtorrent', source) }
		owner = self
		runner.define_singleton_method(:trial) do |fixture, format, direction, engine, pair, warmup, source: nil|
			@trials << owner.source_trial(source, engine, pair, warmup: warmup)
		end
		assert_equal 'source-comparison-only', runner.source_case({ 'case' => 'many' }, 'v1', 'seed', 17)[:status]
		rows = runner.instance_variable_get(:@trials)
		assert_equal 4, rows.count { |r| r[:warmup] }
		measured = rows.reject { |r| r[:warmup] }
		assert_equal 24, measured.size
		assert_equal 3, measured.group_by { |r| r[:pair] }.values.count { |pair| pair.first[:source_variant] == 'previous' }
		%w[previous current].each do |source|
			pairs = measured.select { |r| r[:source_variant] == source }.group_by { |r| r[:pair] }.values
			assert_equal 3, pairs.count { |pair| pair.first[:engine] == 'Swift' }
		end
		observed = measured.group_by { |r| r[:pair] }.values.map { |pair| pair.map { |r| r[:source_variant] }.uniq }
		assert_equal H.orders(6, 2017, labels: %w[previous current]), observed
		assert_raises(RuntimeError) { H.orders(6, 1, labels: %w[current current]) }
		assert H.selected_case?('many', 'v1', 'seed', H::SOURCE_CASES, {})
		refute H.selected_case?('single', 'v1', 'download', H::SOURCE_CASES, {})
	end
	def test_larger_source_schedules_are_fixed_and_balanced
		[12, 24].each do |count|
			runner = H::Runner.new('/current', '/reference', '/unused', '/unused', previous: '/previous', baseline: nil, source_pairs: count)
			owner = self
			runner.define_singleton_method(:trial) do |fixture, format, direction, engine, pair, warmup, source: nil|
				@trials << owner.source_trial(source, engine, pair, warmup: warmup)
			end
			result = runner.source_case({ 'case' => 'many' }, 'v1', 'seed', 17)
			rows = runner.instance_variable_get(:@trials)
			assert_equal 4, rows.count { |row| row[:warmup] }
			assert_equal count, result[:valid_pairs]
			assert_includes result[:method], "fixed #{count} pairs"
			measured = rows.reject { |row| row[:warmup] }.group_by { |row| row[:pair] }.values
			assert_equal count, measured.size
			assert_equal count / 2, measured.count { |pair| pair.first[:source_variant] == 'previous' }
			%w[previous current].each do |source|
				assert_equal count / 2, measured.count { |pair| pair.find { |row| row[:source_variant] == source }[:engine] == 'Swift' }
			end
		end
		assert_raises(ArgumentError) { H::Runner.new('/current', '/reference', '/unused', '/unused', source_pairs: 7) }
	end
	def test_source_pair_options_reject_invalid_values_and_other_modes_before_building
		Dir.mktmpdir do |root|
			[['7', '--compare-source'], ['12', '--smoke']].each do |count, mode|
				output, status = Open3.capture2e({'BUTTER_BENCHMARK_SOURCE_PAIRS'=>count}, '/bin/sh', File.expand_path('../Scripts/test-benchmark.sh', __dir__), mode, File.join(root, 'output'))
				assert_equal 2, status.exitstatus
				assert_includes output, 'Source pair'
				refute File.exist?(File.join(root, 'output'))
			end
		end
	end
	def test_failed_source_variants_keep_distinct_raw_records
		Dir.mktmpdir('butter-source-variants') do |root|
			out, work = File.join(root, 'out'), File.join(root, 'work')
			FileUtils.mkdir_p(out); FileUtils.mkdir_p(File.join(work, 'fixtures/many/seed'))
			File.write(File.join(work, 'fixtures/many/seed/payload'), 'payload')
			fixture = { 'case' => 'many', 'bytes' => 7, 'files' => [{ 'path' => 'payload', 'size' => 7, 'sha256' => 'wrong' }], 'torrents' => { 'v1' => ['fixture.torrent'] } }
			runner = H::Runner.new('/unused/current', '/unused/reference', out, work, previous: '/unused/previous', baseline: nil)
			capture_io { %w[previous current].each { |source| runner.trial(fixture, 'v1', 'seed', 'Swift', 0, false, source: source) } }
			rows = File.readlines(File.join(out, 'trials.jsonl')).map { |line| JSON.parse(line) }
			assert_equal %w[previous current], rows.map { |r| r['source_variant'] }
			assert_equal 2, rows.map { |r| r['id'] }.uniq.size
			assert rows.all? { |r| !r['accepted'] && r['error'].include?('Source digest changed') }
		end
	end
	def with_profiler(mode, name: 'profile')
		Dir.mktmpdir('butter-profiler-test') do |root|
			flag = File.join(root, 'ready')
			notification = Object.new
			notification.define_singleton_method(:ready?) { File.exist?(flag) }
			notification.define_singleton_method(:close) { @closed = true }
			notification.define_singleton_method(:closed?) { @closed }
			program = "trap('INT') { exit 0 unless ARGV[0] == 'ignore' }; abort 'profiler failure' if ARGV[0] == 'fail'; File.write(ARGV[1], 'ready') if %w[ready ignore].include?(ARGV[0]); loop { sleep 0.01 }"
			profiler = H::TimeProfiler.new(0, File.join(root, name), command: [RbConfig.ruby, '-e', program, mode, flag], notification: notification)
			begin; yield profiler, File.join(root, name)
			ensure; profiler.cleanup
			end
			assert notification.closed?
			assert_raises(Errno::ESRCH) { Process.kill(0, profiler.pid) }
		end
	end
	def test_profiler_ready_and_orderly_finish
		with_profiler('ready') do |profiler|
			profiler.wait_ready([], timeout: 2)
			profiler.finish(timeout: 2)
		end
	end
	def test_profile_reports_stay_compact_and_raw_retention_cannot_be_enabled
		previous = ENV['BUTTER_PROFILE_KEEP_RAW']
		begin
			%w[0 1].each do |keep|
				ENV['BUTTER_PROFILE_KEEP_RAW'] = keep
				with_profiler('ready', name: 'profile[1]') do |profiler, prefix|
					profiler.wait_ready([], timeout: 2); profiler.finish(timeout: 2)
					FileUtils.mkdir_p(prefix + '.trace')
					%w[toc samples allocation-table].each { |name| File.write(prefix + ".#{name}.xml", 'raw') }
					File.write(File.join(File.dirname(prefix), 'unrelated.xml'), 'keep')
					profile = {target_pid: 42, running_samples: 25, stacks: (0...25).map { |i| {frames: ["leaf-#{i}"], weight_ns: 1} }}
					H.write_profile_report(prefix, profile)
					profiler.cleanup
					refute File.exist?(prefix + '.trace')
					%w[toc samples allocation-table].each { |name| refute File.exist?(prefix + ".#{name}.xml") }
					assert File.exist?(File.join(File.dirname(prefix), 'unrelated.xml'))
					refute File.exist?(prefix + '.cpu.json')
					result = JSON.parse(File.read(prefix + '.attribution.json'))
					assert_equal 25, result.fetch('weight_ns')
					assert_equal 20, result.fetch('leaves').length
					refute result.key?('stacks')
				end
			end
		ensure
			ENV['BUTTER_PROFILE_KEEP_RAW'] = previous
		end
	end
	def test_cpu_profile_resolves_references_and_excludes_waits_and_other_processes
		Dir.mktmpdir('butter-profile-xml') do |root|
			path = File.join(root, 'profile.xml')
			File.write(path, <<~XML)
				<trace-query-result><node>
				<row><process id="1"><pid>42</pid></process><thread-state id="2">Running</thread-state><weight id="3">1000000</weight><tagged-backtrace id="4"><frame id="5" name="leaf"/><frame name="parent"/><frame name="parent"/></tagged-backtrace></row>
				<row><process ref="1"/><thread-state ref="2"/><weight ref="3"/><tagged-backtrace ref="4"/></row>
				<row><process ref="1"/><thread-state>Waiting</thread-state></row>
				<row><process><pid>43</pid></process><thread-state ref="2"/></row>
				</node></trace-query-result>
			XML
			summary = H.profile_summary(path, 42)
			assert_equal 2, summary[:running_samples]
			assert_equal 2000000, summary[:weight_ns]
			assert_equal ['leaf', 'parent', 'parent'], summary[:stacks].first[:frames]
			assert_equal 100.0, summary[:stacks].first[:percent]
			assert_equal [{ symbol: 'leaf', weight_ns: 2000000, percent: 100.0 }], summary[:flat]
			assert_in_delta 100.0, summary[:categories].sum { |r| r[:percent] }
			assert_equal 'kernel-facing copying', H.profile_category(['mach_msg2_trap', 'vm_copy', 'Data.append'])
			assert_equal 'filesystem metadata/open/close', H.profile_category(['__openat', 'StorageDirectory.inspect'])
			assert_equal 'other user processing or unresolved execution', H.profile_category(['processing', 'StorageWorker.run'])
			assert_equal [100.0, 100.0], summary[:inclusive].map { |row| row[:percent] }
			File.write(path, File.read(path).sub('</node>', '<row><process ref="1"/><thread-state ref="2"/><weight ref="3"/></row></node>'))
			incomplete = H.profile_summary(path, 42)
			assert_equal 3, incomplete[:running_samples]
			assert_equal 1, incomplete[:unavailable_backtrace_samples]
			assert_equal 3000000, incomplete[:weight_ns]
			assert_in_delta 100.0, incomplete[:flat].sum { |row| row[:percent] }, 1e-9
			assert_raises(RuntimeError) { H.profile_summary(path, 44) }
		end
	end
	def test_profiler_failure_deadline_and_counterpart_cleanup
		with_profiler('ignore') do |profiler|
			profiler.wait_ready([], timeout: 2)
			error = assert_raises(RuntimeError) { profiler.finish(timeout: 0.05) }
			assert_match(/finish deadline/, error.message)
		end
		with_profiler('fail') do |profiler|
			error = assert_raises(RuntimeError) { profiler.wait_ready([], timeout: 2) }
			assert_match(/exited before ready/, error.message)
		end
		with_profiler('stall') do |profiler|
			error = assert_raises(RuntimeError) { profiler.wait_ready([], timeout: 0.05) }
			assert_match(/readiness deadline/, error.message)
		end
		with_children(['failed']) do |children|
			with_profiler('stall') do |profiler|
				error = assert_raises(RuntimeError) { profiler.wait_ready(children, timeout: 2) }
				assert_match(/exited before stopped/, error.message)
			end
		end
	end
	def test_profile_defaults_and_explicit_workload_selection
		assert H.profile_case?('single', 'v1', 'seed', {})
		refute H.profile_case?('many', 'v2', 'seed', {})
		filters = { 'BUTTER_BENCHMARK_CASE' => 'many', 'BUTTER_BENCHMARK_FORMAT' => 'v2', 'BUTTER_BENCHMARK_DIRECTION' => 'seed' }
		assert H.profile_case?('many', 'v2', 'seed', filters)
		refute H.profile_case?('single', 'v1', 'seed', filters)
		refute H.profile_case?('many', 'v2', 'seed', { 'BUTTER_BENCHMARK_CASE' => 'many' })
	end
	def test_balanced_reproducible_orders
		[6, 12].each do |count|
			orders = H.orders(count, 42)
			assert_equal orders, H.orders(count, 42)
			assert_equal count / 2, orders.count { |order| order.first == 'Swift' }
			assert orders.all? { |order| order.sort == %w[Swift libtorrent].sort }
		end
		assert_raises(RuntimeError) { H.orders(3, 42) }
	end
	def test_phase_cpu_and_payload_accounting
		child = Object.new
		phases = H::PHASES.each_with_index.to_h { |phase, i| [phase, { 'time' => 10.0 + i, 'user' => i * 0.25, 'system' => i * 0.1, 'payload_bytes' => 1_073_741_824 }] }
		phases.fetch('stopped')['peer_errors'] = ['peer reset']
		child.define_singleton_method(:phase) { |name| phases.fetch(name) }
		child.define_singleton_method(:whole) { { peak_rss: 12345 } }
		metrics = H.metrics(child, 1_073_741_824)
		assert_equal 1_073_741_824, metrics[:verified_bytes_per_second]
		assert_in_delta 1.05, metrics[:cpu_seconds_per_gib], 1e-12
		assert_in_delta 0.75, metrics[:user_cpu_seconds], 1e-12
		assert_in_delta 0.3, metrics[:system_cpu_seconds], 1e-12
		assert_in_delta 25, metrics[:user_cpu_percent], 1e-12
		assert_in_delta 10, metrics[:system_cpu_percent], 1e-12
		assert_in_delta 1.05, metrics[:user_cpu_seconds_per_gib] + metrics[:system_cpu_seconds_per_gib], 1e-12
		assert_in_delta 0.35, metrics[:verified_cpu_seconds_per_gib], 1e-12
		assert_equal 1.0, metrics[:persistence][:wall]
		assert_equal 12345, metrics[:whole][:peak_rss]
		assert_equal ['peer reset'], metrics[:peer_errors]
		assert_raises(RuntimeError) { H.metrics(child, 0) }
		assert_raises(RuntimeError) { H.metrics(child, 1_073_741_823) }
	end
	def test_statistics_retain_failed_pairs_and_uncertainty
		trials = 6.times.flat_map do |pair|
			%w[Swift libtorrent].map do |engine|
				{ engine: engine, pair: pair, warmup: false, accepted: true,
					engine_metrics: { verified_bytes_per_second: 100.0, durable_bytes_per_second: 90.0, cpu_seconds_per_gib: 1.0 } }
			end
		end
		assert_equal 'throughput-and-cpu-pass', H.summary(trials)[:status]
		trials[0][:accepted] = false
		assert_equal 'failed', H.summary(trials)[:status]
		assert_equal 5, H.summary(trials)[:valid_pairs]
		interval = H.interval([0.7, 0.8, 0.9, 0.95, 1.0, 1.1])
		assert interval[:lower] < 0.9
		assert interval[:upper] > 0.9
	end
	def test_memory_uses_whole_process_peaks_and_rejects_failed_baselines
		baseline = 6.times.map { { engine: 'Swift', accepted: true, engine_metrics: { whole: { peak_rss: 1000 } } } }
		candidate = 6.times.map { { engine: 'Swift', accepted: true, engine_metrics: { whole: { peak_rss: 1090 } } } }
		assert_equal 'pass', H.memory_summary(candidate, baseline)[:status]
		candidate[0][:engine_metrics][:whole][:peak_rss] = 1200
		assert_equal 'inconclusive', H.memory_summary(candidate, baseline)[:status]
		candidate.each { |trial| trial[:engine_metrics][:whole][:peak_rss] = 1200 }
		assert_equal 'target-unmet', H.memory_summary(candidate, baseline)[:status]
		baseline[0][:accepted] = false
		assert_equal 'failed', H.memory_summary(candidate, baseline)[:status]
	end
	def test_one_failed_target_cannot_be_hidden_by_another_uncertain_target
		trials = [0.7, 0.8, 0.85, 0.95, 1.0, 1.1].each_with_index.flat_map do |ratio, pair|
			%w[Swift libtorrent].map do |engine|
				{ engine: engine, pair: pair, warmup: false, accepted: true, engine_metrics: {
					verified_bytes_per_second: engine == 'Swift' ? 100 * ratio : 100,
					durable_bytes_per_second: engine == 'Swift' ? 100 * ratio : 100,
					cpu_seconds_per_gib: engine == 'Swift' ? 5 : 1 } }
			end
		end
		summary = H.summary(trials)
		assert_equal 'target-unmet', summary[:status]
		assert summary[:requires_more_pairs]
	end
	def test_source_validation_failure_is_retained_as_a_failed_trial
		Dir.mktmpdir('butter-source-failure') do |root|
			out, work = File.join(root, 'output'), File.join(root, 'work')
			FileUtils.mkdir_p(out); FileUtils.mkdir_p(File.join(work, 'fixtures/single/seed'))
			File.write(File.join(work, 'fixtures/single/seed/payload.bin'), 'payload')
			fixture = { 'case' => 'single', 'bytes' => 7, 'files' => [{ 'path' => 'payload.bin', 'size' => 7, 'sha256' => 'wrong' }], 'torrents' => { 'v1' => ['fixture.torrent'] } }
			runner = H::Runner.new('/unused/Swift', '/unused/reference', out, work, smoke: true, baseline: nil)
			capture_io { runner.trial(fixture, 'v1', 'download', 'Swift', 0, false) }
			record = JSON.parse(File.read(File.join(out, 'trials.jsonl')))
			assert_equal false, record['accepted']
			assert_match(/Source digest changed/, record['error'])
		end
	end
	def with_children(programs)
		Dir.mktmpdir('butter-harness-tests') do |root|
			path = File.join(root, 'child.rb'); File.write(path, <<~RUBY)
				require 'json'
				mode = JSON.parse(File.read(ARGV.last)).fetch('mode')
				phases = %w[prepare ready start verified persistence durable shutdown stopped]
				if mode == 'stall'; sleep 60; end
				if mode == 'failed'; abort 'counterpart failure'; end
				phases = %w[ready] if mode == 'bad-order'
				phases.each_with_index do |phase, index|
				  puts JSON.generate(phase: phase, time: index + 1, user: index * 0.1, system: index * 0.2, peak_rss: 1000)
				  STDOUT.flush
				end
				if mode == 'exit-after-stopped'; STDERR.write([255].pack('C')); abort 'fixture failed after stopped'; end
			RUBY
			children = programs.each_with_index.map do |mode, index|
				job = File.join(root, "job-#{index}.json"); File.write(job, JSON.generate(mode: mode))
				H::Child.new([RbConfig.ruby, path], job, File.join(root, "#{index}.log"))
			end
			begin; yield children
			ensure; children.each(&:cleanup)
			end
			children.each { |child| assert_raises(Errno::ESRCH) { Process.kill(0, child.pid) } }
		end
	end
	def test_phase_protocol_and_whole_process_accounting
		with_children(['ok']) do |children|
			H.wait(children, [[children[0], 'stopped']], timeout: 3)
			children[0].finish
			assert children[0].whole[:peak_rss] > 0
		end
	end
	def test_child_exit_failure_retains_stderr_after_stopped
		with_children(['exit-after-stopped']) do |children|
			H.wait(children, [[children[0], 'stopped']], timeout: 3)
			error = assert_raises(RuntimeError) { children[0].finish }
			assert_match(/fixture failed after stopped/, error.message)
			assert error.message.valid_encoding?
			assert_includes JSON.generate(error: error.message), 'fixture failed after stopped'
		end
	end
	def test_early_child_failure_retains_exit_status_and_stderr
		with_children(['failed']) do |children|
			error = assert_raises(RuntimeError) { H.wait(children, [[children[0], 'ready']], timeout: 3) }
			assert_match(/exited before stopped.*exit 1/, error.message)
			assert_includes error.message, 'counterpart failure'
			assert error.message.valid_encoding?
		end
	end
	def test_deadline_counterpart_failure_and_cleanup
		with_children(['stall']) { |children| assert_raises(RuntimeError) { H.wait(children, [[children[0], 'ready']], timeout: 0.05) } }
		with_children(['stall', 'failed']) do |children|
			error = assert_raises(RuntimeError) { H.wait(children, [[children[0], 'ready']], timeout: 3) }
			assert_match(/exited before stopped/, error.message)
		end
		with_children(['bad-order']) { |children| assert_raises(RuntimeError) { H.wait(children, [[children[0], 'ready']], timeout: 3) } }
	end
end

class WriteProfileTests < Minitest::Test
	H = TransferBenchmarkHarness
	def profile_trial(mode, warmup: false)
		diagnostics = {'writeProfile.jobs'=>2, 'writeProfile.job.cpuNs'=>1_000_000_000, 'writeProfile.phase.payloadSyscall.cpuNs'=>500_000_000, 'writeProfile.phase.payloadSyscall.elapsedNs'=>750_000_000, 'writeProfile.phase.payloadSyscall.calls'=>4,
			'writeProfile.blocksPerJobCount'=>2, 'writeProfile.blocksPerJobSum'=>6, 'writeProfile.blocksPerJobPower2_1'=>1, 'writeProfile.blocksPerJobPower2_2'=>1}
		diagnostics = {} if mode == 'off'
		{accepted: true, warmup: warmup, write_mode: mode, engine_metrics: {cpu_seconds: 2.0, user_cpu_seconds: 1.5, system_cpu_seconds: 0.5, through_durable: {wall: 3.0}}, counterpart_metrics: {cpu_seconds: 1.0},
			events: {'download'=>[{'phase'=>'ready', 'storage_diagnostics'=>{'clock.cpu.resolutionNs'=>1}}, {'phase'=>'start', 'storage_diagnostics'=>{}}, {'phase'=>'durable', 'storage_diagnostics'=>diagnostics}]}}
	end
	def test_fixed_protocol_uses_four_workloads_and_exactly_36_trials
		Dir.mktmpdir do |root|
			owner = self
			runner = H::Runner.new('/swift', '/reference', root, root, write_profile: true, baseline: nil)
			runner.define_singleton_method(:trial) do |fixture, format, direction, engine, pair, warmup, write_mode:|
				@trials << owner.profile_trial(write_mode, warmup: warmup).merge(case: fixture['case'], format: format, direction: direction, engine: engine, pair: pair)
			end
			runner.run(%w[single many concurrent].map { |name| {'case'=>name} })
			rows = runner.instance_variable_get(:@trials)
			assert_equal 36, rows.size
			groups = rows.group_by { |row| row.values_at(:case, :format) }
			assert_equal [['single', 'v1'], ['many', 'hybrid'], ['concurrent', 'v2'], ['concurrent', 'hybrid']], groups.keys
			groups.each_value do |trials|
				assert_equal %w[off counts timed off counts timed timed counts off], trials.map { |row| row[:write_mode] }
				assert_equal [true] * 3 + [false] * 6, trials.map { |row| row[:warmup] }
				assert trials.all? { |row| row[:engine] == 'Swift' && row[:direction] == 'download' }
			end
		end
	end
	def test_report_keeps_cpu_elapsed_and_histogram_upper_bounds_distinct
		rows = %w[off counts timed].map { |mode| profile_trial(mode, warmup: true) } + %w[off counts timed timed counts off].map { |mode| profile_trial(mode) }
		report = H.aggregate_write_profile(rows)
		timed = report[:modes]['timed']
		assert_equal 4, timed[:totals]['jobs']
		assert_equal 1.0, timed[:phases]['payloadSyscall'][:cpu_seconds]
		assert_equal 1.5, timed[:phases]['payloadSyscall'][:elapsed_seconds_sum]
		assert_equal 0.5, timed[:write_job_cpu_share]
		assert_equal 3.0, timed[:distributions]['blocksPerJob'][:mean]
		assert_equal 2, timed[:distributions]['blocksPerJob'][:p50_upper]
		assert_equal 4, timed[:distributions]['blocksPerJob'][:p99_upper]
		rows.first[:accepted] = false
		assert_equal 'failed', H.aggregate_write_profile(rows)[:status]
	end
	def test_timing_gate_rejects_acceptance_runs_and_missing_counters
		[['--full', '1', 'diagnostic only'], ['--profile', '0', 'require BUTTER_STORAGE_DIAGNOSTICS']].each do |mode, counts, message|
			text, status = Open3.capture2e({'BUTTER_STORAGE_WRITE_TIMINGS'=>'1', 'BUTTER_STORAGE_DIAGNOSTICS'=>counts}, File.expand_path('../Scripts/test-benchmark.sh', __dir__), mode)
			assert_equal 2, status.exitstatus
			assert_includes text, message
		end
		previous = ENV['BUTTER_STORAGE_WRITE_TIMINGS']
		begin
			ENV['BUTTER_STORAGE_WRITE_TIMINGS'] = '1'
			assert_equal '1', H.process_environment['BUTTER_STORAGE_WRITE_TIMINGS']
		ensure
			ENV['BUTTER_STORAGE_WRITE_TIMINGS'] = previous
		end
	end
end

class ReceivePipelineProfileTests < Minitest::Test
	H = TransferBenchmarkHarness
	def row(source, mode, warmup)
		pipeline = mode == 'off' ? {} : {'reader.samples'=>2, 'reader.readBytes.count'=>2, 'reader.readBytes.sum'=>65536, 'reader.readBytes.power2.15'=>2,
			'dispatch.blocks.count'=>2, 'dispatch.blocks.sum'=>4, 'dispatch.blocks.power2.1'=>2}
		storage = mode == 'off' ? {} : {'writeQueue.jobs'=>2, 'writeProfile.jobs'=>2}
		pipeline['dispatch.stage.storageWrite.calls'] = 2 unless mode == 'off'
		if mode == 'timed'
			pipeline.merge!('reader.stage.streamRead.elapsedNs'=>30, 'reader.stage.dispatch.elapsedNs'=>60, 'reader.other.elapsedNs'=>10,
				'dispatch.stage.storageWrite.elapsedNs'=>40, 'dispatch.stage.actorEntry.elapsedNs'=>10, 'dispatch.other.elapsedNs'=>10)
			storage.merge!('writeQueue.elapsedNs'=>5, 'writeProfile.job.elapsedNs'=>25)
		end
		{source_variant: source, pipeline_mode: mode, warmup: warmup, accepted: true,
			engine_metrics: {cpu_seconds: 2.0, user_cpu_seconds: 1.5, system_cpu_seconds: 0.5, transfer: {wall: 3.0}}, counterpart_metrics: {cpu_seconds: 1.0},
			events: {'download'=>[{'phase'=>'start'}, {'phase'=>'durable', 'receive_pipeline_diagnostics'=>pipeline, 'storage_diagnostics'=>storage}, {'phase'=>'stopped', 'receive_pipeline_diagnostics'=>pipeline, 'storage_diagnostics'=>storage}]}}
	end
	def test_fixed_modes_and_balanced_source_order_have_exactly_18_trials
		Dir.mktmpdir do |root|
			owner = self
			runner = H::Runner.new('/swift', '/reference', root, root, receive_profile: true, previous: '/previous', baseline: nil)
			runner.define_singleton_method(:trial) do |fixture, format, direction, engine, pair, warmup, source:, pipeline_mode:|
				@trials << owner.row(source, pipeline_mode, warmup).merge(pair: pair)
			end
			runner.run([{'case'=>'many'}])
			rows = runner.instance_variable_get(:@trials)
			assert_equal 18, rows.size
			assert_equal 6, rows.count { |r| r[:warmup] }
			groups = rows.reject { |r| r[:warmup] }.group_by { |r| r[:pair] }
			assert_equal %w[off counts timed timed counts off], groups.values.map { |r| r.first[:pipeline_mode] }
			groups.each { |pair, r| assert_equal pair.even? ? %w[previous current] : %w[current previous], r.map { |item| item[:source_variant] } }
			report = H.receive_pipeline_report(rows)
			timed = report[:modes]['current/timed']
			assert_in_delta 20e-9, timed[:storage_await_breakdown_seconds][:actor_and_completion_remainder], 1e-15
			assert_equal 32768, timed[:distributions]['reader.readBytes'][:p50_upper]
			assert_equal 0, timed[:after_durable]['reader.samples']
			timed_row = rows.find { |item| item[:pipeline_mode] == 'timed' && !item[:warmup] }
			timed_row[:events]['download'].last['receive_pipeline_diagnostics']['dispatch.overlapErrors'] = 1
			assert_raises(RuntimeError) { H.receive_pipeline_report(rows) }
			timed_row[:events]['download'].last['receive_pipeline_diagnostics'].delete('dispatch.overlapErrors')
			timed_row[:events]['download'].last['storage_diagnostics']['writeQueue.jobs'] = 3
			assert_raises(RuntimeError) { H.receive_pipeline_report(rows) }
			timed_row[:events]['download'].last['storage_diagnostics']['writeQueue.jobs'] = 2
			rows.first[:accepted] = false
			assert_equal 'failed', H.receive_pipeline_report(rows)[:status]
		end
	end
	def test_receive_timing_gate_and_source_requirement_are_checked_before_building
		[['--full', '1', 'diagnostic only'], ['--profile', '0', 'require BUTTER_STORAGE_DIAGNOSTICS'], ['--receive-profile', '0', 'PREVIOUS_REVISION']].each do |mode, counts, message|
			timing = mode == '--receive-profile' ? nil : '1'
			text, status = Open3.capture2e({'BUTTER_RECEIVE_PIPELINE_TIMINGS'=>timing, 'BUTTER_STORAGE_DIAGNOSTICS'=>counts, 'BUTTER_BENCHMARK_PREVIOUS_REVISION'=>nil}, File.expand_path('../Scripts/test-benchmark.sh', __dir__), mode)
			assert_equal 2, status.exitstatus
			assert_includes text, message
		end
		previous = ENV['BUTTER_RECEIVE_PIPELINE_TIMINGS']
		begin
			ENV['BUTTER_RECEIVE_PIPELINE_TIMINGS'] = '1'
			assert_equal '1', H.process_environment['BUTTER_RECEIVE_PIPELINE_TIMINGS']
		ensure
			ENV['BUTTER_RECEIVE_PIPELINE_TIMINGS'] = previous
		end
	end
	def test_fused_verification_is_separate_from_actor_and_completion_time
		rows = %w[previous current].flat_map do |source|
			%w[off counts timed].map { |mode| row(source, mode, true) } + %w[off counts timed timed counts off].map { |mode| row(source, mode, false) }
		end
		rows.select { |item| item[:source_variant] == 'current' && item[:pipeline_mode] == 'timed' }.each do |item|
			item[:events]['download'].last['storage_diagnostics']['storageSync.verificationInWrite.elapsedNs'] = 3
		end
		timed = H.receive_pipeline_report(rows)[:modes]['current/timed'][:storage_await_breakdown_seconds]
		assert_in_delta 6e-9, timed[:synchronous_verification_in_write], 1e-15
		assert_in_delta 14e-9, timed[:actor_and_completion_remainder], 1e-15
	end
end
