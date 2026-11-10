import Foundation
import ButterTorrentMetadata

/// UDPTrackerClient implements BEP 15 and BEP 41 on the engine's shared UDP dispatchers.
public actor UDPTrackerClient: TrackerAnnouncing {
	private struct Connection { let id: UInt64; let expires: TimeInterval }
	private let dispatchers: [Bool: UDPDispatcher]
	private let resolver: any AddressResolving
	private let clock: any TransportClock
	private let key: UInt32
	private let timeout: TimeInterval
	private var transaction: UInt32
	private var connections: [NetworkEndpoint: Connection] = [:]
	public init(dispatchers: [UDPDispatcher], resolver: any AddressResolving = SystemAddressResolver(), clock: any TransportClock = ContinuousTransportClock(),
		key: UInt32 = .random(in: .min ... .max), transactionSeed: UInt32 = .random(in: .min ... .max), timeout: TimeInterval = 120) throws {
		guard (1...2).contains(dispatchers.count), Set(dispatchers.map { $0.localEndpoint.address.isIPv6 }).count == dispatchers.count,
			timeout.isFinite, timeout > 0, timeout <= 86400 else { throw NetworkFailure.invalid("UDP tracker configuration") }
		self.dispatchers = Dictionary(uniqueKeysWithValues: dispatchers.map { ($0.localEndpoint.address.isIPv6, $0) })
		self.resolver = resolver; self.clock = clock; self.key = key; transaction = transactionSeed; self.timeout = timeout
	}
	public func announce(to tracker: URL, request: TrackerRequest) async throws -> TrackerResponse {
		try Task.checkCancellation(); try request.validateFields()
		let (host, port) = try Self.destination(tracker)
		let deadline = clock.now() + timeout
		let answers = try await resolver.resolve(host: host, port: port, timeout: min(10, timeout))
		guard let endpoint = answers.first(where: { dispatchers[$0.address.isIPv6] != nil && $0.port == port && !$0.address.isUnspecified && !$0.address.isMulticast }),
			let dispatcher = dispatchers[endpoint.address.isIPv6] else { throw NetworkFailure.invalid("UDP tracker address family") }
		let id = nextID()
		for attempt in 0..<9 {
			do {
				let connection = try await connection(to: endpoint, dispatcher: dispatcher, deadline: deadline)
				var bytes = Data()
				PacketBytes.append(connection, to: &bytes); PacketBytes.append(UInt32(1), to: &bytes); PacketBytes.append(id, to: &bytes)
				bytes.append(request.infoHash); bytes.append(request.peerID)
				PacketBytes.append(UInt64(request.counters.downloaded), to: &bytes); PacketBytes.append(UInt64(request.counters.left), to: &bytes); PacketBytes.append(UInt64(request.counters.uploaded), to: &bytes)
				let event: UInt32 = request.event == .completed ? 1 : request.event == .started ? 2 : request.event == .stopped ? 3 : 0
				PacketBytes.append(event, to: &bytes); PacketBytes.append(UInt32(0), to: &bytes); PacketBytes.append(key, to: &bytes)
				PacketBytes.append(Int32(request.wantedPeers), to: &bytes); PacketBytes.append(request.port, to: &bytes)
				let parts = URLComponents(url: tracker, resolvingAgainstBaseURL: false)!
				var resource = parts.percentEncodedPath
				if let query = parts.percentEncodedQuery { resource += "?" + query }
				let path = Data(resource.utf8)
				guard path.count <= 4096 else { throw NetworkFailure.limit("UDP tracker URL") }
				for start in stride(from: 0, to: path.count, by: 255) {
					let part = path.subdata(in: start..<min(start + 255, path.count)); bytes.append(contentsOf: [2, UInt8(part.count)]); bytes.append(part)
				}
				let response = try await dispatcher.exchange(bytes, with: endpoint, reply: .tracker(id), timeout: retryDelay(attempt, deadline: deadline)).payload
				try Self.check(response, action: 1, id: id, minimum: 20)
				let interval = try PacketBytes.uint32(response, at: 8), leechers = try PacketBytes.uint32(response, at: 12), seeders = try PacketBytes.uint32(response, at: 16)
				let peers = response.subdata(in: 20..<response.count)
				let fields: [Data: BencodeValue] = [
					Data("interval".utf8): .integer(Int64(interval)), Data("complete".utf8): .integer(Int64(seeders)),
					Data("incomplete".utf8): .integer(Int64(leechers)), Data((endpoint.address.isIPv6 ? "peers6" : "peers").utf8): .bytes(peers)
				]
				return try TrackerResponse(BencodeValue.dictionary(fields).encoded())
			} catch NetworkFailure.timedOut { continue }
		}
		throw NetworkFailure.timedOut
	}
	private func nextID() -> UInt32 { transaction &+= 1; return transaction }
	private func retryDelay(_ attempt: Int, deadline: TimeInterval) throws -> TimeInterval {
		let remaining = deadline - clock.now()
		guard remaining > 0 else { throw NetworkFailure.timedOut }
		return min(15 * pow(2, Double(attempt)), remaining)
	}
	private func connection(to endpoint: NetworkEndpoint, dispatcher: UDPDispatcher, deadline: TimeInterval) async throws -> UInt64 {
		if let cached = connections[endpoint], clock.now() < cached.expires { return cached.id }
		connections = connections.filter { $0.value.expires > clock.now() }
		guard connections.count < 128 else { throw NetworkFailure.limit("UDP tracker connections") }
		let id = nextID()
		var bytes = Data(); PacketBytes.append(UInt64(0x41727101980), to: &bytes); PacketBytes.append(UInt32(0), to: &bytes); PacketBytes.append(id, to: &bytes)
		for attempt in 0..<9 {
			do {
				let response = try await dispatcher.exchange(bytes, with: endpoint, reply: .tracker(id), timeout: retryDelay(attempt, deadline: deadline)).payload
				try Self.check(response, action: 0, id: id, minimum: 16)
				let connection = try PacketBytes.uint64(response, at: 8)
				connections[endpoint] = Connection(id: connection, expires: clock.now() + 60)
				return connection
			} catch NetworkFailure.timedOut { continue }
		}
		throw NetworkFailure.timedOut
	}
	static func destination(_ url: URL) throws -> (String, UInt16) {
		guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme?.lowercased() == "udp",
			let host = url.host, !host.isEmpty, host.utf8.count <= 253, parts.user == nil, parts.password == nil, parts.fragment == nil,
			(1...65535).contains(parts.port ?? 443), url.absoluteString.utf8.count <= 4096 else { throw NetworkFailure.invalid("UDP tracker URL") }
		return (host, UInt16(parts.port ?? 443))
	}
	private static func check(_ data: Data, action: UInt32, id: UInt32, minimum: Int) throws {
		guard data.count >= 8, try PacketBytes.uint32(data, at: 4) == id else { throw NetworkFailure.invalid("UDP tracker transaction") }
		let actual = try PacketBytes.uint32(data, at: 0)
		if actual == 3 { throw HTTPServiceError.trackerFailure(String(decoding: data.dropFirst(8).prefix(1024), as: UTF8.self)) }
		guard actual == action, data.count >= minimum else { throw NetworkFailure.invalid("UDP tracker action or length") }
	}
}

/// TrackerClient routes HTTP and UDP tiers through the same lifecycle interface.
public struct TrackerClient: TrackerAnnouncing {
	private let http: any TrackerAnnouncing
	private let udp: any TrackerAnnouncing
	public init(http: any TrackerAnnouncing = HTTPTrackerClient(), udp: any TrackerAnnouncing) { self.http = http; self.udp = udp }
	public func announce(to tracker: URL, request: TrackerRequest) async throws -> TrackerResponse {
		if tracker.scheme?.lowercased() == "udp" { return try await udp.announce(to: tracker, request: request) }
		return try await http.announce(to: tracker, request: request)
	}
}
