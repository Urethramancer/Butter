import Foundation
import Darwin
import Testing
@testable import ButterTorrentNetworking

actor InjectedDatagrams: DatagramTransport {
	nonisolated let localEndpoint: NetworkEndpoint
	nonisolated let datagrams: AsyncStream<NetworkDatagram>
	private let continuation: AsyncStream<NetworkDatagram>.Continuation
	let sent = AsyncStream<(Data, NetworkEndpoint)>.makeStream()
	private var closed = false
	private(set) var sentCount = 0
	init(endpoint: NetworkEndpoint? = nil) throws {
		localEndpoint = try endpoint ?? NetworkEndpoint("127.0.0.1", port: 12345)
		let pair = AsyncStream<NetworkDatagram>.makeStream(bufferingPolicy: .bufferingNewest(256))
		datagrams = pair.stream; continuation = pair.continuation
	}
	func send(_ data: Data, to endpoint: NetworkEndpoint) async throws {
		try Task.checkCancellation()
		guard !closed else { throw NetworkFailure.closed }
		sentCount += 1
		sent.continuation.yield((data, endpoint))
	}
	func inject(_ data: Data, source: NetworkEndpoint) { continuation.yield(NetworkDatagram(source: source, payload: data)) }
	func nextSent() async throws -> (Data, NetworkEndpoint) {
		try await deadline { for await packet in self.sent.stream { return packet }; throw NetworkFailure.closed }
	}
	func shutdown() async throws { closed = true; continuation.finish(); sent.continuation.finish() }
}

@Suite struct UDPTransportTests {
	@Test(arguments: ["0.0.0.0", "::"]) func sharedPortsInteroperateWithBSDMulticastSocketOptions(_ host: String) async throws {
		let owner = try DatagramSocket(bind: NetworkEndpoint(host, port: 0), reusePort: true)
		let fd = socket(owner.localEndpoint.address.isIPv6 ? AF_INET6 : AF_INET, SOCK_DGRAM, IPPROTO_UDP)
		guard fd >= 0 else { try await owner.shutdown(); throw NetworkFailure.system(errno) }
		defer { Darwin.close(fd) }
		do {
			var yes: Int32 = 1
			for option in [SO_REUSEADDR, SO_REUSEPORT] {
				try #require(setsockopt(fd, SOL_SOCKET, option, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0)
			}
			if owner.localEndpoint.address.isIPv6 { try #require(setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size)) == 0) }
			#expect(owner.localEndpoint.withSockAddr { Darwin.bind(fd, $0, $1) } == 0)
			try await owner.shutdown()
		} catch { try? await owner.shutdown(); throw error }
	}
	@Test func loopbackIPv4AndIPv6Datagrams() async throws {
		for host in ["127.0.0.1", "::1"] {
			let a = try DatagramSocket(bind: NetworkEndpoint(host, port: 0)), b = try DatagramSocket(bind: NetworkEndpoint(host, port: 0))
			try await a.send(Data([0, 255, 42]), to: b.localEndpoint)
			let received = try await deadline { for await packet in b.datagrams { return packet }; throw NetworkFailure.closed }
			#expect(received.source == a.localEndpoint && received.payload == Data([0, 255, 42]))
			try await a.shutdown(); try await b.shutdown()
		}
	}
	@Test func transactionSourceFilteringCancellationAndTimeout() async throws {
		let transport = try InjectedDatagrams(), clock = ManualTransportClock()
		let dispatcher = UDPDispatcher(transport: transport, clock: clock)
		let peer = try NetworkEndpoint("127.0.0.1", port: 6969), wrong = try NetworkEndpoint("127.0.0.1", port: 6970)
		let task = Task { try await dispatcher.exchange(Data([42]), with: peer, reply: .tracker(7), timeout: 15) }
		try await clock.waitForSleep(15)
		var reply = Data(); PacketBytes.append(UInt32(0), to: &reply); PacketBytes.append(UInt32(7), to: &reply)
		await transport.inject(reply, source: wrong)
		await transport.inject(reply, source: peer)
		#expect(try await task.value.source == peer)
		let expired = Task { try await dispatcher.exchange(Data([42]), with: peer, reply: .tracker(8), timeout: 16) }
		try await clock.waitForSleep(16); clock.advance(16)
		do { _ = try await expired.value; Issue.record("UDP deadline ignored") } catch { #expect(error as? NetworkFailure == .timedOut) }
		let cancelled = Task { try await dispatcher.exchange(Data([42]), with: peer, reply: .tracker(9), timeout: 17) }
		try await clock.waitForSleep(17); cancelled.cancel()
		do { _ = try await cancelled.value; Issue.record("UDP cancellation ignored") } catch { #expect(error is CancellationError) }
		#expect(await dispatcher.pendingCount == 0)
		try await dispatcher.shutdown()
	}
	@Test func routesDHTAndUTPOnOneSocket() async throws {
		let transport = try InjectedDatagrams(), dispatcher = UDPDispatcher(transport: transport)
		let dht = try await dispatcher.subscribe(.dht), utp = try await dispatcher.subscribe(.utp)
		let peer = try NetworkEndpoint("127.0.0.1", port: 6969)
		let dhtData = Data("d1:t2:ab1:y1:re".utf8), utpData = Data([0x41]) + Data(repeating: 0, count: 19)
		await transport.inject(utpData, source: peer); await transport.inject(dhtData, source: peer)
		let a = try await deadline { for await packet in dht { return packet.payload }; throw NetworkFailure.closed }
		let b = try await deadline { for await packet in utp { return packet.payload }; throw NetworkFailure.closed }
		#expect(a == dhtData && b == utpData)
		try await dispatcher.shutdown()
	}
	@Test func ownsOnePortAndRollsBackFailedUDPBind() async throws {
		let occupied = try DatagramSocket(bind: NetworkEndpoint("0.0.0.0", port: 0))
		do { let owner = try await ListeningPort.bind(port: occupied.localEndpoint.port); try await owner.shutdown(); Issue.record("Occupied UDP port accepted") }
		catch { #expect(error as? NetworkFailure == .system(EADDRINUSE)) }
		let recovered = try await TCPListener.listen(port: occupied.localEndpoint.port)
		try await recovered.shutdown(); try await occupied.shutdown()
		let owner = try await ListeningPort.bind(loopbackOnly: true)
		let port = owner.port
		#expect(owner.port > 0 && owner.udp4.localEndpoint.port == owner.port && owner.udp6.localEndpoint.port == owner.port)
		for host in ["127.0.0.1", "::1"] {
			let client = try await TCPStream.connect(to: NetworkEndpoint(host, port: owner.port))
			let peer = try await owner.tcp.accept(timeout: 3); peer.close(); client.close()
		}
		try await withThrowingTaskGroup(of: Void.self) { group in
			for _ in 0..<8 { group.addTask { try await owner.shutdown() } }
			try await group.waitForAll()
		}
		let rebound = try await ListeningPort.bind(port: port, loopbackOnly: true)
		try await rebound.shutdown()
	}
}
