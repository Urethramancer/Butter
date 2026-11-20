require 'socket'
require_relative 'TransferBenchmarkHarness'

# Delays each chunk from its arrival time. Independent reader and writer threads
# allow multiple chunks in flight and preserve TCP order with bounded memory.
class DelayedPeerRelay
	attr_reader :port
	def initialize(target, delay)
		@listener = TCPServer.new('127.0.0.1', 0)
		@port = @listener.addr[1]
		@threads = []
		@connection = Thread.new do
			@client = @listener.accept
			@seed = TCPSocket.new('127.0.0.1', target)
			[@client, @seed].each { |socket| socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1) }
			[[@client, @seed], [@seed, @client]].each do |input, output|
				queue = SizedQueue.new(32)
				@threads << Thread.new do
					begin
						loop do
							bytes = input.readpartial(65536)
							queue.push([TransferBenchmarkHarness.now + delay, bytes])
						end
					rescue EOFError, IOError, Errno::ECONNRESET
					ensure
						queue.close
					end
				end
				@threads << Thread.new do
					begin
						while (chunk = queue.pop)
							remaining = chunk[0] - TransferBenchmarkHarness.now
							sleep(remaining) if remaining.positive?
							output.write(chunk[1])
						end
						output.close_write
					rescue IOError, Errno::EPIPE, Errno::ECONNRESET
					ensure
						queue.close
					end
				end
			end
		end
	end
	def close
		@connection.kill.join
		[@listener, @client, @seed].compact.each(&:close)
		@threads.each { |thread| thread.kill.join }
	end
end

module PeerWindowBenchmark
	Harness = TransferBenchmarkHarness
	def self.trial(driver, reference, root, fixture, work, delay)
		raise 'Expected one hybrid torrent' unless fixture.fetch('torrents').fetch('hybrid').length == 1
		files = fixture.fetch('files')
		bytes = fixture.fetch('bytes')
		raise 'Payload size mismatch' unless files.sum { |file| file.fetch('size') } == bytes
		source = File.join(root, fixture.fetch('case'))
		seed = File.join(source, 'seed')
		item = {torrent: File.join(source,fixture['torrents']['hybrid'].first), destination: File.join(work,'data'), state: File.join(work,'state')}
		jobs = [{role:'download',items:[item],peerCount:2}] + (1..2).map do |i|
			{role:'seed',reportUploaded:true,items:[item.merge(destination:seed,state:File.join(work,"seed-#{i}"))]}
		end
		children = []; relays = []
		begin
			verify = lambda do |dir|
				files.each do |file|
					path = File.join(dir,file.fetch('path'))
					raise 'File size or digest mismatch' unless File.size(path) == file.fetch('size') && Digest::SHA256.file(path).hexdigest == file.fetch('sha256')
				end
			end
			verify.call(seed)
			jobs.each_with_index do |job,i|
				path = File.join(work,"job-#{i}.json"); File.write(path,JSON.generate(job))
				children << Harness::Child.new([i.zero? ? driver : reference],path,File.join(work,"peer-#{i}.log"))
			end
			wait = ->(peers,phase) { Harness.wait(children,peers.map { |child| [child,phase] }) }
			down, *seeds = children
			wait.call(children,'ready')
			raise 'Unexpected payload geometry' unless children.all? { |child| child.phase('ready').fetch('payload_bytes') == bytes }
			seeds.each do |child|
				relays << DelayedPeerRelay.new(child.phase('ready').fetch('ports').fetch(0),delay)
				child.send_command('start')
			end
			down.send_command('start', ports: relays.map(&:port))
			wait.call([down],'verified')
			seeds.each { |child| child.send_command('verified') }; wait.call(seeds,'verified')
			children.each { |child| child.send_command('persist') }; wait.call(children,'durable')
			uploaded = seeds.map { |child| child.phase('durable').fetch('uploaded_payload_bytes') }
			raise "Both seeds must contribute payload: #{uploaded}" unless uploaded.min.positive? && uploaded.sum >= bytes
			children.each { |child| child.send_command('stop') }; wait.call(children,'stopped')
			children.each(&:finish)
			verify.call(item[:destination])
			children.each_with_index do |child,i|
				raise 'Checkpoint reopen failed' unless Harness.run_bounded([i.zero? ? driver : reference,'--verify',child.job_path],File.join(work,"reopen-#{i}.log"))
			end
			client, *senders = children.map { |child| Harness.metrics(child,bytes) }
			{client_cpu:client[:cpu_seconds_per_gib],sender_cpu:senders.sum { |s| s[:cpu_seconds_per_gib] },mib_per_s:client[:verified_bytes_per_second]/1048576,
				client_peak_mib:client[:whole][:peak_rss]/1048576.0,sender_peaks_mib:senders.map { |s| s[:whole][:peak_rss]/1048576.0 },sender_bytes:uploaded}
		ensure
			children.each(&:cleanup); relays.each(&:close)
		end
	end
end

if $PROGRAM_NAME == __FILE__
	abort 'Usage: ruby PeerWindowBenchmark.rb FIXED32 FIXED48 REFERENCE FIXTURES OUTPUT [ADAPTIVE]' unless (5..6).cover?(ARGV.size)
	previous, current, reference, root, output, adaptive = ARGV.map { |p| File.expand_path(p) }
	fixture = JSON.parse(File.read(File.join(root,'manifest.json'))).find { |f| f['case']=='many' }
	raise 'Expected 1 MiB pieces' unless fixture.fetch('piece_length') == 1048576
	drivers = {'32'=>previous,'48'=>current}
	drivers['adaptive'] = adaptive if adaptive
	orders = if adaptive
		drivers.keys.permutation.to_a.shuffle(random: Random.new(20261120))
	else
		TransferBenchmarkHarness.orders(6,20261120,labels:drivers.keys)
	end
	File.open(output,File::WRONLY | File::CREAT | File::EXCL) do |io|
		([drivers.keys] + orders).each_with_index do |order,i|
			order.each do |window|
				data=Dir.mktmpdir('window-',File.dirname(output)) { |work| PeerWindowBenchmark.trial(drivers.fetch(window),reference,root,fixture,work,0.010) }
				io.puts(JSON.generate(data.merge(window:window,pair:i-1))); io.flush
				puts "window=#{window} pair=#{i-1} verified"; $stdout.flush
			end
		end
	end
end
