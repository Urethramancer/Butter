import Foundation

extension UTPTransport {
	func receive(_ datagram: NetworkDatagram) {
		guard !closed, !datagram.source.address.isUnspecified, !datagram.source.address.isMulticast, datagram.source.port > 0,
			let packet = try? UTPPacket(datagram.payload) else { droppedPackets += 1; return }
		let key = UTPKey(peer: datagram.source, connection: packet.type == .syn ? packet.connection &+ 1 : packet.connection)
		if let id = routes[key], let record = records[id] {
			if packet.type == .syn {
				guard !record.state.outgoing, packet.sequence == record.state.synSequence else { return }
				enqueue(record.state.packet(.state, sequence: record.state.initialSequence, window: window(record), now: clock.now()), to: record.endpoint, id: record.id)
				return
			}
			do { try record.state.receive(packet, capacity: window(record), now: clock.now()); drive(record) }
			catch { abort(id, error: error, reset: packet.type != .reset) }
			return
		}
		if let old = tombstones[key], old.expires > clock.now() {
			if packet.type == .fin { enqueue(old.packet, to: datagram.source) }; return
		}
		guard packet.type == .syn else { if packet.type != .reset { reject(packet, peer: datagram.source) }; return }
		guard records.count < maximumConnections, accepted.count < 32, let lease = budget.acquire() else { reject(packet, peer: datagram.source); return }
		let now = clock.now(), state = UTPState(outgoing: false, id: packet.connection, sequence: UInt16.random(in: 0...65535), syn: packet, now: now)
		let record = UTPRecord(endpoint: datagram.source, state: state, leases: [lease], now: now)
		records[record.id] = record; routes[key] = record.id
		enqueue(record.state.initial(window: window(record), now: now), to: record.endpoint, id: record.id)
		if let waiter = acceptor, waiter.isPending {
			acceptor = nil; record.claimed = true
			if !waiter.resolve(.success(stream(record))) { abort(record.id) }
		} else { accepted.append(record.id) }
	}
	func reject(_ packet: UTPPacket, peer: NetworkEndpoint) {
		let epoch = Int64(clock.now()); if epoch != resetEpoch { resetEpoch = epoch; resets = 0 }
		guard resets < 100 else { return }; resets += 1
		enqueue(UTPPacket(type: .reset, connection: packet.connection, timestamp: utpTimestamp(clock.now()), window: 0,
			sequence: packet.acknowledgement, acknowledgement: packet.sequence), to: peer)
	}
	func drive(_ record: UTPRecord) {
		guard !closed, records[record.id] === record else { return }
		let now = clock.now()
		if record.state.phase == .connected, let opened = record.opened {
			record.opened = nil; _ = opened.resolve(.success(stream(record)))
		}
		if let (maximum, waiter) = record.reader {
			if !record.state.ready.isEmpty {
				let bytes = Data(record.state.ready.prefix(maximum)); record.state.ready = Data(record.state.ready.dropFirst(bytes.count))
				record.reader = nil; waiter.resolve(.success(bytes)); record.state.needsACK = true
			} else if record.state.eof { record.reader = nil; waiter.resolve(.success(Data())) }
		}
		if record.state.eof { record.end.finish() }
		if var write = record.writer {
			let packets = record.state.send(write.bytes, offset: &write.offset, window: window(record), now: now)
			record.writer = write
			for packet in packets { enqueue(packet, to: record.endpoint, id: record.id) }
			if write.offset == write.bytes.count && record.state.flights.isEmpty {
				record.writer = nil; write.completion.resolve(.success(()))
			}
		}
		if let finishing = record.finishing {
			if record.writer == nil, let fin = record.state.finish(window: window(record), now: now) { enqueue(fin, to: record.endpoint, id: record.id) }
			if record.state.finAcknowledged { record.finishing = nil; finishing.resolve(.success(())) }
		}
		do { for packet in try record.state.poll(window: window(record), pendingWrite: record.writer != nil, now: now) { enqueue(packet, to: record.endpoint, id: record.id) } }
		catch { abort(record.id, error: error); return }
		if record.state.finAcknowledged && record.state.eof && record.completed == nil { record.completed = now; for lease in record.leases { lease.release() } }
	}
	func tick() {
		guard !closed else { return }; let now = clock.now()
		tombstones = tombstones.filter { $0.value.expires > now }
		for record in Array(records.values) {
			if (!record.claimed && now - record.created >= 10) || now - record.state.lastActivity >= 180 || record.completed.map({ now - $0 >= 5 }) == true {
				abort(record.id, error: NetworkFailure.timedOut, reset: record.completed == nil)
			} else { drive(record) }
		}
	}
}
