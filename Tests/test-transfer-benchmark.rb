require 'minitest/autorun'
require_relative 'TransferBenchmarkHarness'

class TransferBenchmarkHarnessTests < Minitest::Test
	H = TransferBenchmarkHarness
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
