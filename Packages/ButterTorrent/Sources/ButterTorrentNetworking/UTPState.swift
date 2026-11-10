import Foundation

struct UTPFlight: Sendable {
	let sequence: UInt16
	let type: UTPPacketType
	let payload: Data
	var sent: TimeInterval
	var transmissions = 1
	var fast: TimeInterval = -.infinity
}

// All sequence and buffer mutations occur before the transport suspends for I/O.
struct UTPState: Sendable {
	enum Phase: Sendable { case connecting, connected }
	let receiveID: UInt16
	let sendID: UInt16
	let synSequence: UInt16
	let initialSequence: UInt16
	let outgoing: Bool
	var phase: Phase
	var next: UInt16
	var acknowledged: UInt16
	var received: UInt16
	var remoteWindow = 262_144
	var replyDelay: UInt32 = 0
	var flights: [UTPFlight] = []
	var reordered: [UInt16: UTPPacket] = [:]
	var ready = Data()
	var remoteFin: UInt16?
	var localFin: UInt16?
	var finAcknowledged = false
	var congestion = UTPCongestion()
	var needsACK = false
	var duplicateACKs = 0
	var fastResend = false
	var lastProbe: TimeInterval = -.infinity
	var lastActivity: TimeInterval
	var retransmissions = 0
	init(outgoing: Bool, id: UInt16, sequence: UInt16, syn: UTPPacket? = nil, now: TimeInterval) {
		self.outgoing = outgoing; phase = outgoing ? .connecting : .connected
		receiveID = outgoing ? id : id &+ 1; sendID = outgoing ? id &+ 1 : id
		synSequence = outgoing ? sequence : syn!.sequence; initialSequence = sequence
		next = outgoing ? sequence &+ 1 : sequence; acknowledged = sequence &- 1
		received = outgoing ? 0 : syn!.sequence; lastActivity = now
		if outgoing { flights = [UTPFlight(sequence: sequence, type: .syn, payload: Data(), sent: now)] }
		else { remoteWindow = Int(syn!.window); replyDelay = utpTimestamp(now) &- syn!.timestamp; needsACK = true }
	}
	var buffered: Int { ready.count + reordered.values.reduce(0) { $0 + $1.payload.count } }
	var inFlight: Int { flights.reduce(0) { $0 + $1.payload.count } }
	var eof: Bool { remoteFin == received && remoteFin != nil && ready.isEmpty }
	var writeFinished: Bool { localFin != nil }
	func packet(_ type: UTPPacketType, sequence: UInt16, window: Int, now: TimeInterval, payload: Data = Data()) -> UTPPacket {
		var selective = Data(repeating: 0, count: 16)
		for key in reordered.keys {
			let delta = utpDistance(key, received)
			if (2...129).contains(delta) { let bit = delta - 2; selective[bit / 8] |= 1 << (bit % 8) }
		}
		if selective.allSatisfy({ $0 == 0 }) { selective = Data() }
		return UTPPacket(type: type, connection: type == .syn ? receiveID : sendID, timestamp: utpTimestamp(now), difference: replyDelay,
			window: UInt32(max(0, window)), sequence: sequence, acknowledgement: received, selective: selective, payload: payload)
	}
	mutating func initial(window: Int, now: TimeInterval) -> UTPPacket {
		needsACK = false
		return packet(outgoing ? .syn : .state, sequence: initialSequence, window: window, now: now)
	}
	mutating func receive(_ incoming: UTPPacket, capacity: Int, now: TimeInterval) throws {
		guard incoming.type != .syn else { return }
		if phase == .connecting {
			guard incoming.acknowledgement == synSequence, incoming.type == .state || incoming.type == .data || incoming.type == .reset else { return }
			if incoming.type == .reset { throw NetworkFailure.closed }
			phase = .connected; received = incoming.sequence &- 1
		}
		let ack = incoming.acknowledgement, last = next &- 1
		let validACK = !utpBefore(ack, acknowledged) && utpDistance(ack, acknowledged) <= utpDistance(last, acknowledged)
		if incoming.type == .reset { if validACK { throw NetworkFailure.closed }; return }
		lastActivity = now; replyDelay = utpTimestamp(now) &- incoming.timestamp; remoteWindow = Int(incoming.window)
		if validACK {
			var removed: [UTPFlight] = []
			flights.removeAll { flight in
				let distance = utpDistance(flight.sequence, ack)
				let bit = distance - 2
				let selective = bit >= 0 && bit < incoming.selective.count * 8 && incoming.selective[bit / 8] & (1 << (bit % 8)) != 0
				if !utpBefore(ack, flight.sequence) || selective { removed.append(flight); return true }; return false
			}
			let bytes = removed.reduce(0) { $0 + $1.payload.count }
			for flight in removed {
				if flight.transmissions == 1 { congestion.sampleRTT(now - flight.sent) }
				if flight.type == .fin { finAcknowledged = true }
			}
			if ack == acknowledged && bytes == 0 && !flights.isEmpty { duplicateACKs += 1 } else { duplicateACKs = 0 }
			acknowledged = ack
			congestion.acknowledged(bytes: bytes, delay: incoming.difference, now: now)
			if let missing = flights.first {
				let later = (0..<incoming.selective.count * 8).filter { bit in incoming.selective[bit / 8] & (1 << (bit % 8)) != 0 && utpBefore(missing.sequence, ack &+ UInt16(bit + 2)) }.count
				if duplicateACKs >= 3 || later >= 3 { fastResend = true }
			}
		}
		guard incoming.type == .data || incoming.type == .fin else {
			// An old sequence in a STATE packet is a persist probe; ordinary ACKs use the next sequence.
			if incoming.type == .state, incoming.sequence == received { needsACK = true }; return
		}
		needsACK = true
		let delta = utpDistance(incoming.sequence, received)
		guard (1...128).contains(delta), reordered[incoming.sequence] == nil,
			incoming.payload.count <= capacity, reordered.count < 128 else { return }
		if let fin = remoteFin, utpBefore(fin, incoming.sequence) { return }
		if incoming.type == .fin {
			guard remoteFin == nil || remoteFin == incoming.sequence else { throw NetworkFailure.invalid("µTP conflicting FIN") }
			guard !reordered.keys.contains(where: { utpBefore(incoming.sequence, $0) }) else { throw NetworkFailure.invalid("µTP data after FIN") }
			remoteFin = incoming.sequence
		}
		reordered[incoming.sequence] = incoming
		while let contiguous = reordered.removeValue(forKey: received &+ 1) {
			received &+= 1
			if contiguous.type == .fin { break }; ready.append(contiguous.payload)
		}
	}
	mutating func send(_ bytes: Data, offset: inout Int, window: Int, now: TimeInterval) -> [UTPPacket] {
		guard phase == .connected, localFin == nil else { return [] }
		var packets: [UTPPacket] = []
		while offset < bytes.count && flights.count < 256 && packets.count < 32 && utpDistance(next, acknowledged) < 16_384 {
			let allowance = min(remoteWindow, Int(congestion.window)) - inFlight
			let count = min(congestion.packetSize, allowance, bytes.count - offset)
			guard count > 0 else { break }
			let payload = bytes.subdata(in: offset..<offset + count), sequence = next; next &+= 1; offset += count
			flights.append(UTPFlight(sequence: sequence, type: .data, payload: payload, sent: now))
			packets.append(packet(.data, sequence: sequence, window: window, now: now, payload: payload)); needsACK = false
		}; return packets
	}
	mutating func finish(window: Int, now: TimeInterval) -> UTPPacket? {
		guard phase == .connected, localFin == nil, flights.isEmpty else { return nil }
		let sequence = next; next &+= 1; localFin = sequence
		flights.append(UTPFlight(sequence: sequence, type: .fin, payload: Data(), sent: now))
		return packet(.fin, sequence: sequence, window: window, now: now)
	}
	mutating func poll(window: Int, pendingWrite: Bool, now: TimeInterval) throws -> [UTPPacket] {
		var result: [UTPPacket] = []
		if let first = flights.first {
			let timedOut = now - first.sent >= congestion.retransmitAfter
			if timedOut || (fastResend && now - first.fast >= max(0.1, congestion.rtt ?? 0.1)) {
				guard first.transmissions < 6 else { throw NetworkFailure.timedOut }
				congestion.lost(now: now, timedOut: timedOut); flights[0].sent = now; flights[0].transmissions += 1; flights[0].fast = now
				retransmissions += 1; duplicateACKs = 0
				result.append(packet(first.type, sequence: first.sequence, window: window, now: now, payload: first.payload))
			}
		}
		fastResend = false
		if phase == .connected, pendingWrite, remoteWindow == 0, now - lastProbe >= 1 {
			lastProbe = now; result.append(packet(.state, sequence: next &- 1, window: window, now: now))
		}
		if needsACK { needsACK = false; result.append(packet(.state, sequence: next, window: window, now: now)) }
		return result
	}
}
