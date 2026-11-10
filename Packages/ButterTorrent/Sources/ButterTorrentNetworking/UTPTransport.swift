import Foundation

struct UTPKey: Hashable { let peer: NetworkEndpoint; let connection: UInt16 }
struct UTPWrite { let bytes: Data; var offset = 0; let completion: NetworkWaiter<Void> }
final class UTPRecord {
	let id = UUID()
	let endpoint: NetworkEndpoint
	let leases: [TCPPeerLease]
	let end = UTPReadEnd()
	var state: UTPState
	let created: TimeInterval
	var claimed = false
	var opened: NetworkWaiter<UTPStream>?
	var reader: (Int, NetworkWaiter<Data>)?
	var writer: UTPWrite?
	var finishing: NetworkWaiter<Void>?
	var completed: TimeInterval?
	init(endpoint: NetworkEndpoint, state: UTPState, leases: [TCPPeerLease], now: TimeInterval) { self.endpoint = endpoint; self.state = state; self.leases = leases; created = now }
}
struct UTPTombstone { let expires: TimeInterval; let packet: UTPPacket }
struct UTPOutbound: Sendable { let id: UUID?; let endpoint: NetworkEndpoint; let packet: UTPPacket }

public struct UTPStatistics: Sendable {
	public let connections: Int
	public let incomingBytes: Int
	public let outgoingBytes: Int
	public let retransmissions: Int
	public let droppedPackets: Int
}

