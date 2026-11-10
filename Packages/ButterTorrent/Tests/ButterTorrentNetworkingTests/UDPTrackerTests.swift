import Foundation
import Testing
@testable import ButterTorrentNetworking

private func connectResponse(_ request: Data) throws -> Data {
	var response = Data()
	PacketBytes.append(UInt32(0), to: &response); PacketBytes.append(try PacketBytes.uint32(request, at: 12), to: &response)
	PacketBytes.append(UInt64(0x0102030405060708), to: &response)
	return response
}
private func announceResponse(_ request: Data, ipv6: Bool = false) throws -> Data {
	var response = Data()
	PacketBytes.append(UInt32(1), to: &response); PacketBytes.append(try PacketBytes.uint32(request, at: 12), to: &response)
	PacketBytes.append(UInt32(60), to: &response); PacketBytes.append(UInt32(2), to: &response); PacketBytes.append(UInt32(4), to: &response)
	response.append(try IPAddress(ipv6 ? "::1" : "127.0.0.1").bytes); PacketBytes.append(UInt16(6881), to: &response)
	return response
}

@Suite struct UDPTrackerTests {
	@Test func sharedPortAndMixedTrackerLifecycle() async throws {
		let inputs = AsyncStream<HTTPFixture.Input>.makeStream(bufferingPolicy: .bufferingNewest(4))
		let http = try await HTTPFixture.start { input in
			inputs.continuation.yield(input); return .init(status: 503)
		}
		let owner = try await ListeningPort.bind(loopbackOnly: true)
		let server = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0))
		let fixture = Task { () throws -> [UInt32] in
			var events: [UInt32] = []
			for await packet in server.datagrams {
				#expect(packet.source.port == owner.port)
				if try PacketBytes.uint32(packet.payload, at: 8) == 0 {
					try await server.send(connectResponse(packet.payload), to: packet.source)
				} else {
					#expect(try PacketBytes.uint16(packet.payload, at: 96) == owner.port)
					events.append(try PacketBytes.uint32(packet.payload, at: 80))
					try await server.send(announceResponse(packet.payload), to: packet.source)
					if events.count == 3 { return events }
				}
			}
			throw NetworkFailure.closed
		}
		do {
			let udp = try UDPTrackerClient(dispatchers: [owner.udp4, owner.udp6], timeout: 1)
			let base = trackerRequest()
			let request = TrackerRequest(infoHash: base.infoHash, peerID: base.peerID, port: owner.port, counters: base.counters)
			let urls = [http.url.appendingPathComponent("announce"), URL(string: "udp://127.0.0.1:\(server.localEndpoint.port)/announce")!]
			let announcer = try TrackerAnnouncer(tiers: [urls], request: request, client: TrackerClient(udp: udp), order: { $0 })
			_ = try await announcer.start(TrackerCounters(left: 3))
			_ = try await announcer.complete(TrackerCounters(downloaded: 3, left: 0))
			try await announcer.stop(TrackerCounters(downloaded: 3, left: 0))
			#expect(try await fixture.value == [2, 1, 3])
			#expect(await announcer.status.phase == .stopped)
			let input = try await deadline {
				for await input in inputs.stream { return input }
				throw NetworkFailure.closed
			}
			#expect(input.target.contains("event=started") && input.target.contains("port=\(owner.port)"))
		} catch {
			try? await server.shutdown(); try? await owner.shutdown(); await http.stop()
			_ = try? await fixture.value; throw error
		}
		try await server.shutdown(); try await owner.shutdown(); await http.stop()
	}
	@Test func realIPv4AndIPv6TrackerRoundTrips() async throws {
		for host in ["127.0.0.1", "::1"] {
			let server = try DatagramSocket(bind: NetworkEndpoint(host, port: 0)), socket = try DatagramSocket(bind: NetworkEndpoint(host, port: 0))
			let dispatcher = UDPDispatcher(transport: socket)
			let fixture = Task {
				for await packet in server.datagrams {
					let action = try PacketBytes.uint32(packet.payload, at: 8)
					if action == 0 {
						guard try PacketBytes.uint64(packet.payload, at: 0) == 0x41727101980 else { throw NetworkFailure.invalid("fixture protocol ID") }
						try await server.send(connectResponse(packet.payload), to: packet.source)
					} else {
						guard packet.payload.count >= 100, packet.payload[16..<36] == Data(0..<20),
							try PacketBytes.uint32(packet.payload, at: 80) == 2, packet.payload[98] == 2,
							String(data: packet.payload.dropFirst(100), encoding: .ascii) == "/announce?passkey=a%2Bb" else { throw NetworkFailure.invalid("fixture announce fields") }
						try await server.send(announceResponse(packet.payload, ipv6: host == "::1"), to: packet.source)
					}
				}
			}
			do {
				let client = try UDPTrackerClient(dispatchers: [dispatcher], timeout: 1)
				var request = trackerRequest(); request.event = .started
				let url = URL(string: "udp://\(host == "::1" ? "[::1]" : host):\(server.localEndpoint.port)/announce?passkey=a%2Bb")!
				let response = try await client.announce(to: url, request: request)
				#expect(response.peers.first?.address == host && response.complete == 4 && response.incomplete == 2)
			} catch { try? await server.shutdown(); try? await dispatcher.shutdown(); _ = try? await fixture.value; throw error }
			try await server.shutdown(); try await dispatcher.shutdown(); try await fixture.value
		}
	}
	@Test func deterministicLossRetransmissionAndConnectionExpiry() async throws {
		let transport = try InjectedDatagrams(), clock = ManualTransportClock()
		let dispatcher = UDPDispatcher(transport: transport, clock: clock)
		let client = try UDPTrackerClient(dispatchers: [dispatcher], clock: clock, transactionSeed: 100)
		let task = Task { try await client.announce(to: URL(string: "udp://127.0.0.1:6969/announce")!, request: trackerRequest()) }
		defer { task.cancel() }
		let connect = try await transport.nextSent()
		await transport.inject(try connectResponse(connect.0), source: connect.1)
		let first = try await transport.nextSent()
		try await clock.waitForSleep(15); clock.advance(15)
		let second = try await transport.nextSent()
		#expect(first.0 == second.0)
		try await clock.waitForSleep(30); clock.advance(30)
		_ = try await transport.nextSent()
		try await clock.waitForSleep(60); clock.advance(60)
		let renewed = try await transport.nextSent()
		#expect(try PacketBytes.uint32(renewed.0, at: 8) == 0)
		await transport.inject(try connectResponse(renewed.0), source: renewed.1)
		let final = try await transport.nextSent()
		await transport.inject(try announceResponse(final.0), source: final.1)
		#expect(try await task.value.interval == 60)
		try await dispatcher.shutdown()
	}
}
