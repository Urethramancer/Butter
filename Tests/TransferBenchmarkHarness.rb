# Shared controller/statistics for Scripts/test-benchmark.sh. No third-party gems.
require 'json'
require 'digest'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'
require 'time'

module TransferBenchmarkHarness
	PHASES = %w[prepare ready start verified persistence durable shutdown stopped].freeze
	PROFILE_CASES = [['single', 'v1', 'download'], ['single', 'hybrid', 'download'], ['many', 'hybrid', 'download'], ['single', 'v1', 'seed']].freeze
	SOURCE_CASES = [['many', 'v1', 'seed'], ['concurrent', 'v2', 'seed']].freeze
	def self.profile_case?(workload, format, direction, filters = ENV)
		return true if filters['BUTTER_BENCHMARK_PROFILE_ALL'] == '1'
		selected_case?(workload, format, direction, PROFILE_CASES, filters)
	end
	def self.selected_case?(workload, format, direction, defaults, filters = ENV)
		requested = %w[BUTTER_BENCHMARK_CASE BUTTER_BENCHMARK_FORMAT BUTTER_BENCHMARK_DIRECTION].map { |key| filters[key] }
		requested.all? ? requested == [workload, format, direction] : defaults.include?([workload, format, direction])
	end
	def self.now
		Process.clock_gettime(Process::CLOCK_MONOTONIC)
	end
	# Instruments records the target environment. Do not propagate unrelated credentials.
	def self.process_environment
		keys = %w[PATH HOME TMPDIR LANG LC_ALL LC_CTYPE USER LOGNAME DEVELOPER_DIR SDKROOT BUTTER_STORAGE_DIAGNOSTICS BUTTER_RECEIVE_ORDER_TRACE]
		ENV.to_h.select { |key, _| keys.include?(key) }
	end
	def self.redact_profile_environment(path)
		text = File.read(path)
		File.write(path, text.gsub(/<environment(?:\s[^>]*)?>.*?<\/environment>/m, '<environment redacted="true"/>'))
		File.chmod(0600, path)
	end
	def self.terminate(pid)
		return if Process.waitpid(pid, Process::WNOHANG)
		Process.kill('TERM', -pid)
		deadline = now + 0.5
		while now < deadline
			return if Process.waitpid(pid, Process::WNOHANG)
			sleep 0.01
		end
		Process.kill('KILL', -pid)
		Process.waitpid(pid)
	rescue Errno::ESRCH, Errno::ECHILD
	end
	def self.run_bounded(command, log, timeout: 600, output: File::NULL)
		pid = Process.spawn(process_environment, *command, out: output, err: log, pgroup: true, unsetenv_others: true)
		deadline = now + timeout
		loop do
			if (result = Process.waitpid2(pid, Process::WNOHANG))
				return result[1].success?
			end
			raise "Command deadline: #{log}" if now >= deadline
			sleep 0.01
		end
	ensure
		terminate(pid) if pid
	end

	def self.memory_snapshot(target, prefix, phase)
		[['vmmap', ['-summary'], 'REGION TYPE'], ['heap', ['-s'], 'All zones:']].to_h do |tool, arguments, marker|
			path = "#{prefix}.#{phase}.#{tool}.txt"
			raise "Memory snapshot failed: #{phase}/#{tool}" unless run_bounded(["/usr/bin/#{tool}", *arguments, target.to_s], "#{path}.err", timeout: 10, output: path)
			raise "Incomplete memory snapshot: #{phase}/#{tool}" unless File.read(path).include?(marker)
			[tool, path]
		end
	end

	# Register before starting Instruments, so its start notification cannot be lost.
	class TraceNotification
		def initialize(name)
			require 'fiddle'
			library = Fiddle.dlopen(nil)
			register = Fiddle::Function.new(library['notify_register_check'], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
			@check = Fiddle::Function.new(library['notify_check'], [Fiddle::TYPE_INT, Fiddle::TYPE_VOIDP], Fiddle::TYPE_INT)
			@cancel = Fiddle::Function.new(library['notify_cancel'], [Fiddle::TYPE_INT], Fiddle::TYPE_INT)
			value = Fiddle::Pointer.malloc(4)
			raise 'Profiler notification registration failed' unless register.call(name, value) == 0
			@token = value[0, 4].unpack('i').first
			ready? # Discard the initial registration state.
		end
		def ready?
			value = Fiddle::Pointer.malloc(4)
			raise 'Profiler notification check failed' unless @check.call(@token, value) == 0
			value[0, 4].unpack('i').first != 0
		end
		def close
			@cancel.call(@token) if @token
			@token = nil
		end
	end

	class TimeProfiler
		attr_reader :pid
		def initialize(target, prefix, command: nil, notification: nil, filesystem: false, kind: nil)
			@prefix = prefix; @filesystem = filesystem
			@kind = kind || (filesystem ? 'file-activity' : 'time-profiler')
			name = "org.butter.profile.#{Process.pid}.#{target}"
			@notification = notification || TraceNotification.new(name)
			unless command
				template = {'time-profiler'=>'Time Profiler', 'file-activity'=>'File Activity', 'allocations'=>'Allocations', 'system-trace'=>'System Trace', 'concurrency'=>'Swift Concurrency'}.fetch(@kind)
				command = ['xcrun', 'xctrace', 'record', '--template', template]
				command += ['--instrument', 'Time Profiler', '--window', filesystem ? '1s' : '2s'] unless @kind == 'time-profiler'
				command += ['--attach', target.to_s, '--notify-tracing-started', name, '--time-limit', '600s', '--output', "#{prefix}.trace"]
			end
			@pid = Process.spawn(TransferBenchmarkHarness.process_environment, *command, out: "#{prefix}.profiler.log", err: [:child, :out], pgroup: true, unsetenv_others: true)
		rescue Exception
			@notification.close if @notification
			raise
		end
		def wait_ready(children, timeout: 30)
			deadline = TransferBenchmarkHarness.now + timeout
			loop do
				if (result = Process.waitpid2(@pid, Process::WNOHANG))
					@reaped = true
					raise "Profiler exited before ready: #{result[1]}"
				end
				readers = children.map(&:output).compact
				ready = IO.select(readers, nil, nil, 0.01)
				children.each { |child| child.read_available if ready && ready[0].include?(child.output) }
				return if @notification.ready?
				raise 'Profiler readiness deadline' if TransferBenchmarkHarness.now >= deadline
			end
		end
		def finish(timeout: 60)
			raise 'Profiler already exited' if @reaped
			Process.kill('INT', -@pid)
			deadline = TransferBenchmarkHarness.now + timeout
			loop do
				if (result = Process.waitpid2(@pid, Process::WNOHANG))
					@reaped = true
					raise "Profiler failed: #{result[1]}" unless result[1].success?
					return
				end
				raise 'Profiler finish deadline' if TransferBenchmarkHarness.now >= deadline
				sleep 0.02
			end
		end
		def export
			queries = [['toc', ['--toc']], ['samples', ['--xpath', '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]']]]
			queries << ['fs', ['--xpath', '/trace-toc/run[@number="1"]/data/table[@schema="FsSyscall"]']] if @filesystem
			queries.each do |suffix, query|
				command = ['xcrun', 'xctrace', 'export', '--input', "#{@prefix}.trace", *query, '--output', "#{@prefix}.#{suffix}.xml"]
				raise 'Profiler export failed' unless TransferBenchmarkHarness.run_bounded(command, "#{@prefix}.export.log", timeout: 60)
				TransferBenchmarkHarness.redact_profile_environment("#{@prefix}.toc.xml") if suffix == 'toc'
			end
			export_extra_tables if %w[allocations system-trace concurrency].include?(@kind)
		end
		def export_extra_tables
			require 'rexml/document'
			pattern = {'allocations'=>/alloc|heap|vm/i, 'system-trace'=>/thread|syscall|sched|cswitch|system-call/i, 'concurrency'=>/swift|task|actor|executor/i}.fetch(@kind)
			document = REXML::Document.new(File.read("#{@prefix}.toc.xml"))
			schemas = document.get_elements('//table').map { |table| table.attributes['schema'] }.compact.uniq.select { |name| name.match?(pattern) }
			manifest = schemas.map do |schema|
				suffix = schema.gsub(/[^a-zA-Z0-9_-]/, '_')
				path = "#{@prefix}.#{suffix}.xml"
				query = "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"#{schema}\"]"
				raise "Profiler table export failed: #{schema}" unless TransferBenchmarkHarness.run_bounded(['xcrun', 'xctrace', 'export', '--input', "#{@prefix}.trace", '--xpath', query, '--output', path], "#{path}.log", timeout: 60)
				{schema: schema, file: File.basename(path), bytes: File.size(path)}
			end
			File.write("#{@prefix}.tables.json", JSON.pretty_generate(manifest))
		end
		def cleanup
			TransferBenchmarkHarness.terminate(@pid) if @pid && !@reaped
			@notification.close
		end
	end

	# Classify each sample once by its executing leaf. Preserve full calling stacks
	# for attribution; worker ancestry alone does not identify scheduling overhead.
	def self.profile_category(frames)
		leaf = frames.first
		return 'kernel-facing copying' if frames.any? { |frame| frame == 'vm_copy' }
		case leaf
		when /\A(?:__)?(?:openat|open|close|fstatat|fstat|stat|lstat|dup|fcntl|fsync|rename|unlink|mkdir|faccessat)(?:\z|_)/ then 'filesystem metadata/open/close'
		when /\A(?:__)?(?:pread|pwrite|read|write)(?:\z|_)/ then 'payload I/O'
		when /\A(?:__)?(?:recvmsg|sendmsg|recvfrom|sendto|getsockopt|setsockopt|connect|accept|socket)(?:\z|_)/ then 'networking'
		when /mach_msg|kevent|workq_kernreturn|ulock|psynch|thread_switch/ then 'scheduling and event delivery'
		when /SHA\d|ccdigest|HashFunction/ then 'user hashing'
		when /memmove|memcpy|bzero/ then 'user copying/clearing'
		when /malloc|_free|swift_alloc|DataStorage.init/ then 'user allocation'
		when /start_wqthread|unavailable backtrace/ then 'unattributed'
		else 'other user processing or unresolved execution'
		end
	end
	def self.profile_summary(path, target)
		require 'rexml/document'
		document = REXML::Document.new(File.read(path))
		refs, rows = {}, []
		document.root.each_recursive do |element|
			refs[element.attributes['id']] = element if element.attributes['id']
			rows << element if element.name == 'row'
		end
		resolve = ->(element) { element && (element.attributes['ref'] ? refs.fetch(element.attributes['ref']) : element) }
		flat, inclusive, stacks, categories = Hash.new(0), Hash.new(0), Hash.new(0), Hash.new(0)
		count = 0; unavailable = 0
		rows.each do |row|
			process = resolve.call(row.elements['process'])
			next unless process && resolve.call(process.elements['pid']).text.to_i == target
			next unless resolve.call(row.elements['thread-state']).text == 'Running'
			weight = Integer(resolve.call(row.elements['weight']).text)
			raise 'Invalid profiler sample weight' unless weight > 0
			stack = resolve.call(row.elements['tagged-backtrace'])
			frames = stack ? stack.get_elements('frame').map { |frame| resolve.call(frame).attributes['name'] || '[unnamed frame]' } : []
			if frames.empty?
				unavailable += 1; frames = ['[unavailable backtrace]']
			end
			categories[profile_category(frames)] += weight
			stacks[frames] += weight
			flat[frames.first] += weight
			frames.uniq.each { |frame| inclusive[frame] += weight }
			count += 1
		end
		raise 'No running samples for profiler target' if count == 0
		total = flat.values.sum
		rank = ->(values) { values.sort_by { |name, weight| [-weight, name] }.first(100).map { |name, weight| { symbol: name, weight_ns: weight, percent: 100.0 * weight / total } } }
		{ target_pid: target, running_samples: count, unavailable_backtrace_samples: unavailable, weight_ns: total,
			method: 'Running samples for the tested process only; statistical sample weights, not measured CPU durations; inclusive symbols overlap',
			category_method: 'Disjoint executing-leaf symbol groups; kernel-facing syscall stacks, not a measurement of kernel residence. Inspect calling stacks for purpose. No inclusive sums; unresolved worker entry remains unattributed.',
			categories: rank.call(categories), flat: rank.call(flat), inclusive: rank.call(inclusive),
			stacks: stacks.sort_by { |frames, weight| [-weight, frames] }.map { |frames, weight| {frames: frames, weight_ns: weight, percent: 100.0 * weight / total} } }
	end

	class Child
		attr_reader :events, :pid, :log, :job_path, :whole
		def initialize(command, job_path, log, allocation_logging: false)
			@phases = JSON.parse(File.read(job_path))['partial'] ? %w[prepare ready start measurement-start measurement-end verified persistence durable shutdown stopped] : PHASES
			@job_path, @log, @events, @buffer = job_path, log, [], ''.b
			input, @control = IO.pipe
			@output, output = IO.pipe
			environment = TransferBenchmarkHarness.process_environment
			environment['MallocStackLogging'] = '1' if allocation_logging
			@pid = Process.spawn(environment, '/usr/bin/time', '-l', *command, '--benchmark', job_path,
				in: input, out: output, err: log, pgroup: true, unsetenv_others: true)
			input.close; output.close
		end
		def send_command(command, fields = {})
			bytes = JSON.generate(fields.merge(command: command)) + "\n"
			raise 'Oversized control command' if bytes.bytesize > 4096
			@control.write(bytes); @control.flush
		end
		def read_available
			loop do
				bytes = @output.read_nonblock(4096)
				@buffer << bytes
				raise 'Oversized phase event' if @buffer.bytesize > 262_144
				while (index = @buffer.index("\n"))
					line = @buffer.slice!(0, index + 1)
					event = JSON.parse(line)
					raise "Unexpected phase #{event['phase']}" unless event['phase'] == @phases[@events.length]
					%w[time user system peak_rss].each { |key| raise "Invalid accounting #{key}" unless event[key].is_a?(Numeric) && event[key].finite? && event[key] >= 0 }
					if (previous = @events.last)
						%w[time user system peak_rss].each { |key| raise "Regressing accounting #{key}" if event[key] < previous[key] }
					end
					@events << event
				end
			end
		rescue IO::WaitReadable
		rescue EOFError
			@eof = true
			raise "Child exited before stopped: #{@log}" unless phase('stopped') && @buffer.empty?
		end
		def output
			@eof ? nil : @output
		end
		def phase(name)
			@events.find { |event| event['phase'] == name }
		end
		def finish(deadline: 10)
			finish_by = TransferBenchmarkHarness.now + deadline
			loop do
				if (result = Process.waitpid2(@pid, Process::WNOHANG))
					@reaped = true
					unless result[1].success?
						tail = File.binread(@log, 4096, [File.size(@log) - 4096, 0].max).force_encoding(Encoding::UTF_8).scrub
						raise "Child failed (#{result[1]}): #{@log}\n#{tail}"
					end
					break
				end
				raise "Child shutdown deadline: #{@log}" if TransferBenchmarkHarness.now >= finish_by
				sleep 0.01
			end
			text = File.read(@log)
			match = text.match(/([\d.]+) real\s+([\d.]+) user\s+([\d.]+) sys/)
			rss = text.match(/(\d+)\s+maximum resident set size/)
			raise "Missing whole-process accounting: #{@log}" unless match && rss
			@whole = { wall: match[1].to_f, user: match[2].to_f, system: match[3].to_f, peak_rss: rss[1].to_i }
		end
		def cleanup
			TransferBenchmarkHarness.terminate(@pid) unless @reaped
			@control.close unless @control.closed?
			@output.close unless @output.closed?
		end
		def diagnose
			event = phase('ready')
			Process.kill('USR1', event['pid']) if event && !event.key?('libtorrent')
		rescue Errno::ESRCH
		end
	end

	# Monitor every child, including the counterpart, during every phase deadline.
	def self.wait(children, targets, timeout: 600)
		deadline = now + timeout
		until targets.all? { |child, phase| child.phase(phase) }
			raise 'Benchmark phase deadline' if now >= deadline
			readers = children.map(&:output).compact
			raise 'All benchmark children closed' if readers.empty?
			ready = IO.select(readers, nil, nil, [deadline - now, 0.1].min)
			next unless ready
			children.each { |child| child.read_available if ready[0].include?(child.output) }
		end
	end

	def self.delta(first, last)
		{ wall: last.fetch('time') - first.fetch('time'), user: last.fetch('user') - first.fetch('user'), system: last.fetch('system') - first.fetch('system') }
	end
	def self.metrics(child, bytes)
		raise 'Invalid payload byte count' unless bytes.is_a?(Integer) && bytes > 0
		raise 'Metadata payload byte count mismatch' unless child.phase('ready').fetch('payload_bytes') == bytes
		phases = { setup: %w[prepare ready], transfer: %w[start verified], persistence: %w[persistence durable], shutdown: %w[shutdown stopped], through_durable: %w[start durable] }
		values = phases.transform_values { |a, b| delta(child.phase(a), child.phase(b)) }
		transfer, durable = values.fetch(:transfer), values.fetch(:through_durable)
		raise 'Zero transfer duration' unless transfer[:wall] > 0 && durable[:wall] >= transfer[:wall]
		values.merge(user_cpu_seconds: durable[:user], system_cpu_seconds: durable[:system], cpu_seconds: durable[:user] + durable[:system],
			user_cpu_percent: 100 * durable[:user] / durable[:wall], system_cpu_percent: 100 * durable[:system] / durable[:wall], cpu_percent: 100 * (durable[:user] + durable[:system]) / durable[:wall],
			user_cpu_seconds_per_gib: durable[:user] / (bytes.to_f / 1_073_741_824), system_cpu_seconds_per_gib: durable[:system] / (bytes.to_f / 1_073_741_824),
			verified_bytes_per_second: bytes / transfer[:wall], durable_bytes_per_second: bytes / durable[:wall],
			verified_cpu_seconds_per_gib: (transfer[:user] + transfer[:system]) / (bytes.to_f / 1_073_741_824),
			cpu_seconds_per_gib: (durable[:user] + durable[:system]) / (bytes.to_f / 1_073_741_824),
			peer_errors: child.phase('stopped').fetch('peer_errors', []), whole: child.whole)
	end
	def self.orders(count, seed, labels: %w[Swift libtorrent])
		raise 'Pair count must be positive and even' unless count > 0 && count.even?
		raise 'Two distinct order labels required' unless labels.size == 2 && labels.uniq.size == 2
		(Array.new(count / 2) { labels.dup } + Array.new(count / 2) { labels.reverse }).shuffle(random: Random.new(seed))
	end
	def self.median(values)
		sorted = values.sort; n = sorted.length
		raise 'No observations' if n == 0
		n.odd? ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
	end
	def self.interval(values, seed: 11011)
		random = Random.new(seed)
		samples = Array.new(10_000) { median(Array.new(values.length) { values[random.rand(values.length)] }) }.sort
		{ median: median(values), lower: samples[249], upper: samples[9749], method: 'paired median percentile bootstrap, 10000 resamples, 95%' }
	end
	def self.summary(trials)
		measured = trials.reject { |trial| trial[:warmup] }
		pairs = measured.group_by { |trial| trial[:pair] }.values
		valid = pairs.select { |pair| pair.map { |trial| trial[:engine].to_s }.sort == %w[Swift libtorrent].sort && pair.all? { |trial| trial[:accepted] } }
		return { status: 'failed', pairs: pairs.length, valid_pairs: valid.length } if valid.length != pairs.length || valid.empty?
		ratios = %i[verified_bytes_per_second durable_bytes_per_second cpu_seconds_per_gib].to_h do |key|
			values = valid.map do |pair|
				swift = pair.find { |trial| trial[:engine] == 'Swift' }[:engine_metrics][key]
				other = pair.find { |trial| trial[:engine] == 'libtorrent' }[:engine_metrics][key]
				raise 'Zero reference measurement' unless other > 0
				swift / other
			end
			[key, interval(values)]
		end
		throughput, cpu = ratios[:verified_bytes_per_second], ratios[:cpu_seconds_per_gib]
		crosses = (throughput[:lower] < 0.9 && throughput[:upper] >= 0.9) || (cpu[:lower] <= 1.25 && cpu[:upper] > 1.25)
		failed_target = throughput[:upper] < 0.9 || cpu[:lower] > 1.25
		status = failed_target ? 'target-unmet' : crosses ? 'inconclusive' : 'throughput-and-cpu-pass'
		medians = %w[Swift libtorrent].to_h do |engine|
			records = measured.select { |trial| trial[:engine] == engine }
			[engine, %i[verified_bytes_per_second durable_bytes_per_second cpu_seconds_per_gib].to_h { |key| [key, median(records.map { |trial| trial[:engine_metrics][key] })] }]
		end
		{ status: status, requires_more_pairs: crosses, pairs: pairs.length, ratios: ratios, medians: medians, memory: 'Compare whole-process Swift peak RSS with the fresh baseline; no memory acceptance inferred.' }
	end
	def self.memory_summary(trials, baseline)
		sets = [trials, baseline].map { |set| set.select { |trial| !trial[:warmup] && trial[:engine] == 'Swift' } }
		return { status: 'failed', reason: 'Missing or failed baseline/candidate trials' } if sets.any? { |set| set.empty? || set.any? { |trial| !trial[:accepted] } }
		candidate, original = sets.map { |set| set.map { |trial| trial[:engine_metrics][:whole][:peak_rss] } }
		random = Random.new(11011)
		values = Array.new(10_000) do
			median(Array.new(candidate.size) { candidate[random.rand(candidate.size)] }) / median(Array.new(original.size) { original[random.rand(original.size)] }).to_f
		end.sort
		maximum_ratio = candidate.max.to_f / original.max
		status = values[249] <= 1.1 && values[9749] > 1.1 ? 'inconclusive' : values[9749] <= 1.1 && maximum_ratio <= 1.1 ? 'pass' : 'target-unmet'
		{ status: status, median_peak_rss_ratio: median(candidate) / median(original).to_f, lower: values[249], upper: values[9749], maximum_peak_rss_ratio: maximum_ratio, method: 'independent median percentile bootstrap, 10000 resamples, 95%; also require observed maximum ratio <= 1.10' }
	end
	def self.source_summary(trials)
		variants = %w[previous current].to_h { |source| [source, summary(trials.select { |r| r[:source_variant] == source })] }
		pairs = trials.reject { |r| r[:warmup] }.group_by { |r| r[:pair] }.values
		expected = %w[previous current].product(%w[Swift libtorrent]).sort
		valid = pairs.select { |p| p.all? { |r| r[:accepted] } && p.map { |r| [r[:source_variant].to_s, r[:engine].to_s] }.sort == expected }
		return { status: 'failed', pairs: pairs.size, valid_pairs: valid.size, variants: variants } if valid.empty? || valid.size != pairs.size || trials.any? { |r| !r[:accepted] }
		paired = ->(engine, path) do
			interval(valid.map do |pair|
				previous, current = %w[previous current].map { |source| pair.find { |r| r[:source_variant] == source && r[:engine] == engine }.dig(*path) }
				raise 'Invalid source comparison measurement' unless previous.is_a?(Numeric) && current.is_a?(Numeric) && previous.finite? && current.finite? && previous > 0 && current > 0
				current.to_f / previous
			end)
		end
		specs = { cpu_seconds_per_gib: [:engine_metrics, :cpu_seconds_per_gib], verified_bytes_per_second: [:engine_metrics, :verified_bytes_per_second], peak_rss: [:engine_metrics, :whole, :peak_rss], counterpart_cpu_seconds_per_gib: [:counterpart_metrics, :cpu_seconds_per_gib] }
		{ status: 'source-comparison-only', pairs: pairs.size, valid_pairs: valid.size, variants: variants,
			source_ratios: specs.transform_values { |path| paired.call('Swift', path) },
			native_control_ratios: %i[cpu_seconds_per_gib verified_bytes_per_second].to_h { |key| [key, paired.call('libtorrent', [:engine_metrics, key])] },
			method: 'Current/previous within balanced source-order pairs; fixed six pairs; diagnostic only, no acceptance inference or uncertainty-driven retries' }
	end

	class Runner
		def initialize(swift, reference, output, work, smoke: false, profile: false, previous: nil, baseline: ENV['BUTTER_BENCHMARK_BASELINE'])
			@commands = { 'Swift' => [swift], 'libtorrent' => [reference] }
			@source_commands = { 'current' => [swift] }; @source_commands['previous'] = [previous] if previous
			@source_comparison = !previous.nil?
			raise 'Source comparison cannot use smoke' if @source_comparison && smoke
			@output, @work, @smoke, @profile = output, work, smoke, profile
			@profiler = ENV.fetch('BUTTER_BENCHMARK_PROFILER', 'sample')
			raise 'Unknown benchmark profiler' unless %w[sample counts time-profiler file-activity heap allocations system-trace concurrency].include?(@profiler)
			raise 'Instrumented profiling requires --profile' if !profile && @profiler != 'sample'
			@trials = []
			if baseline
				raise 'A representative full baseline is required' unless JSON.parse(File.read(File.join(baseline, 'environment.json')))['mode'] == '--full'
				raise 'Baseline fixture hashes differ' unless JSON.parse(File.read(File.join(baseline, 'fixtures.json'))) == JSON.parse(File.read(File.join(work, 'fixtures', 'manifest.json')))
				@baseline = File.readlines(File.join(baseline, 'trials.jsonl')).map { |line| JSON.parse(line, symbolize_names: true) }
			end
		end
		def command_for(engine, source)
			engine == 'Swift' && source ? @source_commands.fetch(source) : @commands.fetch(engine)
		end
		def trial(fixture, format, direction, engine, pair, warmup, source: nil)
			id = [source, fixture['case'], format, direction, pair, engine, warmup ? 'warmup' : 'measured'].compact.join('-')
			folder = File.join(@work, id); FileUtils.mkdir_p(folder)
			log_dir = File.join(@output, id); FileUtils.mkdir_p(log_dir)
			root = File.join(@work, 'fixtures', fixture['case'])
			items = fixture['torrents'][format].each_with_index.map do |torrent, index|
				{ torrent: File.join(root, torrent), destination: File.join(folder, "download-#{index}"), state: File.join(folder, "download-state-#{index}") }
			end
			seed_items = items.each_with_index.map { |item, index| item.merge(destination: File.join(root, 'seed'), state: File.join(folder, "seed-state-#{index}")) }
			jobs = { 'seed' => { role: 'seed', items: seed_items }, 'download' => { role: 'download', items: items } }
			if (inspector = ENV['BUTTER_BENCHMARK_APPLICATION_INSPECTOR'])
				jobs.each_value { |job| job[:applicationInspector] = inspector == 'visible' }
			end
			record = { id: id, case: fixture['case'], format: format, direction: direction, engine: engine, pair: pair, warmup: warmup, bytes: fixture['bytes'], accepted: false }
			record[:application_inspector] = inspector if inspector
			record[:source_variant] = source if source
			children = []; profilers = []; trace = nil
			begin
				# Explicitly warm every source with an independent streaming digest, outside timing.
				raise 'Fixture payload byte count mismatch' unless fixture['files'].sum { |file| file.fetch('size') } == fixture['bytes']
				raise 'Duplicate fixture payload path' unless fixture['files'].map { |file| file.fetch('path') }.uniq.size == fixture['files'].size
				fixture['files'].each do |file|
					path = File.join(root, 'seed', file['path'])
					raise "Source size changed: #{file['path']}" unless File.size(path) == file['size']
					raise "Source digest changed: #{file['path']}" unless Digest::SHA256.file(path).hexdigest == file['sha256']
				end
				roles = {}
				jobs.each do |role, job|
					job_path = File.join(folder, "#{role}.json"); File.write(job_path, JSON.generate(job))
					selected = (direction == 'download' ? role == 'download' : role == 'seed') ? engine : 'libtorrent'
					tested_role = direction == 'download' ? role == 'download' : role == 'seed'
					roles[role] = Child.new(command_for(selected, source), job_path, File.join(log_dir, "#{role}.log"), allocation_logging: @profile && @profiler == 'allocations' && tested_role); children << roles[role]
				end
				seed, down = roles.values_at('seed', 'download')
				timeout = @smoke ? 30 : 600
				TransferBenchmarkHarness.wait(children, children.map { |child| [child, 'ready'] }, timeout: timeout)
				raise 'Metadata payload byte count mismatch' unless children.all? { |child| child.phase('ready').fetch('payload_bytes') == fixture['bytes'] }
				if @profile && @profiler != 'sample'
					tested = direction == 'download' ? down : seed
					if @profiler == 'counts'
						record[:profiler] = { name: 'Operation counters', sampling: false, timing_acceptance: false }
					elsif @profiler == 'heap'
						record[:profiler] = { name: 'Heap and VM snapshots', target: engine, target_pid: tested.phase('ready').fetch('pid'), counterpart_instrumented: false,
							method: 'Ready, verified and durable gate snapshots; intrusive diagnostics, not peak RSS, allocation churn or timing acceptance', snapshots: {} }
						record[:profiler][:snapshots][:ready] = TransferBenchmarkHarness.memory_snapshot(tested.phase('ready').fetch('pid'), File.join(@output, id), 'ready')
					else
						trace = TimeProfiler.new(tested.phase('ready').fetch('pid'), File.join(@output, id), filesystem: @profiler == 'file-activity', kind: @profiler)
						trace.wait_ready(children)
						record[:profiler] = { name: @profiler, target: engine, attached_before_start: true, counterpart_instrumented: false, capture_window: @profiler == 'time-profiler' ? 'whole transfer through durable completion' : @profiler == 'file-activity' ? 'requested trailing 1s before durable completion' : 'requested trailing 2s before durable completion; intrusive diagnostic, not timing acceptance' }
						record[:profiler][:allocation_logging] = 'MallocStackLogging=1 from target process launch' if @profiler == 'allocations'
					end
				end
				seed.send_command('start'); down.send_command('start', ports: seed.phase('ready').fetch('ports'))
				if @profile && @profiler == 'sample'
					TransferBenchmarkHarness.wait(children, children.map { |child| [child, 'start'] }, timeout: timeout)
					roles.each do |role, child|
						path = File.join(@output, "#{id}-#{role}.sample.txt")
						profilers << Process.spawn(TransferBenchmarkHarness.process_environment, '/usr/bin/sample', child.phase('start').fetch('pid').to_s, '2', '-file', path, out: File::NULL, err: File.join(log_dir, "#{role}-profile.log"), pgroup: true, unsetenv_others: true)
					end
				end
				TransferBenchmarkHarness.wait(children, [[down, 'verified']], timeout: timeout)
				seed.send_command('verified')
				TransferBenchmarkHarness.wait(children, [[seed, 'verified']], timeout: timeout)
				if @profile && @profiler == 'heap'
					record[:profiler][:snapshots][:verified] = TransferBenchmarkHarness.memory_snapshot(tested.phase('ready').fetch('pid'), File.join(@output, id), 'verified')
				end
				children.each { |child| child.send_command('persist') }
				TransferBenchmarkHarness.wait(children, children.map { |child| [child, 'durable'] }, timeout: timeout)
				if @profile && @profiler == 'heap'
					record[:profiler][:snapshots][:durable] = TransferBenchmarkHarness.memory_snapshot(tested.phase('ready').fetch('pid'), File.join(@output, id), 'durable')
				end
				trace.finish if trace
				children.each { |child| child.send_command('stop') }
				TransferBenchmarkHarness.wait(children, children.map { |child| [child, 'stopped'] }, timeout: timeout)
				children.each(&:finish)
				if trace
					trace.export
					prefix = File.join(@output, id)
					summary = TransferBenchmarkHarness.profile_summary("#{prefix}.samples.xml", tested.phase('ready').fetch('pid'))
					File.write("#{prefix}.cpu.json", JSON.pretty_generate(summary))
				end
				# Measurements have ended. Check each file independently, then reopen native recovery state.
				fixture['files'].each do |file|
					index = fixture['case'] == 'concurrent' ? file['path'][/payload-(\d+)/, 1].to_i : 0
					path = File.join(items[index][:destination], file['path'])
					raise "Payload size/digest mismatch: #{file['path']}" unless File.size(path) == file['size'] && Digest::SHA256.file(path).hexdigest == file['sha256']
				end
				jobs.each_key do |role|
					selected = (direction == 'download' ? role == 'download' : role == 'seed') ? engine : 'libtorrent'
					raise "Reopen failed: #{role}" unless TransferBenchmarkHarness.run_bounded([*command_for(selected, source), '--verify', roles[role].job_path], File.join(log_dir, "#{role}-reopen.log"), timeout: timeout)
				end
				tested, counterpart = direction == 'download' ? [down, seed] : [seed, down]
				record[:engine_metrics] = TransferBenchmarkHarness.metrics(tested, fixture['bytes'])
				record[:counterpart_metrics] = TransferBenchmarkHarness.metrics(counterpart, fixture['bytes'])
				record[:accepted] = true
				profilers.each { |pid| raise 'Profiler failed' unless Process.waitpid2(pid)[1].success? }
			rescue Interrupt => error
				record[:error] = error.message; raise
			rescue StandardError => error
				record[:accepted] = false
				record[:error] = "#{error.class}: #{error.message}"
				children.each(&:diagnose); sleep 0.05
				record[:failure_files] = Dir.glob(File.join(folder, '**', '*')).select { |path| File.file?(path) }.map { |path| { path: path.delete_prefix(folder + '/'), bytes: File.size(path) } }
			ensure
				children.each(&:cleanup)
				trace.cleanup if trace
				profilers.each { |pid| TransferBenchmarkHarness.terminate(pid) }
				record[:events] = jobs.keys.zip(children.map(&:events)).to_h
				File.open(File.join(@output, 'trials.jsonl'), 'a') { |file| file.puts(JSON.generate(record)) }
				@trials << record
				FileUtils.rm_rf(folder)
				FileUtils.rm_rf(log_dir) if record[:accepted]
			end
			puts "#{id}: #{record[:accepted] ? 'verified' : record[:error]}"; $stdout.flush
		end
		def source_case(fixture, format, direction, seed)
			%w[previous current].each { |source| %w[Swift libtorrent].each { |engine| trial(fixture, format, direction, engine, -1, true, source: source) } }
			engines = TransferBenchmarkHarness.orders(6, seed)
			TransferBenchmarkHarness.orders(6, seed + 2000, labels: %w[previous current]).each_with_index do |sources, pair|
				sources.each { |source| engines[pair].each { |engine| trial(fixture, format, direction, engine, pair, false, source: source) } }
			end
			selected = @trials.select { |r| r.values_at(:case, :format, :direction) == [fixture['case'], format, direction] }
			result = TransferBenchmarkHarness.source_summary(selected)
			if @baseline
				baseline = @baseline.select { |r| r.values_at(:case, :format, :direction) == [fixture['case'], format, direction] }
				result[:baseline_memory] = %w[previous current].to_h { |source| [source, TransferBenchmarkHarness.memory_summary(selected.select { |r| r[:source_variant] == source }, baseline)] }
			end
			result
		end
		def profile_source_case(fixture, format, direction, seed)
			order = %w[previous current].shuffle(random: Random.new(seed))
			order.each { |source| %w[Swift libtorrent].each { |engine| trial(fixture, format, direction, engine, 0, false, source: source) } }
			rows = @trials.select { |r| r.values_at(:case, :format, :direction) == [fixture['case'], format, direction] }
			{ status: rows.size == 4 && rows.all? { |r| r[:accepted] } ? 'profile-source-only' : 'failed', profiled: true, source_order: order,
				method: 'One diagnostic capture per engine/source; no acceptance or source-ratio inference' }
		end
		def run(fixtures)
			Signal.trap('TERM') { raise Interrupt, 'Benchmark terminated' }
			results = []
			fixtures.each_with_index do |fixture, index|
				next if ENV['BUTTER_BENCHMARK_CASE'] && ENV['BUTTER_BENCHMARK_CASE'] != fixture['case']
				%w[v1 v2 hybrid].each_with_index do |format, format_index|
					next if ENV['BUTTER_BENCHMARK_FORMAT'] && ENV['BUTTER_BENCHMARK_FORMAT'] != format
					%w[download seed].each_with_index do |direction, direction_index|
						next if ENV['BUTTER_BENCHMARK_DIRECTION'] && ENV['BUTTER_BENCHMARK_DIRECTION'] != direction
						if @profile
							next unless TransferBenchmarkHarness.profile_case?(fixture['case'], format, direction)
						end
						seed = 11011 + index * 100 + format_index * 10 + direction_index
						key = { case: fixture['case'], format: format, direction: direction, order_seed: seed }
						if @source_comparison
							if @profile
								results << key.merge(profile_source_case(fixture, format, direction, seed))
								File.write(File.join(@output, 'summary.json'), JSON.pretty_generate(results)); next
							end
							next unless TransferBenchmarkHarness.selected_case?(fixture['case'], format, direction, SOURCE_CASES)
							results << key.merge(source_case(fixture, format, direction, seed))
							File.write(File.join(@output, 'summary.json'), JSON.pretty_generate(results)); next
						end
						%w[Swift libtorrent].each { |engine| trial(fixture, format, direction, engine, -1, true) } unless @profile
						orders = @smoke || @profile ? [%w[Swift libtorrent]] : TransferBenchmarkHarness.orders(6, seed)
						orders.each_with_index { |order, pair| order.each { |engine| trial(fixture, format, direction, engine, pair, false) } }
						select = -> { @trials.select { |trial| trial[:case] == fixture['case'] && trial[:format] == format && trial[:direction] == direction } }
						result = TransferBenchmarkHarness.summary(select.call)
						baseline = @baseline&.select { |trial| trial[:case] == fixture['case'] && trial[:format] == format && trial[:direction] == direction }
						result[:memory] = TransferBenchmarkHarness.memory_summary(select.call, baseline) if baseline
						if !@smoke && !@profile && (result[:requires_more_pairs] || (baseline && result[:memory][:status] == 'inconclusive'))
							TransferBenchmarkHarness.orders(6, seed + 1000).each_with_index { |order, pair| order.each { |engine| trial(fixture, format, direction, engine, pair + 6, false) } }
							result = TransferBenchmarkHarness.summary(select.call)
							result[:memory] = TransferBenchmarkHarness.memory_summary(select.call, baseline) if baseline
						end
						if baseline
							memory_status = result[:memory][:status]
							if memory_status == 'failed' || memory_status == 'target-unmet' || result[:status] == 'target-unmet'
								result[:status] = memory_status == 'failed' ? 'failed' : 'target-unmet'
							elsif result[:status] == 'throughput-and-cpu-pass'
								result[:status] = memory_status == 'pass' ? 'target-met' : 'inconclusive'
							end
						end
						result[:status] = @profile ? 'profile-only' : 'smoke-only' if @profile || @smoke
						results << key.merge(result).merge(smoke: @smoke, profiled: @profile)
						File.write(File.join(@output, 'summary.json'), JSON.pretty_generate(results))
					end
				end
			end
			raise 'Benchmark contains failed trials; see raw results' if @trials.any? { |trial| !trial[:accepted] }
			raise 'No benchmark cases selected' if results.empty?
		end
	end
end

if $PROGRAM_NAME == __FILE__
	swift, reference, output, work, mode, previous = ARGV
	raise 'Previous source driver required' if %w[--compare-source --profile-source].include?(mode) && previous.nil?
	FileUtils.mkdir_p(output)
	manifest = JSON.parse(File.read(File.join(work, 'fixtures', 'manifest.json')))
	FileUtils.cp(File.join(work, 'fixtures', 'manifest.json'), File.join(output, 'fixtures.json'))
	TransferBenchmarkHarness::Runner.new(swift, reference, output, work, smoke: mode == '--smoke', profile: %w[--profile --profile-source].include?(mode), previous: %w[--compare-source --profile-source].include?(mode) ? previous : nil).run(manifest)
end
