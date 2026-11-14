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
			cpu_seconds: cpu, user_cpu_percent: 100 * value[:user] / value[:wall], system_cpu_percent: 100 * value[:system] / value[:wall],
			user_cpu_seconds_per_gib: value[:user] / (bytes.to_f / 1_073_741_824), system_cpu_seconds_per_gib: value[:system] / (bytes.to_f / 1_073_741_824),
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
	# Fixed schedule: one warm-up per source/engine, then six balanced source
	# pairs with independently balanced engine order and an identical native control.
	def self.comparison_schedule(seed = 500)
		warmups = %w[previous current].product(%w[Swift libtorrent]).map { |source, engine| [source, engine, -1, true] }
		engine_orders = %w[previous current].to_h { |source| [source, H.orders(6, seed + (source == 'current' ? 1 : 0))] }
		warmups + H.orders(6, seed + 2, labels: %w[previous current]).each_with_index.flat_map do |sources, pair|
			sources.flat_map { |source| engine_orders.fetch(source)[pair].map { |engine| [source, engine, pair, false] } }
		end
	end
	def self.comparison_summary(samples)
		return {status: 'failed', reason: 'Diagnostic samples cannot be compared'} if samples.any? { |s| s[:diagnostic] }
		formats = samples.map { |s| s.fetch(:format, 'hybrid') }.uniq
		return {status: 'failed', reason: 'Mixed torrent formats'} unless formats.size == 1 && %w[hybrid v2].include?(formats.first)
		expected = %w[previous current].product(%w[Swift libtorrent]).sort
		warmups = samples.select { |r| r[:warmup] }
		pairs = samples.reject { |r| r[:warmup] }.group_by { |r| r[:pair] }.values
		valid = pairs.select { |pair| pair.map { |r| [r[:source_variant], r[:engine]] }.sort == expected }
		return {status: 'failed', pairs: pairs.size, valid_pairs: valid.size} unless pairs.size == 6 && valid.size == 6 && warmups.map { |r| [r[:source_variant], r[:engine]] }.sort == expected && samples.all? { |r| r[:validated] && r.dig(:engine_metrics, :rate_status) == 'saturated' }
		specs = {cpu_seconds_per_gib: [:engine_metrics, :cpu_seconds_per_gib], user_cpu_seconds_per_gib: [:engine_metrics, :user_cpu_seconds_per_gib], system_cpu_seconds_per_gib: [:engine_metrics, :system_cpu_seconds_per_gib], mb_per_second: [:engine_metrics, :mb_per_second], peak_rss: [:engine_metrics, :whole, :peak_rss], counterpart_cpu_seconds_per_gib: [:counterpart_metrics, :cpu_seconds_per_gib]}
		paired = lambda do |engine, path|
			H.interval(pairs.map do |pair|
				previous, current = %w[previous current].map { |source| pair.find { |r| r[:source_variant] == source && r[:engine] == engine }.dig(*path) }
				raise 'Invalid rate comparison measurement' unless [previous, current].all? { |v| v.is_a?(Numeric) && v.finite? && v > 0 }
				current.to_f / previous
			end)
		end
		result = {status: 'rate-source-comparison-only', format: formats.first, pairs: 6, valid_pairs: 6,
			source_ratios: specs.transform_values { |path| paired.call('Swift', path) },
			native_control_ratios: specs.transform_values { |path| paired.call('libtorrent', path) }}
		r = result[:source_ratios]
		peaks = %w[previous current].map { |source| samples.select { |row| row[:source_variant] == source && row[:engine] == 'Swift' && !row[:warmup] }.map { |row| row.dig(:engine_metrics, :whole, :peak_rss) }.max }
		result[:maximum_peak_rss_ratio] = peaks[1].to_f / peaks[0]
		result[:retention] = if r[:cpu_seconds_per_gib][:upper] < 1 && r[:mb_per_second][:upper] >= 1 && r[:counterpart_cpu_seconds_per_gib][:lower] <= 1 && r[:peak_rss][:upper] <= 1.1 && result[:maximum_peak_rss_ratio] <= 1.1
			'eligible'
		else
			'insufficient-or-regressed'
		end
		result[:method] = 'Current/previous within six fixed balanced source pairs; paired 95% bootstrap intervals; instrumented runs excluded; no automatic repetitions'
		result
	end
	class Runner

		def initialize(swift, reference, output, work, mode = '--rate-sweep', previous = nil)
			@commands = { 'Swift' => [swift], 'libtorrent' => [reference] }
			@output, @work, @samples = output, work, []
			@format = ENV.fetch('BUTTER_BENCHMARK_RATE_FORMAT', 'hybrid')
			raise 'Rate format must be hybrid or v2' unless %w[hybrid v2].include?(@format)
			@mode = mode
			@previous = previous
			raise 'Rate comparison needs a previous driver' if mode == '--rate-compare' && (previous.nil? || previous.empty?)
			@profile = mode == '--rate-profile'
			@counters = ENV['BUTTER_STORAGE_DIAGNOSTICS'] == '1'
			raise 'Instrumented runs cannot be compared' if !@profile && (@counters || ENV.fetch('BUTTER_BENCHMARK_PROFILER', 'sample') != 'sample')
		end
		def sample(fixture, engine, rate, sequence, source: nil, warmup: false)
			id = [source, sequence, rate, engine, warmup ? "warmup" : "measured"].compact.join("-")
			folder = File.join(@work, id); logs = File.join(@output, id)
			FileUtils.mkdir_p(folder); FileUtils.mkdir_p(logs)
			root = File.join(@work, 'fixtures', 'many')
			item = { torrent: File.join(root, fixture.fetch('torrents').fetch(@format).fetch(0)), destination: File.join(folder, 'download'), state: File.join(folder, 'download-state') }
			jobs = { 'seed' => {role: 'seed', partial: true, upload_bytes_per_second: RateSweep.bytes_per_second(rate), items: [item.merge(destination: File.join(root, 'seed'), state: File.join(folder, 'seed-state'))]},
				'download' => {role: 'download', partial: true, items: [item]} }
			jobs['download'][:profileHoldAfterStop] = true if @profile && !@counters
			children = []; roles = {}; trace = nil
			commands = @commands.merge('Swift' => source == 'previous' ? [@previous] : @commands.fetch('Swift'))
			record = {id: id, engine: engine, format: @format, mbps: rate, validated: false, exploratory: true, pair: sequence, warmup: warmup, source_variant: source, diagnostic: @profile}
			begin
				fixture.fetch('files').each do |file|
					path = File.join(root, 'seed', file.fetch('path'))
					raise 'Fixture changed' unless File.size(path) == file.fetch('size') && Digest::SHA256.file(path).hexdigest == file.fetch('sha256')
				end
				jobs.each do |role, job|
					path = File.join(folder, "#{role}.json"); File.write(path, JSON.generate(job))
					roles[role] = H::Child.new(commands.fetch(role == 'seed' ? 'libtorrent' : engine), path, File.join(logs, "#{role}.log")); children << roles[role]
				end
				seed, down = roles.values_at('seed', 'download')
				H.wait(children, children.map { |c| [c, 'ready'] })
				raise 'Metadata size mismatch' unless children.all? { |c| c.phase('ready').fetch('payload_bytes') == fixture.fetch('bytes') }
				settings = seed.phase('ready').fetch('request_window')
				raise 'Loopback rate enforcement missing' unless settings['loopback_global_class'] == true && settings['upload_bytes_per_second'] == RateSweep.bytes_per_second(rate)
				if @profile && !@counters
					trace = H::TimeProfiler.new(down.phase('ready').fetch('pid'), File.join(logs, 'download'))
					trace.wait_ready(children)
					record[:profiler] = {name: 'Time Profiler', capture_window: 'attached before transfer start through stopped after durable engine/storage shutdown; includes settle, measurement, drain, persistence and final shutdown', running_samples_only: true, counterpart_instrumented: false}
				end
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
				if trace
					trace.finish
					down.send_command('release')
				end
				children.each(&:finish)
				record[:engine_metrics][:whole] = down.whole
				record[:counterpart_metrics][:whole] = seed.whole
				if trace
					trace.export
					H.write_profile_report(File.join(logs, 'download'), H.profile_summary(File.join(logs, 'download.samples.xml'), down.phase('ready').fetch('pid')))
				end
				pieces = down.phase('durable').fetch('verified_pieces')
				record[:checked_pieces] = RateSweep.validate_pieces(fixture, File.join(root, 'seed'), item[:destination], pieces)
				reopen = File.join(logs, 'reopened.jsonl')
				raise 'Partial checkpoint reopen failed' unless H.run_bounded([*commands.fetch(engine), '--verify', down.job_path], File.join(logs, 'reopen.log'), output: reopen)
				claims = File.readlines(reopen).map { |l| JSON.parse(l) }.find { |e| e['phase'] == 'reopened' }.fetch('verified_pieces')
				raise 'Restored piece claims changed' unless claims.sort == pieces.sort
				record[:validated] = true
			rescue StandardError => error
				record[:error] = "#{error.class}: #{error.message}"
			ensure
				record[:events] = roles.transform_values(&:events)
				children.each(&:cleanup)
				trace.cleanup if trace
				File.open(File.join(@output, 'rate-sweep.jsonl'), 'a') { |f| f.puts(JSON.generate(record)) }
				@samples << record
				FileUtils.rm_rf(folder)
			end
			puts "#{id}: #{record[:validated] ? 'partial checkpoint validated' : record[:error]}"; $stdout.flush
		end
		def report
			File.write(File.join(@output, 'rate-sweep-summary.json'), JSON.pretty_generate(@samples.map { |s| s.reject { |k, _| k == :events } }))
			if @mode == '--rate-compare'
				File.write(File.join(@output, 'rate-comparison.json'), JSON.pretty_generate(RateSweep.comparison_summary(@samples)))
			end
			lines = [@profile ? 'Diagnostic interval: transfer start through stopped after durable engine/storage shutdown. Instrumented samples excluded from performance comparisons.' : 'Timed partial downloads: 5s settle, 10s measured. CPU 100% = one core. Decimal MB/s. No full-transfer acceptance claim.', '',
				'| Sample | Engine | Mbps | MB/s | User s | System s | Total s | User % | System % | Total % | User s/GiB | System s/GiB | Total s/GiB | Peak MiB | Seed CPU % | Seed CPU s/GiB | Status |',
				'| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |']
			@samples.each do |s|
				m = s[:engine_metrics]; c = s[:counterpart_metrics]
				numbers = m ? [m[:mb_per_second], m[:user], m[:system], m[:cpu_seconds], m[:user_cpu_percent], m[:system_cpu_percent], m[:cpu_percent], m[:user_cpu_seconds_per_gib], m[:system_cpu_seconds_per_gib], m[:cpu_seconds_per_gib], m.dig(:whole, :peak_rss).to_f / 1_048_576, c[:cpu_percent], c[:cpu_seconds_per_gib]].map { |v| format('%.3f', v) } : Array.new(13, '—')
				lines << "| #{([s[:id], s[:engine], s[:mbps]] + numbers + [s[:validated] ? m[:rate_status] : 'validation-failed']).join(' | ')} |"
			end
			File.write(File.join(@output, 'rate-sweep.md'), lines.join("\n") + "\n")
		end
		def run
			Signal.trap('TERM') { raise Interrupt, 'Sweep terminated' }
			manifest = File.join(@work, 'fixtures', 'manifest.json')
			FileUtils.cp(manifest, File.join(@output, 'fixtures.json'))
			fixture = JSON.parse(File.read(manifest)).fetch(0)
			raise 'Expected 4 GiB many-file fixture' unless fixture['case'] == 'many' && fixture['bytes'] == 4 * 1_073_741_824
			if @mode == '--rate-compare'
				RateSweep.comparison_schedule.each { |source, engine, pair, warmup| sample(fixture, engine, 500, pair, source: source, warmup: warmup); report }
			else
				(@profile ? [500] : RATES).shuffle(random: Random.new(11011)).each_with_index do |rate, index|
					order = index.even? ? %w[Swift libtorrent] : %w[libtorrent Swift]
					order.each { |engine| sample(fixture, engine, rate, index); report }
				end
			end
			raise 'Sweep contains failed partial validations' if @samples.any? { |s| !s[:validated] }
			raise 'Sweep rate enforcement failed' if @samples.any? { |s| s.dig(:engine_metrics, :rate_status) == 'rate-enforcement-failure' }
		end
	end
end
RateSweep::Runner.new(*ARGV).run if $PROGRAM_NAME == __FILE__
