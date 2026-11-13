require 'minitest/autorun'
require 'open3'
require_relative 'RateSweep'

class RateSweepTests < Minitest::Test
	def test_decimal_rate_conversion_and_metrics
		assert_equal [12_500_000, 31_250_000, 62_500_000, 93_750_000, 125_000_000], RateSweep::RATES.map { |r| RateSweep.bytes_per_second(r) }
		first = {'time'=>5.0, 'user'=>1.0, 'system'=>2.0, 'received_payload_bytes'=>50_000_000}
		[ [1.0, 'saturated'], [0.89, 'unsaturated'], [1.11, 'rate-enforcement-failure'] ].each do |ratio, status|
			bytes = (125_000_000 * ratio).to_i
			last = {'time'=>15.0, 'user'=>3.0, 'system'=>3.0, 'received_payload_bytes'=>50_000_000 + bytes}
			m = RateSweep.metrics(first, last, 100)
			assert_in_delta 12.5 * ratio, m[:mb_per_second]
			assert_in_delta 30, m[:cpu_percent]
			assert_in_delta 20, m[:user_cpu_percent]
			assert_in_delta 10, m[:system_cpu_percent]
			assert_in_delta 3, m[:cpu_seconds]
			assert_in_delta m[:cpu_seconds_per_gib], m[:user_cpu_seconds_per_gib] + m[:system_cpu_seconds_per_gib]
			assert_in_delta 3.0 * 1_073_741_824 / bytes, m[:cpu_seconds_per_gib]
			assert_equal status, m[:rate_status]
			counterpart = RateSweep.metrics(first, last.merge('received_payload_bytes'=>0), 100, received: bytes)
			assert_equal m, counterpart
		end
		assert_raises(RuntimeError) { RateSweep.metrics(first, first, 100) }
	end
	def test_fixed_source_schedule_and_retention_gates
		schedule = RateSweep.comparison_schedule
		assert_equal schedule, RateSweep.comparison_schedule
		assert_equal 28, schedule.size
		assert_equal %w[previous current].product(%w[Swift libtorrent]).sort, schedule.select(&:last).map { |r| r.first(2) }.sort
		pairs = schedule.reject(&:last).group_by { |r| r[2] }.values
		assert_equal 6, pairs.size
		assert_equal 3, pairs.count { |p| p.first.first == 'previous' }
		%w[previous current].each do |source|
			assert_equal 3, pairs.count { |p| p.select { |r| r.first == source }.first[1] == 'Swift' }
		end
		rows = schedule.map do |source, engine, pair, warmup|
			cpu = source == 'current' && engine == 'Swift' ? 0.8 : 1.0
			{source_variant: source, engine: engine, pair: pair, warmup: warmup, validated: true,
				engine_metrics: {cpu_seconds_per_gib: cpu, user_cpu_seconds_per_gib: cpu / 2, system_cpu_seconds_per_gib: cpu / 2, mb_per_second: 62.5, rate_status: 'saturated', whole: {peak_rss: 1000}}, counterpart_metrics: {cpu_seconds_per_gib: 1.0}}
		end
		result = RateSweep.comparison_summary(rows)
		assert_equal 'eligible', result[:retention]
		assert_in_delta 0.8, result[:source_ratios][:system_cpu_seconds_per_gib][:median]
		rows.each { |row| row[:format] = 'v2' }
		assert_equal 'v2', RateSweep.comparison_summary(rows)[:format]
		rows[0][:format] = 'hybrid'
		assert_equal 'failed', RateSweep.comparison_summary(rows)[:status]
		rows[0][:format] = 'v2'
		rows.select { |r| r[:engine] == %q[Swift] && r[:source_variant] == %q[current] }.each { |r| r[:engine_metrics][:whole][:peak_rss] = 2000 }
		refute_equal 'eligible', RateSweep.comparison_summary(rows)[:retention]
		rows[4][:validated] = false
		assert_equal 'failed', RateSweep.comparison_summary(rows)[:status]
		rows[4][:validated] = true; rows[0][:diagnostic] = true
		assert_equal 'failed', RateSweep.comparison_summary(rows)[:status]
	end
	def test_modes_select_500_or_the_existing_sweep
		Dir.mktmpdir do |root|
			FileUtils.mkdir_p(File.join(root, 'fixtures'))
			File.write(File.join(root, 'fixtures', 'manifest.json'), JSON.generate([{'case'=>'many', 'bytes'=>4 * 1_073_741_824}]))
			['--rate-profile', '--rate-compare', '--rate-sweep'].each do |mode|
				out = File.join(root, mode); FileUtils.mkdir_p(out)
				runner = RateSweep::Runner.new('/swift', '/native', out, root, mode, '/previous')
				calls = []
				runner.define_singleton_method(:sample) { |fixture, engine, rate, pair, **options| calls << [engine, rate, pair, options] }
				runner.define_singleton_method(:report) {}
				runner.run
				assert_equal(mode == '--rate-compare' ? 28 : mode == '--rate-profile' ? 2 : 10, calls.size)
				assert_equal(mode == '--rate-sweep' ? RateSweep::RATES : [500], calls.map { |r| r[1] }.uniq.sort)
			end
		end
	end
	def test_rate_modes_reject_invalid_configuration_before_build
		cases = [
			['--rate-profile', {'BUTTER_BENCHMARK_RATE_FORMAT'=>'v1'}, /format/],
			['--rate-compare', {'BUTTER_BENCHMARK_PREVIOUS_REVISION'=>nil}, /PREVIOUS_REVISION/],
			['--rate-compare', {'BUTTER_BENCHMARK_PREVIOUS_REVISION'=>'HEAD', 'BUTTER_STORAGE_DIAGNOSTICS'=>'1'}, /diagnostic/i],
			['--rate-profile', {'BUTTER_BENCHMARK_PROFILER'=>'heap'}, /Time Profiler/],
			['--rate-profile', {'BUTTER_STORAGE_DIAGNOSTICS'=>'1', 'BUTTER_BENCHMARK_PROFILER'=>'time-profiler'}, /separately/]
		]
		cases.each do |mode, env, message|
			text, status = Open3.capture2e(env, File.expand_path('../Scripts/test-benchmark.sh', __dir__), mode)
			assert_equal 2, status.exitstatus
			assert_match message, text
		end
	end
	def test_timed_window_drains_events_and_stops_at_deadline
		input, output = IO.pipe
		child = Struct.new(:output, :received) do
			def read_available; self.received = output.read_nonblock(100); end
		end.new(input)
		output.write('event')
		start = TransferBenchmarkHarness.now
		RateSweep.wait_until([child], start + 0.03)
		assert_equal 'event', child.received
		assert_operator TransferBenchmarkHarness.now - start, :>=, 0.03
		assert_operator TransferBenchmarkHarness.now - start, :<, 0.5
	ensure
		input&.close; output&.close
	end
	def test_partial_claims_check_file_boundaries_and_detect_corruption
		Dir.mktmpdir do |root|
			seed, down = %w[seed down].map { |n| File.join(root, n) }
			[seed, down].each { |d| FileUtils.mkdir_p(d) }
			files = Array.new(128) { |i| {'path'=>"file-#{i}", 'size'=>RateSweep::PIECE} }
			fixture = {'files'=>files, 'bytes'=>128 * RateSweep::PIECE}
			[0,127].each do |i|
				[seed, down].each { |d| File.write(File.join(d, "file-#{i}"), i.chr * RateSweep::PIECE) }
			end
			assert_equal 2, RateSweep.validate_pieces(fixture, seed, down, [0,127])
			[[], [128], [-1], [0,0], (0...128).to_a].each { |claims| assert_raises(RuntimeError) { RateSweep.validate_pieces(fixture, seed, down, claims) } }
			File.open(File.join(down, 'file-127'), 'r+') { |f| f.write('x') }
			assert_raises(RuntimeError) { RateSweep.validate_pieces(fixture, seed, down, [127]) }
		end
	end
	def test_sweep_rejects_diagnostics_before_build
		[['BUTTER_STORAGE_DIAGNOSTICS', '1'], ['BUTTER_BENCHMARK_PROFILER', 'heap']].each do |key, value|
			text, status = Open3.capture2e({key=>value}, File.expand_path('../Scripts/test-benchmark.sh', __dir__), '--rate-sweep')
			assert_equal 2, status.exitstatus
			assert_match(/diagnostic|profil/i, text)
		end
	end
end