/// UTPTransport multiplexes bounded BEP 29 streams over one address family's shared UDP port.
public actor UTPTransport {
	let dispatcher: UDPDispatcher
	let clock: any TransportClock
	let budget: TCPPeerBudget
	let maximumConnections: Int
	let ownership = UUID()
	var records: [UUID: UTPRecord] = [:]
	var routes: [UTPKey: UUID] = [:]
	var tombstones: [UTPKey: UTPTombstone] = [:]
	var accepted: [UUID] = []
	var acceptor: NetworkWaiter<UTPStream>?
	var pump: Task<Void, Never>?, ticker: Task<Void, Never>?, writer: Task<Void, Never>?
	let outbound = AsyncStream<UTPOutbound>.makeStream(bufferingPolicy: .bufferingOldest(512))
	var closed = false
	var failed = false
	var stopping: Task<Void, Never>?
	var retransmissions = 0, droppedPackets = 0
	var resetEpoch: Int64 = -1, resets = 0
	public nonisolated let localEndpoint: NetworkEndpoint
	private init(dispatcher: UDPDispatcher, maximumConnections: Int, budget: TCPPeerBudget?, clock: any TransportClock) {
		self.dispatcher = dispatcher; self.maximumConnections = maximumConnections; self.budget = budget ?? TCPPeerBudget(limit: maximumConnections); self.clock = clock
		localEndpoint = dispatcher.localEndpoint
	}
	public static func open(dispatcher: UDPDispatcher, maximumConnections: Int = 50, budget: TCPPeerBudget? = nil,
		clock: any TransportClock = ContinuousTransportClock()) async throws -> UTPTransport {
		guard (1...200).contains(maximumConnections) else { throw NetworkFailure.invalid("µTP connection limit") }
		let owner = UTPTransport(dispatcher: dispatcher, maximumConnections: maximumConnections, budget: budget, clock: clock)
		try await owner.start(); return owner
	}
	private func start() async throws {
		try Task.checkCancellation()
		try await dispatcher.claimUTP(ownership)
		do {
			let packets = try await dispatcher.subscribeUTP(ownership), clock = clock, dispatcher = dispatcher, outgoing = outbound.stream
			try Task.checkCancellation()
			pump = Task { [weak self] in for await packet in packets { if Task.isCancelled { break }; await self?.receive(packet) }; await self?.transportEnded() }
			ticker = Task { [weak self] in do { while !Task.isCancelled { try await clock.sleep(for: 0.05); if let self { await self.tick() } else { return } } } catch {} }
			writer = Task { [weak self] in
				for await item in outgoing {
					if Task.isCancelled { break }
					if let id = item.id, await self?.canSend(id) != true { continue }
					do { var packet = item.packet; packet.timestamp = utpTimestamp(clock.now()); try await dispatcher.send(packet.encoded(), to: item.endpoint) }
					catch is CancellationError { break }
					catch { await self?.sendFailed(item.id, error: error) }
				}
			}
		} catch { await dispatcher.releaseUTP(ownership); throw error }
	}
	public func snapshot() -> UTPStatistics {
		UTPStatistics(connections: records.values.filter { $0.completed == nil }.count, incomingBytes: incomingBytes,
			outgoingBytes: outgoingBytes, retransmissions: retransmissions + records.values.reduce(0) { $0 + $1.state.retransmissions }, droppedPackets: droppedPackets)
	}
	var incomingBytes: Int { records.values.reduce(0) { $0 + $1.state.buffered } }
	var outgoingBytes: Int { records.values.reduce(0) { $0 + ($1.writer?.bytes.count ?? 0) + $1.state.inFlight } }
	func canSend(_ id: UUID) -> Bool { !closed && records[id] != nil }
	func window(_ record: UTPRecord) -> Int { min(max(0, 262_144 - record.state.buffered), max(0, 16_777_216 - incomingBytes)) }
	func enqueue(_ packet: UTPPacket, to endpoint: NetworkEndpoint, id: UUID? = nil) {
		if case .dropped = outbound.continuation.yield(UTPOutbound(id: id, endpoint: endpoint, packet: packet)) { droppedPackets += 1 }
	}
	func stream(_ record: UTPRecord) -> UTPStream { UTPStream(owner: self, id: record.id, endpoint: record.endpoint, leases: record.leases, end: record.end) }
	public func connect(to peer: NetworkEndpoint, timeout: TimeInterval = 10, budget extra: TCPPeerBudget? = nil) async throws -> UTPStream {
		try Task.checkCancellation(); guard !closed, !failed else { throw NetworkFailure.closed }
		guard peer.port > 0, !peer.address.isUnspecified, !peer.address.isMulticast, peer.address.isIPv6 == localEndpoint.address.isIPv6 else { throw NetworkFailure.invalid("µTP endpoint") }
		guard records.count < maximumConnections else { throw NetworkFailure.limit("µTP connections") }
		var leases: [TCPPeerLease] = []
		guard let lease = budget.acquire() else { throw NetworkFailure.limit("peer connections") }; leases.append(lease)
		if let extra, extra !== budget {
			guard let second = extra.acquire() else { lease.release(); throw NetworkFailure.limit("peer connections") }; leases.append(second)
		}
		let now = clock.now(); var connection = UInt16.random(in: 0...65535), attempts = 0
		while routes[UTPKey(peer: peer, connection: connection)] != nil || routes[UTPKey(peer: peer, connection: connection &+ 1)] != nil || tombstones[UTPKey(peer: peer, connection: connection)] != nil {
			attempts += 1; guard attempts < 32 else { for lease in leases { lease.release() }; throw NetworkFailure.limit("µTP connection identifiers") }; connection &+= 2
		}
		let record = UTPRecord(endpoint: peer, state: UTPState(outgoing: true, id: connection, sequence: UInt16.random(in: 0...65535), now: now), leases: leases, now: now)
		let opened = NetworkWaiter<UTPStream>(); record.opened = opened; record.claimed = true
		records[record.id] = record; routes[UTPKey(peer: peer, connection: connection)] = record.id
		enqueue(record.state.initial(window: window(record), now: now), to: peer, id: record.id)
		do { return try await opened.value(timeout: timeout, clock: clock) } catch { abort(record.id, error: error); throw error }
	}
	public func accept(timeout: TimeInterval = 30) async throws -> UTPStream {
		try Task.checkCancellation(); guard !closed, !failed else { throw NetworkFailure.closed }
		while !accepted.isEmpty {
			let id = accepted.removeFirst()
			if let record = records[id] { record.claimed = true; return stream(record) }
		}
		guard acceptor == nil else { throw NetworkFailure.busy }
		let waiter = NetworkWaiter<UTPStream>(); acceptor = waiter
		defer { if acceptor === waiter { acceptor = nil } }
		return try await waiter.value(timeout: timeout, clock: clock)
	}
	func read(_ id: UUID, maximum: Int, timeout: TimeInterval) async throws -> Data {
		try Task.checkCancellation(); guard (1...1_048_576).contains(maximum) else { throw NetworkFailure.invalid("µTP read size") }
		guard let record = records[id] else { throw NetworkFailure.closed }; guard record.reader == nil else { throw NetworkFailure.busy }
		let waiter = NetworkWaiter<Data>(); record.reader = (maximum, waiter); drive(record)
		do { return try await waiter.value(timeout: timeout, clock: clock) } catch { abort(id, error: error); throw error }
	}
	func write(_ id: UUID, bytes: Data, timeout: TimeInterval) async throws {
		try Task.checkCancellation(); guard !bytes.isEmpty, bytes.count <= 1_048_576 else { throw NetworkFailure.invalid("µTP write size") }
		guard let record = records[id], !record.state.writeFinished else { throw NetworkFailure.closed }
		guard record.writer == nil, record.finishing == nil else { throw NetworkFailure.busy }
		// Reserve the retained write and its possible packet copies before admitting more work.
		let reserved = records.values.reduce(0) { $0 + ($1.writer?.bytes.count ?? 0) * 2 }
		guard reserved + bytes.count * 2 <= 16_777_216 else { throw NetworkFailure.backpressure }
		let waiter = NetworkWaiter<Void>(); record.writer = UTPWrite(bytes: Data(bytes), completion: waiter); drive(record)
		do { try await waiter.value(timeout: timeout, clock: clock) } catch { abort(id, error: error); throw error }
	}
	func finish(_ id: UUID, timeout: TimeInterval) async throws {
		guard let record = records[id] else { throw NetworkFailure.closed }
		if record.state.finAcknowledged { return }; guard record.finishing == nil else { throw NetworkFailure.busy }
		let waiter = NetworkWaiter<Void>(); record.finishing = waiter; drive(record)
		do { try await waiter.value(timeout: timeout, clock: clock) } catch { abort(id, error: error); throw error }
	}
	func abort(_ id: UUID, error: Error = NetworkFailure.closed, reset: Bool = true) {
		guard let record = records.removeValue(forKey: id) else { return }
		let key = UTPKey(peer: record.endpoint, connection: record.state.receiveID); routes[key] = nil; accepted.removeAll { $0 == id }
		retransmissions += record.state.retransmissions
		let acknowledgement = record.state.packet(.state, sequence: record.state.next, window: 0, now: clock.now())
		if tombstones.count >= 512, let oldest = tombstones.min(by: { $0.value.expires < $1.value.expires })?.key { tombstones[oldest] = nil }
		tombstones[key] = UTPTombstone(expires: clock.now() + 10, packet: acknowledgement)
		for lease in record.leases { lease.release() }
		record.opened?.resolve(.failure(error)); record.reader?.1.resolve(.failure(error)); record.writer?.completion.resolve(.failure(error)); record.finishing?.resolve(.failure(error))
		if reset && !closed { enqueue(record.state.packet(.reset, sequence: record.state.next, window: 0, now: clock.now()), to: record.endpoint) }
	}
	public func shutdown() async {
		let operation: Task<Void, Never>
		if let stopping { operation = stopping } else { operation = Task { await self.finishShutdown() }; stopping = operation }
		await operation.value
	}
	private func finishShutdown() async {
		closed = true
		acceptor?.resolve(.failure(NetworkFailure.closed)); acceptor = nil
		for id in Array(records.keys) { abort(id, reset: false) }
		pump?.cancel(); ticker?.cancel(); writer?.cancel(); outbound.continuation.finish()
		if let pump { await pump.value }; if let ticker { await ticker.value }; if let writer { await writer.value }
		pump = nil; ticker = nil; writer = nil; await dispatcher.releaseUTP(ownership)
	}
	func transportEnded() { if !closed { failed = true; Task { await self.shutdown() } } }
	func sendFailed(_ id: UUID?, error: Error) { if error as? NetworkFailure != .backpressure, let id { abort(id, error: error, reset: false) } }
	deinit {
		pump?.cancel(); ticker?.cancel(); writer?.cancel(); outbound.continuation.finish()
		let dispatcher = dispatcher, ownership = ownership; Task { await dispatcher.releaseUTP(ownership) }
	}
}
