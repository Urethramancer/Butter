import Foundation
import ButterTorrentMetadata

/// UDPReply identifies a reply independently of its source endpoint.
public enum UDPReply: Hashable, Sendable {
	case tracker(UInt32)
	case dht(Data)
	case natPMP(opcode: UInt8, internalPort: UInt16?)
}

public enum UDPChannel: Sendable { case dht, utp, localDiscovery, ssdp, natPMP, raw }

/// UDPDispatcher shares one UDP port across transactions, DHT, µTP and discovery consumers.
public actor UDPDispatcher {
	private struct Key: Hashable { let peer: NetworkEndpoint; let reply: UDPReply }
	public nonisolated let localEndpoint: NetworkEndpoint
	private let transport: any DatagramTransport
	private let clock: any TransportClock
	private var pending: [Key: NetworkWaiter<NetworkDatagram>] = [:]
	private var subscribers: [UUID: (UDPChannel, AsyncStream<NetworkDatagram>.Continuation)] = [:]
	private var pump: Task<Void, Never>?
	private var closed = false
	private var dropped: UInt64 = 0
	public var pendingCount: Int { pending.count }
	public var droppedPackets: UInt64 { dropped }
	public init(transport: any DatagramTransport, clock: any TransportClock = ContinuousTransportClock()) {
		self.transport = transport; self.clock = clock; localEndpoint = transport.localEndpoint
	}
	private func start() {
		guard pump == nil, !closed else { return }
		let incoming = transport.datagrams
		pump = Task { [weak self] in
			for await packet in incoming { await self?.receive(packet) }
			await self?.ended()
		}
	}
	public func exchange(_ data: Data, with peer: NetworkEndpoint, reply: UDPReply, timeout: TimeInterval) async throws -> NetworkDatagram {
		try Task.checkCancellation()
		guard !closed else { throw NetworkFailure.closed }
		guard pending.count < 128 else { throw NetworkFailure.limit("UDP transactions") }
		let key = Key(peer: peer, reply: reply)
		guard pending[key] == nil else { throw NetworkFailure.busy }
		let waiter = NetworkWaiter<NetworkDatagram>(); pending[key] = waiter; start()
		defer { pending[key] = nil }
		try await transport.send(data, to: peer)
		return try await waiter.value(timeout: timeout, clock: clock)
	}
	public func send(_ data: Data, to peer: NetworkEndpoint) async throws {
		guard !closed else { throw NetworkFailure.closed }
		try await transport.send(data, to: peer)
	}
	public func subscribe(_ channel: UDPChannel) throws -> AsyncStream<NetworkDatagram> {
		guard !closed else { throw NetworkFailure.closed }
		guard subscribers.count < 16 else { throw NetworkFailure.limit("UDP subscribers") }
		let id = UUID(), pair = AsyncStream<NetworkDatagram>.makeStream(bufferingPolicy: .bufferingNewest(32))
		pair.continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
		subscribers[id] = (channel, pair.continuation); start(); return pair.stream
	}
	private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
	private func publish(_ packet: NetworkDatagram, to channel: UDPChannel) {
		for (_, (kind, continuation)) in subscribers where kind == channel {
			if case .dropped = continuation.yield(packet) { dropped &+= 1 }
		}
	}
	private func receive(_ packet: NetworkDatagram) {
		guard !closed, !packet.payload.isEmpty, packet.payload.count <= 65_507 else { return }
		publish(packet, to: .raw)
		let data = packet.payload
		let root = data[0] == 100 ? try? BencodeDocument(data, limits: .init(bytes: 65_507, depth: 12, values: 4096)).root : nil
		var candidates: [UDPReply] = []
		if data.count >= 8, (try? PacketBytes.uint32(data, at: 0)) ?? 4 <= 3, let id = try? PacketBytes.uint32(data, at: 4) { candidates.append(.tracker(id)) }
		if let root, let id = root["t"]?.bytes, !id.isEmpty, id.count <= 8, ["r", "e"].contains(root["y"]?.text ?? "") { candidates.append(.dht(id)) }
		if data.count >= 8, data[0] == 0, data[1] >= 128 {
			candidates.append(.natPMP(opcode: data[1] & 127, internalPort: nil))
			if let port = try? PacketBytes.uint16(data, at: 8) { candidates.append(.natPMP(opcode: data[1] & 127, internalPort: port)) }
		}
		for reply in candidates {
			if let waiter = pending[Key(peer: packet.source, reply: reply)] { waiter.resolve(.success(packet)); return }
		}
		if let root, let id = root["t"]?.bytes, !id.isEmpty, id.count <= 8, ["q", "r", "e"].contains(root["y"]?.text ?? "") { publish(packet, to: .dht) }
		else if data.count >= 20, data[0] & 15 == 1, data[0] >> 4 <= 4 { publish(packet, to: .utp) }
		else if data.starts(with: Data("BT-SEARCH ".utf8)) { publish(packet, to: .localDiscovery) }
		else if data.starts(with: Data("HTTP/1.1 ".utf8)) || data.starts(with: Data("NOTIFY ".utf8)) { publish(packet, to: .ssdp) }
		else if data.count >= 8 && data[0] == 0 && data[1] >= 128 { publish(packet, to: .natPMP) }
	}
	private func ended() {
		closed = true
		for waiter in pending.values { waiter.resolve(.failure(NetworkFailure.closed)) }
		for (_, continuation) in subscribers.values { continuation.finish() }
		subscribers.removeAll()
	}
	public func shutdown() async throws {
		ended(); pump?.cancel(); pump = nil
		try await transport.shutdown()
	}
}

enum PacketBytes {
	static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) { var value = value.bigEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
	static func uint16(_ data: Data, at offset: Int) throws -> UInt16 {
		guard offset >= 0, offset <= data.count - 2 else { throw NetworkFailure.invalid("packet length") }
		return UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
	}
	static func uint32(_ data: Data, at offset: Int) throws -> UInt32 {
		guard offset >= 0, offset <= data.count - 4 else { throw NetworkFailure.invalid("packet length") }
		return (offset..<offset + 4).reduce(UInt32(0)) { $0 << 8 | UInt32(data[$1]) }
	}
	static func uint64(_ data: Data, at offset: Int) throws -> UInt64 {
		guard offset >= 0, offset <= data.count - 8 else { throw NetworkFailure.invalid("packet length") }
		return (offset..<offset + 8).reduce(UInt64(0)) { $0 << 8 | UInt64(data[$1]) }
	}
}
