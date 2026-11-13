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
			assert_in_delta 3.0 * 1_073_741_824 / bytes, m[:cpu_seconds_per_gib]
			assert_equal status, m[:rate_status]
			counterpart = RateSweep.metrics(first, last.merge('received_payload_bytes'=>0), 100, received: bytes)
			assert_equal m, counterpart
		end
		assert_raises(RuntimeError) { RateSweep.metrics(first, first, 100) }
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
