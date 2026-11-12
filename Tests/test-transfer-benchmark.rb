require 'minitest/autorun'
require_relative 'TransferBenchmarkHarness'

class TransferBenchmarkHarnessTests < Minitest::Test
	H = TransferBenchmarkHarness
	def with_profiler(mode)
		Dir.mktmpdir('butter-profiler-test') do |root|
			flag = File.join(root, 'ready')
			notification = Object.new
			notification.define_singleton_method(:ready?) { File.exist?(flag) }
			notification.define_singleton_method(:close) { @closed = true }
			notification.define_singleton_method(:closed?) { @closed }
			program = "trap('INT') { exit 0 unless ARGV[0] == 'ignore' }; abort 'profiler failure' if ARGV[0] == 'fail'; File.write(ARGV[1], 'ready') if %w[ready ignore].include?(ARGV[0]); loop { sleep 0.01 }"
			profiler = H::TimeProfiler.new(0, File.join(root, 'profile'), command: [RbConfig.ruby, '-e', program, mode, flag], notification: notification)
			begin; yield profiler
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
			assert_equal [{ symbol: 'leaf', weight_ns: 2000000, percent: 100.0 }], summary[:flat]
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
	def test_deadline_counterpart_failure_and_cleanup
		with_children(['stall']) { |children| assert_raises(RuntimeError) { H.wait(children, [[children[0], 'ready']], timeout: 0.05) } }
		with_children(['stall', 'failed']) do |children|
			error = assert_raises(RuntimeError) { H.wait(children, [[children[0], 'ready']], timeout: 3) }
			assert_match(/exited before stopped/, error.message)
		end
		with_children(['bad-order']) { |children| assert_raises(RuntimeError) { H.wait(children, [[children[0], 'ready']], timeout: 3) } }
	end
end
