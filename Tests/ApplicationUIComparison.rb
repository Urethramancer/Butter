require_relative 'TransferBenchmarkHarness'

h = TransferBenchmarkHarness
previous, current, out = ARGV
name = ENV.fetch('BUTTER_UI_PROFILE_CASE', 'many-files-download-visible')
workload, role, visibility = %w[many-files many-torrents].product(%w[download seed], %w[hidden visible]).find { |parts| parts.join('-') == name }
raise 'Unknown UI comparison case' unless workload
rows = []
smoke = ENV['BUTTER_UI_COMPARE_SMOKE'] == '1'
orders = smoke ? [%w[previous current]] : [%w[previous current current previous]] + h.orders(6, 51723, labels: %w[previous current]).map { |a, b| [a, b, b, a] }
orders.each_with_index do |order, block|
	order.each_with_index do |variant, slot|
		id = "#{name}-#{block}-#{slot}-#{variant}"
		prefix = File.join(out, id)
		job = {workload: workload, role: role, inspector: visibility == 'visible', screenshot: prefix + '.png'}
		job[:captureFinal] = true if smoke
		job_path = prefix + '.json'; File.write(job_path, JSON.generate(job))
		row = {id: id, block: block, slot: slot, warmup: block == 0, variant: variant, accepted: false}
		child = nil
		begin
			child = h::Child.new([variant == 'previous' ? previous : current], job_path, prefix + '.log')
			h.wait([child], [[child, 'ready']], timeout: 60)
			child.send_command('start'); h.wait([child], [[child, 'verified']], timeout: 120)
			child.send_command('persist'); h.wait([child], [[child, 'durable']], timeout: 30)
			child.send_command('stop'); h.wait([child], [[child, 'stopped']], timeout: 30); child.finish
			raise 'Missing rendered fixture' unless File.size(job[:screenshot]) > 0
			row[:metrics] = h.delta(child.phase('start'), child.phase('durable'))
			row[:metrics][:cpu] = row[:metrics][:user] + row[:metrics][:system]
			row[:initial_render_cpu] = child.phase('verified').fetch('initial_render_cpu_seconds')
			row[:update_cpu] = child.phase('verified').fetch('update_cpu_seconds')
			row[:first_file_frame] = child.phase('verified')['first_file_frame'] if smoke
			row[:whole] = child.whole; row[:accepted] = true
		rescue StandardError => error
			row[:error] = "#{error.class}: #{error.message}"
		ensure
			row[:events] = child.events if child; child.cleanup if child
			FileUtils.rm_f(job[:screenshot]) unless smoke || (block == 1 && slot < 2)
			File.open(File.join(out, 'trials.jsonl'), 'a') { |file| file.puts(JSON.generate(row)) }
			rows << row
			puts "#{id}: #{row[:accepted] ? row[:metrics][:cpu].round(4) : row[:error]}"; $stdout.flush
		end
		raise row[:error] unless row[:accepted]
	end
end
if smoke
	if visibility == 'visible'
		first, second = rows.map { |row| row.fetch(:first_file_frame) }
		raise 'File checkbox layout changed' unless first && second && first.zip(second).all? { |a, b| (a - b).abs <= 0.5 }
	end
	File.write(File.join(out, 'summary.json'), JSON.pretty_generate({case: name, status: 'functional-smoke-only', validated: rows.length, first_file_frames: rows.map { |row| row[:first_file_frame] }, timing_acceptance: false}) + "\n")
	exit
end
blocks = rows.reject { |row| row[:warmup] }.group_by { |row| row[:block] }.values
summary = {case: name, valid: rows.count { |row| row[:accepted] }, samples: rows.length,
	method: 'Current/previous inspector source; fixed four warm-ups and 24 measured samples in six balanced blocks; window creation and 12 one-second updates; model parity, screenshot and saved-state reopening required; synthetic models, no payload/network or transfer CPU claim'}
%i[cpu wall peak_rss].each do |metric|
	values = blocks.map do |block|
		current_value, previous_value = %w[current previous].map do |variant|
			h.median(block.select { |row| row[:variant] == variant }.map { |row| row[metric == :peak_rss ? :whole : :metrics].fetch(metric) })
		end
		current_value / previous_value.to_f
	end
	summary[metric] = h.interval(values)
end
summary[:maximum_rss_ratio] = rows.select { |row| !row[:warmup] && row[:variant] == 'current' }.map { |row| row[:whole][:peak_rss] }.max.to_f / rows.select { |row| !row[:warmup] && row[:variant] == 'previous' }.map { |row| row[:whole][:peak_rss] }.max
summary[:median_cpu] = %w[previous current].to_h { |variant| [variant, h.median(rows.select { |row| !row[:warmup] && row[:variant] == variant }.map { |row| row[:metrics][:cpu] })] }
%i[initial_render_cpu update_cpu].each do |metric|
	summary[metric] = %w[previous current].to_h { |variant| [variant, h.median(rows.select { |row| !row[:warmup] && row[:variant] == variant }.map { |row| row.fetch(metric) })] }
end
File.write(File.join(out, 'summary.json'), JSON.pretty_generate(summary) + "\n")
