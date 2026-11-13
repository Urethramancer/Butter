# Offline attribution of complete exported stacks. Never used for timing acceptance.
require 'json'

module ProfileAttribution
	def self.category(frames)
		leaf = frames.first || '[unavailable backtrace]'
		return 'kernel-facing copying' if frames.include?('vm_copy')
		case leaf
		when /\A(?:__)?(?:openat|open|close|fstatat|fstat|stat|lstat|dup|fcntl|fsync|rename|unlink|mkdir|faccessat|getattrlistbulk)(?:\z|_)/ then 'filesystem metadata/open/close'
		when /\A(?:__)?(?:preadv|pwritev|readv|writev|pread|pwrite|read|write)(?:\z|_)/ then 'payload I/O'
		when /\A(?:__)?(?:recvmsg|sendmsg|recvfrom|sendto|getsockopt|setsockopt|connect|accept|socket)(?:\z|_)/ then 'networking'
		when /mach_msg|kevent|workq_kernreturn|ulock|psynch|thread_switch/ then 'scheduling and event delivery'
		when /sha\d|ccsha|ccdigest|HashFunction/i then 'user hashing'
		when /memmove|memcpy|bzero/ then 'user copying/clearing'
		when /malloc|\A_?free(?:_|\z)|swift_alloc|DataStorage.init/ then 'user allocation'
		when /swift_(?:retain|release)|objc_(?:retain|release)|dealloc/ then 'reference counting and destruction'
		when /start_wqthread|unavailable backtrace/ then 'unattributed'
		else 'other user processing or unresolved execution'
		end
	end
	def self.purpose(frames)
		# Nested checkpoint work is separate from its requesting write or verifier.
		return 'checkpoints and durability' if frames.any? { |f| f.match?(/StorageState\.(?:save\(|prepareVerification\(|requireFlush\(|flush\()/) }
		return 'snapshot integrity and presentation' if frames.any? { |f| f.match?(/StorageState\.snapshot\(|NativeSnapshotMapper|TransferProgress\.init|TCPTransfer\.snapshot\(|TorrentSession\.snapshot\(/) }
		return 'download write jobs' if frames.any? { |f| f.include?('StorageState.writeOperations(') }
		return 'stored-byte authentication' if frames.any? { |f| f.match?(/StorageState\.(?:digestPiece|checkedPiece|verify\()/) }
		return 'upload payload reads' if frames.any? { |f| f.match?(/StorageState\.(?:trustedBytes|verifiedPiece|read\()/) }
		return 'piece and request selection' if frames.any? { |f| f.include?('PiecePicker.') }
		return 'filesystem guards outside attributed jobs' if frames.any? { |f| f.match?(/StorageDirectory\.|StorageStampScan\./) }
		return 'upload admission and cache' if frames.any? { |f| f.match?(/SharedPieceCache|VerifiedPieceCache|TCPTransfer\.(?:upload|requestUpload|finishUpload)/) }
		return 'connection deadlines' if frames.any? { |f| f.include?('ConnectionDeadlines') }
		return 'peer wire and transport' if frames.any? { |f| f.match?(/PeerSession\.|TCPStream\.|PeerWire|NWConnection|nw_connection|nw_socket/) }
		return 'native disk work' if frames.any? { |f| f.match?(/libtorrent.*(?:disk|storage)/) }
		'other runtime or unresolved purpose'
	end
	def self.summarise(profile)
		categories, purposes, leaves, cross = Array.new(4) { Hash.new(0) }
		stacks = profile.fetch('stacks')
		total = stacks.sum { |s| Integer(s.fetch('weight_ns')) }
		raise 'No exported execution samples' unless total > 0
		stacks.each do |sample|
			frames = sample.fetch('frames'); weight = Integer(sample.fetch('weight_ns'))
			raise 'Invalid sample weight' unless weight > 0
			category = category(frames); purpose = purpose(frames)
			categories[category] += weight; purposes[purpose] += weight; leaves[frames.first] += weight
			cross[[purpose, category]] += weight
		end
		rank = ->(values) { values.sort_by { |key, weight| [-weight, key.to_s] }.map { |key, weight| {name: key, weight_ns: weight, percent: 100.0 * weight / total} } }
		{target_pid: profile.fetch('target_pid'), running_samples: profile.fetch('running_samples'), weight_ns: total,
			method: 'Disjoint executing leaves and disjoint stack purposes; sample weights, not CPU durations or kernel residence. Purpose describes sampled ancestry, not inclusive cost. All exported stacks retained in the source CPU report.',
			categories: rank.call(categories), purposes: rank.call(purposes), leaves: rank.call(leaves), purpose_categories: rank.call(cross)}
	end
end

if $PROGRAM_NAME == __FILE__
	ARGV.each do |path|
		profile = JSON.parse(File.read(path))
		out = path.sub(/\.cpu\.json\z/, '.attribution.json')
		raise 'Expected a .cpu.json source' if out == path
		File.write(out, JSON.pretty_generate(ProfileAttribution.summarise(profile)) + "\n")
	end
end
