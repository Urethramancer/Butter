import Foundation

public enum MappedTransport: String, Sendable { case tcp = "TCP", udp = "UDP" }
public struct PortMapping: Sendable {
	public let transport: MappedTransport
	public let internalPort: UInt16
	public let externalPort: UInt16
	public let lifetime: UInt32
	public let renewAt: TimeInterval
}

/// NATPMPClient creates, renews and removes mappings through the shared UDP transport.
public actor NATPMPClient {
	private let dispatcher: UDPDispatcher
	private let gateway: NetworkEndpoint
	private let clock: any TransportClock
	private var epoch: UInt32?
	private var lastEpochTime: TimeInterval = 0
	private var mappings: [MappedTransport: PortMapping] = [:]
	private var busy = false
	public private(set) var requiresRemapping = false
	public init(dispatcher: UDPDispatcher, gateway: NetworkEndpoint, clock: any TransportClock = ContinuousTransportClock()) throws {
		guard !gateway.address.isIPv6, !gateway.address.isUnspecified, !gateway.address.isMulticast, !dispatcher.localEndpoint.address.isIPv6, gateway.port > 0 else { throw NetworkFailure.invalid("NAT-PMP gateway") }
		self.dispatcher = dispatcher; self.gateway = gateway; self.clock = clock
	}
	public func externalAddress() async throws -> IPAddress {
		guard !busy else { throw NetworkFailure.busy }; busy = true; defer { busy = false }
		let response = try await request(Data([0, 0]), opcode: 0)
		guard response.count >= 12 else { throw NetworkFailure.invalid("NAT-PMP address response") }
		return try IPAddress(bytes: response.subdata(in: 8..<12))
	}
	@discardableResult public func map(_ transport: MappedTransport, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32 = 3600) async throws -> PortMapping {
		guard !busy else { throw NetworkFailure.busy }; busy = true; defer { busy = false }
		guard internalPort > 0, lifetime > 0, lifetime <= 86400 else { throw NetworkFailure.invalid("NAT-PMP mapping") }
		if let current = mappings[transport], current.internalPort != internalPort { throw NetworkFailure.invalid("remove the previous NAT-PMP mapping before changing ports") }
		let mapping = try await mappingRequest(transport, internalPort: internalPort, externalPort: externalPort, lifetime: lifetime)
		mappings[transport] = mapping
		return mapping
	}
	public func renewIfDue() async throws {
		guard !busy else { throw NetworkFailure.busy }; busy = true; defer { busy = false }
		for (kind, mapping) in mappings where requiresRemapping || clock.now() >= mapping.renewAt {
			mappings[kind] = try await mappingRequest(kind, internalPort: mapping.internalPort, externalPort: mapping.externalPort, lifetime: mapping.lifetime)
		}
		requiresRemapping = false
	}
	public func remove(_ transport: MappedTransport) async throws {
		guard !busy else { throw NetworkFailure.busy }; busy = true; defer { busy = false }
		guard let mapping = mappings[transport] else { return }
		_ = try await mappingRequest(transport, internalPort: mapping.internalPort, externalPort: 0, lifetime: 0)
		mappings[transport] = nil
	}
	private func mappingRequest(_ transport: MappedTransport, internalPort: UInt16, externalPort: UInt16, lifetime: UInt32) async throws -> PortMapping {
		let opcode: UInt8 = transport == .udp ? 1 : 2
		var bytes = Data([0, opcode, 0, 0]); PacketBytes.append(internalPort, to: &bytes); PacketBytes.append(externalPort, to: &bytes); PacketBytes.append(lifetime, to: &bytes)
		let response = try await request(bytes, opcode: opcode)
		guard response.count >= 16, try PacketBytes.uint16(response, at: 8) == internalPort else { throw NetworkFailure.invalid("NAT-PMP mapping reply") }
		let port = try PacketBytes.uint16(response, at: 10), duration = try PacketBytes.uint32(response, at: 12)
		guard lifetime == 0 ? duration == 0 : (duration > 0 && port > 0) else { throw NetworkFailure.invalid("NAT-PMP mapping lifetime") }
		let retained = min(duration, lifetime)
		return PortMapping(transport: transport, internalPort: internalPort, externalPort: port, lifetime: retained, renewAt: clock.now() + TimeInterval(retained) / 2)
	}
	private func request(_ bytes: Data, opcode: UInt8) async throws -> Data {
		for attempt in 0..<9 {
			do {
				let response = try await dispatcher.exchange(bytes, with: gateway, reply: .natPMP(opcode: opcode, internalPort: nil), timeout: min(64, 0.25 * pow(2, Double(attempt)))).payload
				guard response.count >= 8, response[0] == 0, response[1] == opcode | 128 else { throw NetworkFailure.invalid("NAT-PMP response") }
				let result = try PacketBytes.uint16(response, at: 2)
				guard result == 0 else { throw NetworkFailure.invalid("NAT-PMP result \(result)") }
				let current = try PacketBytes.uint32(response, at: 4)
				if let epoch, Double(current) + 2 < Double(epoch) + max(0, clock.now() - lastEpochTime) { requiresRemapping = true }
				epoch = current; lastEpochTime = clock.now()
				return response
			} catch NetworkFailure.timedOut { continue }
		}
		throw NetworkFailure.timedOut
	}
}
