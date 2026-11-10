import Foundation
import ButterTorrentMetadata

public struct DiscoveredPeer: Sendable {
	public let infoHash: Data
	public let endpoint: NetworkEndpoint
}

/// LocalDiscovery implements BEP 14, advertising only metadata known to be public.
public actor LocalDiscovery {
	public nonisolated let peers: AsyncStream<DiscoveredPeer>
	private let continuation: AsyncStream<DiscoveredPeer>.Continuation
	private let dispatcher: UDPDispatcher
	private let target: NetworkEndpoint
	private let port: UInt16
	private let cookie: String
	private let clock: any HTTPServiceClock
	private let ownsTransport: Bool
	private var hashes: [Data] = []
	private var cursor = 0
	private var next: TimeInterval = 0
	private var pump: Task<Void, Never>?
	private var closed = false
	public init(dispatcher: UDPDispatcher, peerPort: UInt16, cookie: String = UUID().uuidString,
		clock: any HTTPServiceClock = MonotonicHTTPClock(), ownsTransport: Bool = false) throws {
		guard peerPort > 0, !cookie.isEmpty, cookie.utf8.count <= 64, cookie.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }) else { throw NetworkFailure.invalid("local discovery configuration") }
		self.dispatcher = dispatcher; port = peerPort; self.cookie = cookie; self.clock = clock; self.ownsTransport = ownsTransport
		target = try NetworkEndpoint(dispatcher.localEndpoint.address.isIPv6 ? "ff15::efc0:988f" : "239.192.152.143", port: 6771)
		let pair = AsyncStream<DiscoveredPeer>.makeStream(bufferingPolicy: .bufferingNewest(64)); peers = pair.stream; continuation = pair.continuation
	}
	public static func open(interface: IPAddress, interfaceIndex: UInt32 = 0, peerPort: UInt16) throws -> LocalDiscovery {
		let group = try IPAddress(interface.isIPv6 ? "ff15::efc0:988f" : "239.192.152.143")
		let socket = try DatagramSocket(bind: NetworkEndpoint(interface.isIPv6 ? "::" : "0.0.0.0", port: 6771), reusePort: true)
		do { try socket.joinMulticast(group, interfaceAddress: interface, interfaceIndex: interfaceIndex == 0 ? interface.scope : interfaceIndex) }
		catch { socket.close(); throw error }
		return try LocalDiscovery(dispatcher: UDPDispatcher(transport: socket), peerPort: peerPort, ownsTransport: true)
	}
	public func setTorrents(_ metadata: [TorrentMetadata]) async throws {
		guard !closed else { throw NetworkFailure.closed }
		var allowed: Set<Data> = []
		for torrent in metadata where !torrent.inspection.private {
			if let v1 = torrent.hashes.v1 { allowed.insert(v1) }
			if let v2 = torrent.hashes.v2 { allowed.insert(Data(v2.prefix(20))) }
			guard allowed.count <= 4096 else { throw NetworkFailure.limit("local discovery swarms") }
		}
		hashes = allowed.sorted { $0.lexicographicallyPrecedes($1) }; cursor = 0
		if pump == nil {
			let incoming = try await dispatcher.subscribe(.localDiscovery)
			pump = Task { [weak self] in for await packet in incoming { await self?.receive(packet) } }
		}
	}
	@discardableResult public func announceIfDue() async throws -> Bool {
		guard !closed else { throw NetworkFailure.closed }
		guard !hashes.isEmpty, clock.now() >= next else { return false }
		let count = min(20, hashes.count), selected = (0..<count).map { hashes[(cursor + $0) % hashes.count] }
		let host = target.address.isIPv6 ? "[\(target.address)]:6771" : "\(target.address):6771"
		var text = "BT-SEARCH * HTTP/1.1\r\nHost: \(host)\r\nPort: \(port)\r\ncookie: \(cookie)\r\n"
		for hash in selected { text += "Infohash: " + hash.map { String(format: "%02x", $0) }.joined() + "\r\n" }
		let bytes = Data((text + "\r\n\r\n").utf8)
		guard bytes.count <= 1400 else { throw NetworkFailure.limit("local discovery packet") }
		// Reserve the interval before suspension so concurrent ticks cannot multicast twice.
		next = clock.now() + (hashes.count > 20 ? 60 : 300); cursor = (cursor + count) % hashes.count
		try await dispatcher.send(bytes, to: target)
		return true
	}
	private func receive(_ packet: NetworkDatagram) {
		guard !closed, packet.payload.count <= 1400, !packet.source.address.isUnspecified, !packet.source.address.isMulticast,
			let text = String(data: packet.payload, encoding: .ascii), text.hasSuffix("\r\n\r\n") else { return }
		let lines = text.components(separatedBy: "\r\n")
		guard lines.first == "BT-SEARCH * HTTP/1.1" else { return }
		var fields: [String: [String]] = [:]
		for line in lines.dropFirst() where !line.isEmpty {
			let parts = line.split(separator: ":", maxSplits: 1)
			guard parts.count == 2 else { return }
			fields[parts[0].lowercased(), default: []].append(parts[1].trimmingCharacters(in: .whitespaces))
		}
		guard fields["cookie"]?.first != cookie, fields["port"]?.count == 1, let value = fields["port"]?.first,
			value.utf8.allSatisfy({ (48...57).contains($0) }), let port = UInt16(value), port > 0,
			fields["host"]?.count == 1, fields["host"]?.first == target.description else { return }
		var seen: Set<Data> = []
		for text in fields["infohash"] ?? [] {
			guard let hash = try? InfoHashes(hex: [text]).v1, hashes.contains(hash), seen.insert(hash).inserted else { continue }
			continuation.yield(DiscoveredPeer(infoHash: hash, endpoint: NetworkEndpoint(address: packet.source.address, port: port)))
		}
	}
	public func shutdown() async throws {
		closed = true; pump?.cancel(); pump = nil; continuation.finish()
		if ownsTransport { try await dispatcher.shutdown() }
	}
}
