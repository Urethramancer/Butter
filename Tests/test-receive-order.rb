require 'minitest/autorun'
require_relative 'ReceiveOrderSimulation'

class ReceiveOrderTests < Minitest::Test
	def simulate(events, reorder: true)
		model = ReceiveOrderSimulation.new(reorder: reorder)
		events.each { |event| model.accept(event) }; model.finish
	end
	def test_reordering_and_deadline
		events = [[0.0, 'a', 0, 16384, 16384, 32768], [0.009, 'a', 0, 0, 16384, 32768]]
		assert_equal 0, simulate(events, reorder: false)[:proof_pieces]
		assert_equal 1, simulate(events)[:proof_pieces]
		assert_in_delta 9, simulate(events)[:maximum_wait_ms]
		events[1][0] = 0.011
		assert_equal 0, simulate(events)[:proof_pieces]
		assert_equal 1, simulate(events)[:flush_blocks]['deadline']
	end
	def test_context_limit_is_shared_across_transfers
		events = (0...9).map { |i| [0.0, i.to_s, 0, 0, 16384, 32768] }
		events += (0...9).map { |i| [0.001, i.to_s, 0, 16384, 16384, 32768] }
		assert_equal 8, simulate(events)[:proof_pieces]
	end
	def test_transfer_and_session_capacity
		[1, 5].each do |owners|
			events = (0...17).flat_map { |i| (0...owners).map { |owner| [0.0, owner.to_s, i, 16384, 16384, 32768] } }
			result = simulate(events)
			assert_operator result[:peak_buffer_bytes], :<=, [owners * 262144, 1048576].min
			assert_operator result[:flush_blocks]['capacity'], :>, 0
		end
	end
end
