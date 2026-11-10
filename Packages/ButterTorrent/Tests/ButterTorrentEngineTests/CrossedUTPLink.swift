import Foundation
@testable import ButterTorrentNetworking

actor CrossedUTPPort: DatagramTransport {
	nonisolated let localEndpoint: NetworkEndpoint
	nonisolated let datagrams: AsyncStream<NetworkDatagram>
	nonisolated let continuation: AsyncStream<NetworkDatagram>.Continuation
	let link: CrossedUTPLink
	init(endpoint: NetworkEndpoint, link: CrossedUTPLink) {
		localEndpoint = endpoint; self.link = link
		let pair = AsyncStream<NetworkDatagram>.makeStream(bufferingPolicy: .bufferingOldest(512)); datagrams = pair.stream; continuation = pair.continuation
	}
	func send(_ data: Data, to endpoint: NetworkEndpoint) async throws {
		try Task.checkCancellation(); try await link.send(data, source: localEndpoint, destination: endpoint)
	}
	func shutdown() async throws { continuation.finish(); await link.remove(localEndpoint) }
}

// Delay just the first outgoing stream's acknowledgement, leaving its reverse independent.
actor CrossedUTPLink {
	let initiator: NetworkEndpoint
	private var ports: [NetworkEndpoint: AsyncStream<NetworkDatagram>.Continuation] = [:]
	private var connection: UInt16?
	private var held: NetworkDatagram?
	private var released = false
	var holding: Bool { held != nil }
	init(initiator: NetworkEndpoint) { self.initiator = initiator }
	func add(_ port: CrossedUTPPort) { ports[port.localEndpoint] = port.continuation }
	func remove(_ endpoint: NetworkEndpoint) { ports[endpoint] = nil }
	func send(_ bytes: Data, source: NetworkEndpoint, destination: NetworkEndpoint) throws {
		let packet = try UTPPacket(bytes), datagram = NetworkDatagram(source: source, payload: bytes)
		if source == initiator, packet.type == .syn, connection == nil { connection = packet.connection }
		if destination == initiator, packet.type == .state, packet.connection == connection, !released { held = datagram; return }
		guard let port = ports[destination] else { throw NetworkFailure.closed }
		if case .dropped = port.yield(datagram) { throw NetworkFailure.backpressure }
	}
	func release() { released = true; if let held { ports[initiator]?.yield(held) }; held = nil }
}
