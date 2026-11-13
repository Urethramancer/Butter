require 'minitest/autorun'
require_relative 'ProfileAttribution'

class ProfileAttributionTests < Minitest::Test
	def test_native_vector_io_and_assembly_hashes_are_not_mislabelled_as_other_user_code
		{'pwritev'=>'payload I/O', '__preadv'=>'payload I/O', 'sha1_block_armv8'=>'user hashing', 'sha256_block_data_order'=>'user hashing', 'swift_release'=>'reference counting and destruction'}.each do |symbol, category|
			assert_equal category, ProfileAttribution.category([symbol])
		end
	end
	def test_complete_stacks_conserve_weight_without_inclusive_double_counting
		profile = {'target_pid'=>42, 'running_samples'=>4, 'stacks'=>[
			{'frames'=>['pwrite', 'StorageState.writeOperations(_:maximumBytes:maximumCount:check:)'], 'weight_ns'=>10},
			{'frames'=>['fsync', 'StorageState.save()', 'StorageState.writeOperations(_:maximumBytes:maximumCount:check:)'], 'weight_ns'=>20},
			{'frames'=>['fstatat', 'StorageState.snapshot()'], 'weight_ns'=>30},
			{'frames'=>['[unavailable backtrace]'], 'weight_ns'=>40}
		]}
		result = ProfileAttribution.summarise(profile)
		%i[categories purposes leaves purpose_categories].each do |key|
			assert_equal 100, result[key].sum { |row| row[:weight_ns] }
			assert_in_delta 100, result[key].sum { |row| row[:percent] }
		end
		purpose = result[:purposes].to_h { |row| [row[:name], row[:weight_ns]] }
		assert_equal 10, purpose['download write jobs']
		assert_equal 20, purpose['checkpoints and durability']
		assert_equal 30, purpose['snapshot integrity and presentation']
		assert_equal 40, purpose['other runtime or unresolved purpose']
		profile['stacks'][0]['weight_ns'] = 0
		assert_raises(RuntimeError) { ProfileAttribution.summarise(profile) }
	end
end
