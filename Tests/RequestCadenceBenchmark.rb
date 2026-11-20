require_relative 'TransferBenchmarkHarness'

module RequestCadenceBenchmark
	Harness = TransferBenchmarkHarness
	def self.payload_digest(fixtures, work)
		digests = fixtures.map do |f|
			hash = Digest::SHA256.new
			f.fetch('files').each_with_index do |file, i|
				raise 'Invalid split order' unless file.fetch('torrent_index') == i
				File.open(File.join(work,'fixtures',f.fetch('case'),'seed',file.fetch('path')), 'rb') do |io|
					while (data = io.read(1048576)); hash << data; end
				end
			end
			hash.hexdigest
		end
		raise 'Partitioning changed the payload' unless digests.uniq.length == 1
		digests.first
	end

	def self.summarise(rows)
		rows.group_by { |r| r.fetch('case') }.transform_values do |trials|
			timing = trials.reject { |r| r['warmup'] || r['pipeline_mode'] }
			counts = trials.select { |r| r['pipeline_mode'] == 'counts' }
			raise 'Incomplete cadence measurements' unless timing.size == 6 && counts.size == 3 && trials.all? { |r| r.fetch('accepted') }
			samples = timing.map do |r|
				client, sender = r.values_at('engine_metrics','counterpart_metrics')
				{client_cpu:client.fetch('cpu_seconds_per_gib'),sender_cpu:sender.fetch('cpu_seconds_per_gib'),
					combined_cpu:client.fetch('cpu_seconds_per_gib')+sender.fetch('cpu_seconds_per_gib'),kernel_cpu:client.fetch('system_cpu_seconds_per_gib'),
					mib_per_s:client.fetch('verified_bytes_per_second')/1048576,peak_mib:client.fetch('whole').fetch('peak_rss')/1048576.0}
			end
			diagnostics = counts.map do |r|
				d = r.fetch('events').fetch('download').find { |e| e.fetch('phase')=='durable' }.fetch('receive_pipeline_diagnostics')
				requests, writes, calls = %w[requests requestWrites fillCalls].map { |k| d.fetch("cadence.#{k}").to_f }
				raise 'Missing request frames or completed payload' unless requests >= 65536 && writes.positive? && d.fetch('reader.payloadBytes') == 1073741824
				busy, empty = d.fetch('cadence.busyNs'), d.fetch('cadence.emptyNs',0)
				{requests_per_write:requests/writes,single_request_writes_pct:100*d.fetch('cadence.singleRequestWrites')/writes,
					blocks_per_read:d.fetch('reader.decodedBlocks').to_f/d.fetch('reader.samples'),request_writes:writes,fill_calls:calls,
					full_window_fills_pct:100*d.fetch('cadence.fullCalls')/calls,empty_peer_time_pct:100.0*empty/(empty+busy)}
			end
			[samples, diagnostics].map { |set| set.first.keys.to_h { |k| [k,Harness.median(set.map { |v| v.fetch(k) }).round(5)] } }.reduce(:merge)
		end
	end
end

if $PROGRAM_NAME == __FILE__
	base, diagnostic, reference, work, output = ARGV.map { |p| File.expand_path(p) }
	fixtures = JSON.parse(File.read(File.join(work,'fixtures','manifest.json')))
	raise 'Expected split-1, split-2 and split-4' unless fixtures.map { |f| f.fetch('case') } == %w[split-1 split-2 split-4]
	digest = RequestCadenceBenchmark.payload_digest(fixtures,work)
	Dir.mktmpdir('cadence-',work) do |out|
		run = lambda do |runner, fixture, pair, warmup, mode|
			runner.trial(fixture,'v1','download','Swift',pair,warmup,pipeline_mode:mode)
			row = JSON.parse(File.readlines(File.join(out,'trials.jsonl')).last)
			raise row['error'] unless row.fetch('accepted')
		end
		h = TransferBenchmarkHarness
		runner = h::Runner.new(base,reference,out,work)
		fixtures.each { |f| run.call(runner,f,-1,true,nil) }
		fixtures.permutation.to_a.shuffle(random:Random.new(20261120)).each_with_index { |order,pair| order.each { |f| run.call(runner,f,pair,false,nil) } }
		runner = h::Runner.new(diagnostic,reference,out,work)
		3.times { |i| fixtures.rotate(i).each { |f| run.call(runner,f,i,false,'counts') } }
		rows = File.readlines(File.join(out,'trials.jsonl')).map { |line| JSON.parse(line) }
		report = {payload_sha256:digest,verified_trials:rows.size,workloads:RequestCadenceBenchmark.summarise(rows)}
		File.open(output,File::WRONLY | File::CREAT | File::EXCL) { |file| file.puts JSON.pretty_generate(report) }
	end
end
