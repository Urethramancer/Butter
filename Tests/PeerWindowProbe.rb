require 'set'
require_relative 'PeerWindowBenchmark'

# Count outstanding requests at the plaintext relay without retaining payloads
# beyond one incomplete frame per direction. Only diagnostic trials use this.
class PeerWindowProbe
	attr_reader :peak, :periods
	def initialize(slow_first: nil)
		@slow_first = slow_first
		@buffers = [String.new(encoding: Encoding::BINARY), String.new(encoding: Encoding::BINARY)]
		@handshaken = [false, false]
		@pending = Set.new
		@peak = 0
		@periods = Array.new(2) { {peak: 0, payload_bytes: 0} }
	end
	def connected
		@start = TransferBenchmarkHarness.now
		@available = @start
	end
	def delivery_time(direction, earliest, bytes)
		return earliest unless direction == 1 && !@slow_first.nil?
		slow = (TransferBenchmarkHarness.now - @start < 8) == @slow_first
		@available = slow ? [earliest, @available].max + bytes.fdiv(4 * 1048576) : earliest
	end
	def observe(direction, bytes)
		elapsed = TransferBenchmarkHarness.now - @start
		period = if (2...7).cover?(elapsed) then @periods.first elsif (11...16).cover?(elapsed) then @periods.last end
		buffer = @buffers.fetch(direction)
		buffer << bytes
		unless @handshaken[direction]
			return if buffer.bytesize < 68
			raise 'Expected a plaintext handshake' unless buffer.start_with?("\x13BitTorrent protocol")
			buffer.slice!(0,68)
			@handshaken[direction] = true
		end
		while buffer.bytesize >= 4
			length = buffer.unpack1('N')
			raise 'Unexpected benchmark frame size' if length > 131072
			break if buffer.bytesize < length + 4
			frame = buffer.slice!(0, length + 4)
			next if length.zero?
			case [direction, frame.getbyte(4)]
			when [0,6]
				@pending.add(frame.byteslice(5,12))
				@peak = [@peak, @pending.size].max
				period[:peak] = [period[:peak], @pending.size].max if period
			when [0,8], [1,16]
				@pending.delete(frame.byteslice(5,12))
			when [1,7]
				@pending.delete(frame.byteslice(5,8) + [length-9].pack('N'))
				period[:payload_bytes] += length-9 if period
			end
		end
	end
end

if $PROGRAM_NAME == __FILE__
	abort 'Usage: ruby PeerWindowProbe.rb DRIVER REFERENCE FIXTURE_ROOT OUTPUT' unless ARGV.size == 4
	driver, reference, root, output = ARGV.map { |p| File.expand_path(p) }
	fixture = JSON.parse(File.read(File.join(root,'manifest.json'))).find { |f| f.fetch('case') == 'many' }
	raise 'Expected 1 MiB pieces' unless fixture.fetch('piece_length') == 1048576
	File.open(output,File::WRONLY | File::CREAT | File::EXCL) do |io|
		%w[loopback delayed swap].each do |mode|
			probes = Array.new(2) { |i| PeerWindowProbe.new(slow_first: mode == 'swap' ? i.zero? : nil) }
			trial = Dir.mktmpdir('probe-', File.dirname(output)) do |work|
				PeerWindowBenchmark.trial(driver,reference,root,fixture,work,mode == 'loopback' ? 0 : 0.010,probes: probes)
			end
			io.puts JSON.generate(mode:mode,peaks:probes.map(&:peak),periods:probes.map(&:periods),sender_bytes:trial[:sender_bytes]); io.flush
		end
	end
end
