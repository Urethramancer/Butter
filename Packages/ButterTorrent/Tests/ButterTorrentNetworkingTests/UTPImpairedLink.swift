import Foundation
@testable import ButterTorrentNetworking

actor UTPLinkPort: DatagramTransport {
	nonisolated let localEndpoint: NetworkEndpoint
	nonisolated let datagrams: AsyncStream<NetworkDatagram>
	let continuation: AsyncStream<NetworkDatagram>.Continuation
	let link: UTPImpairedLink
	init(endpoint: NetworkEndpoint, link: UTPImpairedLink) {
		localEndpoint = endpoint; self.link = link
		let pair = AsyncStream<NetworkDatagram>.makeStream(bufferingPolicy: .bufferingNewest(512)); datagrams = pair.stream; continuation = pair.continuation
	}
	func send(_ data: Data, to endpoint: NetworkEndpoint) async throws { try Task.checkCancellation(); await link.send(data, source: localEndpoint, destination: endpoint) }
	func inject(_ datagram: NetworkDatagram) { continuation.yield(datagram) }
	func shutdown() async throws { continuation.finish() }
}

actor UTPImpairedLink {
	struct Identity: Hashable { let source: NetworkEndpoint; let id: UInt16; let sequence: UInt16; let type: UTPPacketType }
	struct Delivery { let due: TimeInterval; let source: NetworkEndpoint; let destination: NetworkEndpoint; let bytes: Data }
	let clock: ManualTransportClock
	let impaired: Bool
	var ports: [NetworkEndpoint: UTPLinkPort] = [:]
	var queued: [Delivery] = []
	var seen: Set<Identity> = []
	var counts: [NetworkEndpoint: Int] = [:]
	var zeroWindows: Set<NetworkEndpoint> = [], droppedUpdates: Set<NetworkEndpoint> = []
	var initialStates: Set<NetworkEndpoint> = [], reopened: Set<NetworkEndpoint> = []
	var lastData: [NetworkEndpoint: UInt16] = [:]
	var persistProbes = 0
	var blackhole = false
	var drops = 0, duplicates = 0, reorders = 0
	init(clock: ManualTransportClock, impaired: Bool) { self.clock = clock; self.impaired = impaired }
	func add(_ port: UTPLinkPort) { ports[port.localEndpoint] = port }
	func setBlackhole() { blackhole = true; queued.removeAll() }
	func send(_ bytes: Data, source: NetworkEndpoint, destination: NetworkEndpoint) {
		guard !blackhole, let packet = try? UTPPacket(bytes), queued.count < 512 else { drops += 1; return }
		let identity = Identity(source: source, id: packet.connection, sequence: packet.sequence, type: packet.type), first = seen.insert(identity).inserted
		var delay = 0.02
		if packet.type == .data, lastData[source] == nil || utpBefore(lastData[source]!, packet.sequence) { lastData[source] = packet.sequence }
		if packet.type == .state, lastData[source] == packet.sequence, zeroWindows.contains(destination) {
			persistProbes += 1; if droppedUpdates.contains(destination) { reopened.insert(destination) }
		}
		if packet.window == 0 { zeroWindows.insert(source) }
		if packet.type == .state, packet.window > 0, zeroWindows.contains(source), !reopened.contains(source) {
			droppedUpdates.insert(source); drops += 1; return
		}
		if impaired, packet.type == .syn, first { drops += 1; return }
		if impaired, packet.type == .state, initialStates.insert(source).inserted { drops += 1; return }
		if impaired, packet.type == .fin, first { drops += 1; return }
		if impaired, packet.type == .data, first {
			counts[source, default: 0] += 1; let count = counts[source]!
			if count == 4 || count == 17 { drops += 1; return }
			if count % 5 == 0 { delay = 0.16; reorders += 1 }
			if count % 7 == 0 { queued.append(Delivery(due: clock.now() + delay + 0.02, source: source, destination: destination, bytes: bytes)); duplicates += 1 }
		}
		queued.append(Delivery(due: clock.now() + delay, source: source, destination: destination, bytes: bytes))
	}
	func advance() async {
		clock.advance(0.02)
		let ready = queued.filter { $0.due <= clock.now() }.sorted { $0.due < $1.due }; queued.removeAll { $0.due <= clock.now() }
		for item in ready { await ports[item.destination]?.inject(NetworkDatagram(source: item.source, payload: item.bytes)) }
	}
}

final class UTPLinkFixture: Sendable {
	let clock = ManualTransportClock()
	let link: UTPImpairedLink
	let aPort: UTPLinkPort, bPort: UTPLinkPort
	let aUDP: UDPDispatcher, bUDP: UDPDispatcher
	let a: UTPTransport, b: UTPTransport
	let driver: Task<Void, Never>
	init(impaired: Bool) async throws {
		link = UTPImpairedLink(clock: clock, impaired: impaired)
		aPort = UTPLinkPort(endpoint: try NetworkEndpoint("127.0.0.1", port: 30001), link: link); bPort = UTPLinkPort(endpoint: try NetworkEndpoint("127.0.0.1", port: 30002), link: link)
		await link.add(aPort); await link.add(bPort)
		aUDP = UDPDispatcher(transport: aPort, clock: clock); bUDP = UDPDispatcher(transport: bPort, clock: clock)
		a = try await UTPTransport.open(dispatcher: aUDP, clock: clock); b = try await UTPTransport.open(dispatcher: bUDP, clock: clock)
		let link = link
		driver = Task { do { while !Task.isCancelled { await link.advance(); try await Task.sleep(for: .milliseconds(1)) } } catch {} }
	}
	func pair() async throws -> (UTPStream, UTPStream) {
		let connect = Task { try await a.connect(to: bPort.localEndpoint, timeout: 20) }
		let server = try await b.accept(timeout: 20); return (try await connect.value, server)
	}
	func close() async { driver.cancel(); await driver.value; await a.shutdown(); await b.shutdown(); try? await aUDP.shutdown(); try? await bUDP.shutdown() }
}
