# Offline diagnostic model: metadata only; never part of timed transfers.
require 'json'

class ReceiveOrderSimulation
	TRANSFER_LIMIT = 256 * 1024
	SESSION_LIMIT = 1024 * 1024
	DEADLINE = 0.010
	CONTEXTS = 8
	def initialize(reorder:)
		@reorder = reorder
		@pending = []
		@pieces = {}
		@contexts = {}
		@bytes = 0
		@peak = 0
		@transfer_bytes = Hash.new(0)
		@flushes = Hash.new(0)
		@waits = []
		@last = nil
	end
	def emit(event, now, reason)
		time, owner, piece, offset, count, length = event
		key = [owner, piece]
		state = (@pieces[key] ||= {offset: 0, bytes: 0, length: length, valid: true})
		raise 'Changed piece length' unless state[:length] == length
		if !@contexts.key?(key) && state[:bytes] == 0 && offset == 0
			if @contexts.size == CONTEXTS
				evicted = @contexts.shift.first
				@pieces.fetch(evicted)[:valid] = false
			end
			@contexts[key] = true
		end
		state[:valid] &&= offset == state[:offset] && @contexts.key?(key)
		state[:offset] = offset + count
		state[:bytes] += count
		raise 'Overlapping accepted payload' if state[:bytes] > length
		@contexts.delete(key) if state[:bytes] == length
		@flushes[reason] += 1
		@waits << now - time
	end
	def flush(event, now, reason)
		@pending.delete(event)
		@bytes -= event[4]; @transfer_bytes[event[1]] -= event[4]
		emit(event, now, reason)
	end
	def contiguous(now)
		loop do
			event = @pending.find { |e| e[3] == (@pieces[[e[1], e[2]]]&.fetch(:offset) || 0) }
			break unless event
			flush(event, now, 'contiguous')
		end
	end
	def accept(event)
		time, owner, piece, offset, count, length = event
		raise 'Invalid trace event' unless time.finite? && (@last.nil? || time >= @last) && piece >= 0 && offset >= 0 && count > 0 && count <= 16384 && offset + count <= length
		@last = time
		unless @reorder
			emit(event, time, 'direct'); return
		end
		while @pending.first && @pending.first[0] + DEADLINE <= time
			deadline = @pending.first[0] + DEADLINE
			flush(@pending.first, deadline, 'deadline'); contiguous(deadline)
		end
		while @bytes + count > SESSION_LIMIT || @transfer_bytes[owner] + count > TRANSFER_LIMIT
			victim = @pending.find { |e| e[1] == owner } || @pending.first
			flush(victim, time, 'capacity'); contiguous(time)
		end
		@pending << event; @bytes += count; @transfer_bytes[owner] += count
		@peak = [@peak, @bytes].max
		contiguous(time)
	end
	def finish
		while @pending.first
			flush(@pending.first, @last, 'shutdown'); contiguous(@last)
		end
		complete = @pieces.values.select { |p| p[:bytes] == p[:length] }
		proofs = complete.select { |p| p[:valid] }
		sorted = @waits.sort
		{complete_pieces: complete.size, proof_pieces: proofs.size, proof_bytes: proofs.sum { |p| p[:length] },
			complete_bytes: complete.sum { |p| p[:length] }, peak_buffer_bytes: @peak, flush_blocks: @flushes,
			mean_wait_ms: 1000 * @waits.sum / [@waits.size, 1].max, p95_wait_ms: 1000 * (sorted[(sorted.size * 0.95).floor] || 0),
			maximum_wait_ms: 1000 * (sorted.last || 0)}
	end
end

if $PROGRAM_NAME == __FILE__
	models = {direct: ReceiveOrderSimulation.new(reorder: false), reordered: ReceiveOrderSimulation.new(reorder: true)}
	File.foreach(ARGV.fetch(0)) do |line|
		time, owner, piece, offset, count, length = line.split
		event = [Float(time), owner, Integer(piece), Integer(offset), Integer(count), Integer(length)]
		models.each_value { |model| model.accept(event) }
	end
	puts JSON.pretty_generate(models.transform_values(&:finish))
end
