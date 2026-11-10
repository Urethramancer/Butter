import Foundation

public struct UPnPCandidate: Sendable {
	public let location: URL
	public let gateway: IPAddress
	public let expires: TimeInterval
	public let bootID: UInt32?
	public init(location: URL, gateway: IPAddress, expires: TimeInterval, bootID: UInt32? = nil) throws {
		try HTTPURL.validate(location)
		guard let host = location.host, (try? IPAddress(host)) == gateway, !gateway.isUnspecified, !gateway.isMulticast else { throw NetworkFailure.invalid("UPnP description origin") }
		self.location = location; self.gateway = gateway; self.expires = expires; self.bootID = bootID
	}
}

/// UPnPDiscovery performs bounded SSDP searches; Location must belong to the replying address.
public actor UPnPDiscovery {
	public nonisolated let devices: AsyncStream<UPnPCandidate>
	private let continuation: AsyncStream<UPnPCandidate>.Continuation
	private let dispatcher: UDPDispatcher
	private let clock: any HTTPServiceClock
	private let ownsTransport: Bool
	private var pump: Task<Void, Never>?
	private var next: TimeInterval = 0
	private var known: [URL: (expires: TimeInterval, bootID: UInt32?)] = [:]
	private var closed = false
	public init(dispatcher: UDPDispatcher, clock: any HTTPServiceClock = MonotonicHTTPClock(), ownsTransport: Bool = false) {
		self.dispatcher = dispatcher; self.clock = clock; self.ownsTransport = ownsTransport
		let pair = AsyncStream<UPnPCandidate>.makeStream(bufferingPolicy: .bufferingNewest(16)); devices = pair.stream; continuation = pair.continuation
	}
	public static func open(interface: NetworkInterfaceAddress) throws -> UPnPDiscovery {
		try open(interfaceAddress: interface.address, interfaceIndex: interface.index, clock: ContinuousTransportClock())
	}
	public static func open(interfaceAddress: IPAddress, interfaceIndex: UInt32, clock: any TransportClock) throws -> UPnPDiscovery {
		let socket = try DatagramSocket(bind: NetworkEndpoint(address: interfaceAddress, port: 0))
		do { try socket.configureMulticast(interfaceAddress: interfaceAddress, interfaceIndex: interfaceIndex) }
		catch { socket.close(); throw error }
		return UPnPDiscovery(dispatcher: UDPDispatcher(transport: socket, clock: clock), clock: clock, ownsTransport: true)
	}
	@discardableResult public func searchIfDue() async throws -> Bool {
		guard !closed else { throw NetworkFailure.closed }
		guard clock.now() >= next else { return false }
		// Reserve before subscribing: actor reentrancy must not admit another tick.
		next = clock.now() + 60
		if pump == nil {
			let incoming = try await dispatcher.subscribe(.ssdp)
			pump = Task { [weak self] in for await packet in incoming { await self?.receive(packet) } }
		}
		guard !closed else { pump?.cancel(); pump = nil; throw NetworkFailure.closed }
		let target = try NetworkEndpoint(dispatcher.localEndpoint.address.isIPv6 ? "ff02::c" : "239.255.255.250", port: 1900)
		let bytes = Data("M-SEARCH * HTTP/1.1\r\nHOST: \(target)\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n".utf8)
		try await dispatcher.send(bytes, to: target)
		return true
	}
	private func receive(_ packet: NetworkDatagram) {
		guard !closed, packet.payload.count <= 8192, !packet.source.address.isLoopback, !packet.source.address.isUnspecified, !packet.source.address.isMulticast,
			let text = String(data: packet.payload, encoding: .ascii), text.hasSuffix("\r\n\r\n") else { return }
		let lines = text.components(separatedBy: "\r\n")
		guard lines.first?.hasPrefix("HTTP/1.1 200 ") == true else { return }
		var fields: [String: String] = [:]
		for line in lines.dropFirst() where !line.isEmpty {
			let pair = line.split(separator: ":", maxSplits: 1)
			guard pair.count == 2 else { return }
			let key = pair[0].lowercased()
			guard fields[key] == nil else { return }
			fields[key] = pair[1].trimmingCharacters(in: .whitespaces)
		}
		guard let service = fields["st"], service.hasPrefix("urn:schemas-upnp-org:device:InternetGatewayDevice:") || service.hasPrefix("urn:schemas-upnp-org:service:WANIPConnection:") || service.hasPrefix("urn:schemas-upnp-org:service:WANPPPConnection:"),
			let location = fields["location"].flatMap(URL.init(string:)) else { return }
		known = known.filter { $0.value.expires > clock.now() }
		let bootID = fields["bootid.upnp.org"].flatMap(UInt32.init)
		guard known[location]?.bootID != bootID || known[location] == nil, known[location] != nil || known.count < 16 else { return }
		let age = fields["cache-control"]?.split(separator: ",").compactMap { item -> TimeInterval? in
			let pair = item.split(separator: "=", maxSplits: 1)
			guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "max-age", let seconds = UInt32(pair[1].trimmingCharacters(in: .whitespaces)) else { return nil }
			return TimeInterval(min(86400, max(1, seconds)))
		}.first ?? 1800
		guard let candidate = try? UPnPCandidate(location: location, gateway: packet.source.address, expires: clock.now() + age, bootID: bootID) else { return }
		known[location] = (candidate.expires, bootID); continuation.yield(candidate)
	}
	public func shutdown() async throws {
		closed = true; pump?.cancel(); pump = nil; continuation.finish()
		if ownsTransport { try await dispatcher.shutdown() }
	}
}
