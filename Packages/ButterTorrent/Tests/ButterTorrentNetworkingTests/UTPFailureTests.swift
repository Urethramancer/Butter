import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct UTPFailureTests {
	@Test func gracefulEOFRemainsReadableAfterProtocolStateRetires() async throws {
		let fixture = try await UTPLinkFixture(impaired: false)
		do {
			let (client, server) = try await fixture.pair()
			async let clientFin = client.finish(timeout: 20), serverFin = server.finish(timeout: 20)
			try await clientFin; try await serverFin
			try await deadline {
				while true { let a = await fixture.a.snapshot(), b = await fixture.b.snapshot(); if a.connections == 0 && b.connections == 0 { return }; try await Task.sleep(for: .milliseconds(1)) }
			}
			let retirement = fixture.clock.now() + 6
			try await deadline { while fixture.clock.now() < retirement { try await Task.sleep(for: .milliseconds(1)) } }
			let a = try await client.read(), b = try await server.read(); #expect(a.isEmpty && b.isEmpty)
			try await client.shutdown(); try await server.shutdown()
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func aggregateWriteAdmissionBoundsRetainedDataAndPacketCopies() async throws {
		let fixture = try await UTPLinkFixture(impaired: false)
		var clients: [UTPStream] = [], servers: [UTPStream] = [], writes: [Task<Void, Error>] = []
		do {
			for _ in 0..<9 { let pair = try await fixture.pair(); clients.append(pair.0); servers.append(pair.1) }
			let bytes = Data(repeating: 71, count: 1_048_576)
			for client in clients.prefix(8) { writes.append(Task { try await client.write(bytes, timeout: 120) }) }
			try await deadline { while await fixture.a.snapshot().outgoingBytes < 8_388_608 { try await Task.sleep(for: .milliseconds(1)) } }
			await #expect(throws: NetworkFailure.backpressure) { try await clients[8].write(bytes) }
			#expect(await fixture.a.snapshot().outgoingBytes <= 16_777_216)
			for task in writes { task.cancel() }; for task in writes { _ = try? await task.value }
			#expect(await fixture.a.snapshot().outgoingBytes == 0)
		} catch { for task in writes { task.cancel(); _ = try? await task.value }; for stream in clients + servers { stream.close() }; await fixture.close(); throw error }
		for stream in clients + servers { stream.close() }; await fixture.close()
	}
	@Test func deterministicLossDelayDuplicationAndReorderingPreserveBytes() async throws {
		let fixture = try await UTPLinkFixture(impaired: true)
		do {
			let (client, server) = try await fixture.pair(), bytes = Data((0..<100_003).map { UInt8($0 % 251) })
			async let write = client.write(bytes, timeout: 60), read = utpRead(server, count: bytes.count)
			#expect(try await read == bytes); try await write
			#expect(await fixture.a.snapshot().retransmissions > 0)
			let drops = await fixture.link.drops, duplicates = await fixture.link.duplicates, reorders = await fixture.link.reorders
			#expect(drops >= 3 && duplicates > 0 && reorders > 0)
			async let finishing = client.finish(timeout: 20)
			#expect(try await server.read(timeout: 20).isEmpty); try await finishing
			try await client.shutdown(); try await server.shutdown()
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func receiveWindowBoundsAndLostWindowUpdateRecover() async throws {
		let fixture = try await UTPLinkFixture(impaired: false)
		do {
			let (client, server) = try await fixture.pair(), bytes = Data(repeating: 71, count: 600_003)
			let writing = Task { try await client.write(bytes, timeout: 120) }
			try await deadline { while await fixture.b.snapshot().incomingBytes < 262_144 { try await Task.sleep(for: .milliseconds(1)) } }
			#expect(await fixture.b.snapshot().incomingBytes == 262_144)
			#expect(await fixture.a.snapshot().outgoingBytes <= bytes.count + 262_144)
			let received = try await utpRead(server, count: bytes.count); try await writing.value
			#expect(received == bytes)
			#expect(await fixture.link.droppedUpdates.contains(fixture.bPort.localEndpoint))
			#expect(await fixture.link.persistProbes > 0)
			try await client.shutdown(); try await server.shutdown()
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test(arguments: [false, true]) func blackholeTimeoutOrCancellationDrainBufferedWork(_ cancel: Bool) async throws {
		let fixture = try await UTPLinkFixture(impaired: false)
		do {
			let (client, server) = try await fixture.pair()
			await fixture.link.setBlackhole()
			let reading = Task { try await client.read(timeout: 30) }, writing = Task { try await client.write(Data(repeating: 7, count: 1_000_000), timeout: 3) }
			try await deadline { while await fixture.a.snapshot().outgoingBytes == 0 { try await Task.sleep(for: .milliseconds(1)) } }
			if cancel { writing.cancel(); await #expect(throws: CancellationError.self) { try await writing.value } }
			else { await #expect(throws: NetworkFailure.timedOut) { try await writing.value } }
			await #expect(throws: (any Error).self) { try await reading.value }
			#expect(await fixture.a.snapshot().connections == 0)
			#expect(await fixture.a.snapshot().outgoingBytes == 0)
			try await server.shutdown()
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
}
