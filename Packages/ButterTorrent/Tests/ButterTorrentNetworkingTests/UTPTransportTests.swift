import Foundation
import Testing
@testable import ButterTorrentNetworking

func utpRead(_ stream: UTPStream, count: Int) async throws -> Data {
	var bytes = Data()
	while bytes.count < count { let chunk = try await stream.read(maximumBytes: min(65536, count - bytes.count), timeout: 5); guard !chunk.isEmpty else { throw NetworkFailure.closed }; bytes.append(chunk) }; return bytes
}

@Suite struct UTPTransportTests {
	@Test(arguments: ["127.0.0.1", "::1"]) func bidirectionalStreamsAndGracefulFIN(_ host: String) async throws {
		let aSocket = try DatagramSocket(bind: NetworkEndpoint(host, port: 0)), bSocket = try DatagramSocket(bind: NetworkEndpoint(host, port: 0))
		let aUDP = UDPDispatcher(transport: aSocket), bUDP = UDPDispatcher(transport: bSocket)
		let a = try await UTPTransport.open(dispatcher: aUDP), b = try await UTPTransport.open(dispatcher: bUDP)
		do {
			let connect = Task { try await a.connect(to: bSocket.localEndpoint) }, server = try await b.accept(timeout: 3), client = try await connect.value
			let incomingDHT = try await bUDP.subscribe(.dht)
			let response = Task {
				for await packet in incomingDHT { try await bUDP.send(Data("d1:t2:ab1:y1:re".utf8), to: packet.source); return }; throw NetworkFailure.closed
			}
			let trackerless = try await aUDP.exchange(Data("d1:t2:ab1:y1:qe".utf8), with: bSocket.localEndpoint, reply: .dht(Data("ab".utf8)), timeout: 3)
			#expect(trackerless.payload == Data("d1:t2:ab1:y1:re".utf8)); try await response.value
			let data = Data((0..<300_003).map { UInt8(($0 * 71 + $0 / 97) % 251) })
			async let first = client.write(data, timeout: 10), second = server.write(Data(data.reversed()), timeout: 10)
			async let receivedA = utpRead(client, count: data.count), receivedB = utpRead(server, count: data.count)
			let bytesA = try await receivedA, bytesB = try await receivedB
			try await first; try await second
			#expect(bytesB == data && bytesA == Data(data.reversed()))
			async let finA = client.finish(), finB = server.finish()
			#expect(try await client.read(timeout: 3).isEmpty); #expect(try await server.read(timeout: 3).isEmpty)
			try await finA; try await finB
			try await client.shutdown(); try await server.shutdown()
			#expect(await a.snapshot().connections == 0)
			await a.shutdown(); await b.shutdown()
			// The same port may still dispatch DHT packets after µTP shutdown and can get a new owner.
			let replacement = try await UTPTransport.open(dispatcher: aUDP); await replacement.shutdown()
			try await aUDP.send(Data([42]), to: bSocket.localEndpoint)
		} catch { await a.shutdown(); await b.shutdown(); try? await aUDP.shutdown(); try? await bUDP.shutdown(); throw error }
		try await aUDP.shutdown(); try await bUDP.shutdown()
	}
	@Test func hardPeerLimitCancellationAndDispatcherFailureSettleWaiters() async throws {
		let packets = try InjectedDatagrams(), clock = ManualTransportClock(), udp = UDPDispatcher(transport: packets, clock: clock)
		let budget = TCPPeerBudget(limit: 1), owner = try await UTPTransport.open(dispatcher: udp, maximumConnections: 1, budget: budget, clock: clock)
		await #expect(throws: NetworkFailure.busy) { try await UTPTransport.open(dispatcher: udp) }
		let opening = Task { try await owner.connect(to: NetworkEndpoint("127.0.0.1", port: 54321), timeout: 10) }
		_ = try await packets.nextSent()
		#expect(budget.count == 1)
		await #expect(throws: NetworkFailure.limit("µTP connections")) { try await owner.connect(to: NetworkEndpoint("127.0.0.1", port: 54322)) }
		opening.cancel(); await #expect(throws: CancellationError.self) { try await opening.value }
		let snapshot = await owner.snapshot(); #expect(budget.count == 0 && snapshot.connections == 0)
		let accepting = Task { try await owner.accept(timeout: 10) }
		try await udp.shutdown()
		await #expect(throws: NetworkFailure.closed) { try await accepting.value }
		await owner.shutdown()
	}
	@Test func spoofedSourceAndConnectionIdentifiersCannotResetAnOpening() async throws {
		let transport = try InjectedDatagrams(), udp = UDPDispatcher(transport: transport), owner = try await UTPTransport.open(dispatcher: udp)
		let endpoint = try NetworkEndpoint("127.0.0.1", port: 54321), other = try NetworkEndpoint("127.0.0.1", port: 54322)
		let opening = Task { try await owner.connect(to: endpoint) }
		let sent = try await transport.nextSent(), syn = try UTPPacket(sent.0)
		let reset = UTPPacket(type: .reset, connection: syn.connection, sequence: 1, acknowledgement: syn.sequence)
		await transport.inject(try reset.encoded(), source: other)
		let wrongID = UTPPacket(type: .reset, connection: syn.connection &+ 7, sequence: 1, acknowledgement: syn.sequence)
		await transport.inject(try wrongID.encoded(), source: endpoint)
		let valid = UTPPacket(type: .state, connection: syn.connection, sequence: 40, acknowledgement: syn.sequence)
		await transport.inject(try valid.encoded(), source: endpoint)
		let stream = try await opening.value
		#expect(await owner.snapshot().connections == 1)
		try await stream.shutdown(); await owner.shutdown(); try await udp.shutdown()
	}
}
