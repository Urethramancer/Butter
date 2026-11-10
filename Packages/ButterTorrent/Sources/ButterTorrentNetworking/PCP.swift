import Foundation

enum PCPFailure: Error, LocalizedError, Equatable {
	case unsupportedVersion
	case result(UInt8)
	var errorDescription: String? {
		switch self {
		case .unsupportedVersion: "The gateway does not support PCP version 2."
		case .result(let result): "The gateway returned PCP error \(result)."
		}
	}
}

// RFC 6887 MAP requests retain the same nonce for renewal and deletion.
struct PCPMapping: Sendable {
	let internalPort: UInt16
	var nonce = Data((0..<12).map { _ in UInt8.random(in: .min ... .max) })
	var address: IPAddress?
	var externalPort: UInt16?

	struct Response: Sendable {
		let address: IPAddress
		let port: UInt16
		let lifetime: UInt32
		let epoch: UInt32
	}

	func request(dispatcher: UDPDispatcher, gateway: NetworkEndpoint, source: IPAddress, transport: MappedTransport, externalPort: UInt16, lifetime: UInt32) async throws -> Response {
		let number: UInt8 = transport == .tcp ? 6 : 17
		var bytes = Data([2, 1, 0, 0]); PacketBytes.append(lifetime, to: &bytes)
		bytes.append(Self.encoded(source)); bytes.append(nonce)
		bytes.append(contentsOf: [number, 0, 0, 0]); PacketBytes.append(internalPort, to: &bytes)
		PacketBytes.append(self.externalPort ?? externalPort, to: &bytes)
		let suggestion = address ?? (source.isLocal ? nil : source)
		if let suggestion { bytes.append(Self.encoded(suggestion)) }
		else { bytes.append(source.isIPv6 ? Data(repeating: 0, count: 16) : Self.mappedPrefix + Data(repeating: 0, count: 4)) }
		for timeout in [3.0, 6.0, 12.0] {
			do {
				let packet = try await dispatcher.exchange(bytes, with: gateway, reply: .pcpMap(nonce: nonce), alternate: .pcpMap(nonce: nil), timeout: timeout * Double.random(in: 0.9...1.1))
				let response = packet.payload
				if response.count == 8, response[0] == 0 { throw PCPFailure.unsupportedVersion }
				guard response.count >= 24, response[0] == 2, response[1] == 129 else { throw NetworkFailure.invalid("PCP response header") }
				if response[3] == 1 { throw PCPFailure.unsupportedVersion }
				if response[3] != 0 { throw PCPFailure.result(response[3]) }
				guard response.count >= 60, response.subdata(in: 24..<36) == nonce, response[36] == number,
					try PacketBytes.uint16(response, at: 40) == internalPort else { throw NetworkFailure.invalid("PCP mapping reply") }
				let port = try PacketBytes.uint16(response, at: 42), duration = try PacketBytes.uint32(response, at: 4)
				let address = try IPAddress(bytes: response.subdata(in: 44..<60))
				guard lifetime == 0 ? duration == 0 : (duration > 0 && port > 0 && !address.isUnspecified && !address.isMulticast) else { throw NetworkFailure.invalid("PCP mapping lifetime or address") }
				return Response(address: address, port: port, lifetime: duration, epoch: try PacketBytes.uint32(response, at: 8))
			} catch NetworkFailure.timedOut { continue }
		}
		throw NetworkFailure.timedOut
	}

	private static let mappedPrefix = Data(repeating: 0, count: 10) + Data([255, 255])
	private static func encoded(_ address: IPAddress) -> Data { address.isIPv6 ? address.bytes : mappedPrefix + address.bytes }
}
