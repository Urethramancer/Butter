# Exploratory timed downloads, deliberately separate from full-transfer acceptance.
require_relative 'TransferBenchmarkHarness'

module RateSweep
	H = TransferBenchmarkHarness
	RATES = [100, 250, 500, 750, 1000].freeze
	PIECE = 262_144
	def self.bytes_per_second(mbps)
		raise 'Unsupported sweep rate' unless RATES.include?(mbps)
		mbps * 1_000_000 / 8
	end
	def self.metrics(first, last, rate, received: nil)
		value = H.delta(first, last)
		bytes = received || last.fetch('received_payload_bytes') - first.fetch('received_payload_bytes')
		raise 'Invalid measured accounting' unless value.values.all? { |v| v.finite? && v >= 0 } && value[:wall] > 0 && bytes > 0
		cpu = value[:user] + value[:system]
		ratio = bytes / value[:wall] / bytes_per_second(rate)
		value.merge(received_payload_bytes: bytes, mb_per_second: bytes / value[:wall] / 1e6,
			cpu_percent: 100 * cpu / value[:wall], cpu_seconds_per_gib: cpu / (bytes.to_f / 1_073_741_824),
			rate_status: ratio > 1.1 ? 'rate-enforcement-failure' : ratio < 0.9 ? 'unsaturated' : 'saturated')
	end
	# The sweep fixture has 128 aligned files and no pad spans. Compare each claimed
	# piece independently with the source, rather than trusting either engine's hash.
	def self.validate_pieces(fixture, seed, destination, pieces)
		files = fixture.fetch('files')
		raise 'Invalid sweep fixture' unless files.size == 128 && files.all? { |f| f.fetch('size') % PIECE == 0 } && files.sum { |f| f.fetch('size') } == fixture.fetch('bytes')
		count = fixture.fetch('bytes') / PIECE
		raise 'Invalid partial piece claims' unless pieces.is_a?(Array) && !pieces.empty? && pieces.size < count && pieces.uniq.size == pieces.size && pieces.all? { |p| p.is_a?(Integer) && p >= 0 && p < count }
		pieces.each do |piece|
			offset = piece * PIECE
			file = files.find do |entry|
				if offset < entry.fetch('size'); true
				else offset -= entry.fetch('size'); false
				end
			end
			expected = File.binread(File.join(seed, file.fetch('path')), PIECE, offset)
			actual = File.binread(File.join(destination, file.fetch('path')), PIECE, offset)
			raise "Claimed piece differs from fixture: #{piece}" unless actual.bytesize == PIECE && actual == expected
		end
		pieces.size
	end
	def self.wait_until(children, deadline)
		while H.now < deadline
			readers = children.map(&:output).compact
			raise 'Sweep children exited during timed window' if readers.size != children.size
			ready = IO.select(readers, nil, nil, [deadline - H.now, 0.05].min)
			children.each { |child| child.read_available if ready && ready[0].include?(child.output) }
		end
	end
	class Runner
		def initialize(swift, reference, output, work)
			@commands = { 'Swift' => [swift], 'libtorrent' => [reference] }
			@output, @work, @samples = output, work, []
		end
		def sample(fixture, engine, rate, sequence)
			id = "#{sequence}-#{rate}-#{engine}"
			folder = File.join(@work, id); logs = File.join(@output, id)
			FileUtils.mkdir_p(folder); FileUtils.mkdir_p(logs)
			root = File.join(@work, 'fixtures', 'many')
			item = { torrent: File.join(root, fixture.fetch('torrents').fetch('hybrid').fetch(0)), destination: File.join(folder, 'download'), state: File.join(folder, 'download-state') }
			jobs = { 'seed' => {role: 'seed', partial: true, upload_bytes_per_second: RateSweep.bytes_per_second(rate), items: [item.merge(destination: File.join(root, 'seed'), state: File.join(folder, 'seed-state'))]},
				'download' => {role: 'download', partial: true, items: [item]} }
			children = []; roles = {}
			record = {id: id, engine: engine, mbps: rate, validated: false, exploratory: true}
			begin
				fixture.fetch('files').each do |file|
					path = File.join(root, 'seed', file.fetch('path'))
					raise 'Fixture changed' unless File.size(path) == file.fetch('size') && Digest::SHA256.file(path).hexdigest == file.fetch('sha256')
				end
				jobs.each do |role, job|
					path = File.join(folder, "#{role}.json"); File.write(path, JSON.generate(job))
					roles[role] = H::Child.new(@commands.fetch(role == 'seed' ? 'libtorrent' : engine), path, File.join(logs, "#{role}.log")); children << roles[role]
				end
				seed, down = roles.values_at('seed', 'download')
				H.wait(children, children.map { |c| [c, 'ready'] })
				raise 'Metadata size mismatch' unless children.all? { |c| c.phase('ready').fetch('payload_bytes') == fixture.fetch('bytes') }
				settings = seed.phase('ready').fetch('request_window')
				raise 'Loopback rate enforcement missing' unless settings['loopback_global_class'] == true && settings['upload_bytes_per_second'] == RateSweep.bytes_per_second(rate)
				seed.send_command('start'); down.send_command('start', ports: seed.phase('ready').fetch('ports'))
				H.wait(children, children.map { |c| [c, 'start'] })
				RateSweep.wait_until(children, H.now + 5)
				children.each { |c| c.send_command('measurement-start') }
				H.wait(children, children.map { |c| [c, 'measurement-start'] })
				RateSweep.wait_until(children, H.now + 10)
				children.each { |c| c.send_command('measurement-end') }
				H.wait(children, children.map { |c| [c, 'measurement-end'] })
				record[:engine_metrics] = RateSweep.metrics(down.phase('measurement-start'), down.phase('measurement-end'), rate)
				record[:counterpart_metrics] = RateSweep.metrics(seed.phase('measurement-start'), seed.phase('measurement-end'), rate, received: record[:engine_metrics][:received_payload_bytes])
				children.each { |c| c.send_command('quiesce') }
				H.wait(children, children.map { |c| [c, 'verified'] })
				children.each { |c| c.send_command('persist') }
				H.wait(children, children.map { |c| [c, 'durable'] })
				children.each { |c| c.send_command('stop') }
				H.wait(children, children.map { |c| [c, 'stopped'] })
				children.each(&:finish)
				pieces = down.phase('durable').fetch('verified_pieces')
				record[:checked_pieces] = RateSweep.validate_pieces(fixture, File.join(root, 'seed'), item[:destination], pieces)
				reopen = File.join(logs, 'reopened.jsonl')
				raise 'Partial checkpoint reopen failed' unless H.run_bounded([*@commands.fetch(engine), '--verify', down.job_path], File.join(logs, 'reopen.log'), output: reopen)
				claims = File.readlines(reopen).map { |l| JSON.parse(l) }.find { |e| e['phase'] == 'reopened' }.fetch('verified_pieces')
				raise 'Restored piece claims changed' unless claims.sort == pieces.sort
				record[:validated] = true
			rescue StandardError => error
				record[:error] = "#{error.class}: #{error.message}"
			ensure
				record[:events] = roles.transform_values(&:events)
				children.each(&:cleanup)
				File.open(File.join(@output, 'rate-sweep.jsonl'), 'a') { |f| f.puts(JSON.generate(record)) }
				@samples << record
				FileUtils.rm_rf(folder)
			end
			puts "#{id}: #{record[:validated] ? 'partial checkpoint validated' : record[:error]}"; $stdout.flush
		end
		def report
			File.write(File.join(@output, 'rate-sweep-summary.json'), JSON.pretty_generate(@samples.map { |s| s.reject { |k, _| k == :events } }))
			lines = ['Exploratory: one sample per engine/rate; 5s settle, 10s measured. CPU 100% = one core. Decimal MB/s. No statistical significance or full-transfer acceptance claim.', '',
				'| Mbps | Butter MB/s | CPU % | CPU s/GiB | Seed CPU % | Status | libtorrent MB/s | CPU % | CPU s/GiB | Seed CPU % | Status |',
				'| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |']
			RATES.each do |rate|
				cells = %w[Swift libtorrent].flat_map do |engine|
					s = @samples.find { |r| r[:mbps] == rate && r[:engine] == engine }; m = s && s[:engine_metrics]
					m ? [format('%.2f', m[:mb_per_second]), format('%.1f', m[:cpu_percent]), format('%.2f', m[:cpu_seconds_per_gib]), format('%.1f', s[:counterpart_metrics][:cpu_percent]), s[:validated] ? m[:rate_status] : 'validation-failed'] : ['—', '—', '—', '—', 'failed']
				end
				lines << "| #{([rate] + cells).join(' | ')} |"
			end
			File.write(File.join(@output, 'rate-sweep.md'), lines.join("\n") + "\n")
		end
		def run
			Signal.trap('TERM') { raise Interrupt, 'Sweep terminated' }
			manifest = File.join(@work, 'fixtures', 'manifest.json')
			FileUtils.cp(manifest, File.join(@output, 'fixtures.json'))
			fixture = JSON.parse(File.read(manifest)).fetch(0)
			raise 'Expected 4 GiB many-file fixture' unless fixture['case'] == 'many' && fixture['bytes'] == 4 * 1_073_741_824
			RATES.shuffle(random: Random.new(11011)).each_with_index do |rate, index|
				order = index.even? ? %w[Swift libtorrent] : %w[libtorrent Swift]
				order.each { |engine| sample(fixture, engine, rate, index); report }
			end
			raise 'Sweep contains failed partial validations' if @samples.any? { |s| !s[:validated] }
			raise 'Sweep rate enforcement failed' if @samples.any? { |s| s.dig(:engine_metrics, :rate_status) == 'rate-enforcement-failure' }
		end
	end
end
RateSweep::Runner.new(*ARGV).run if $PROGRAM_NAME == __FILE__
