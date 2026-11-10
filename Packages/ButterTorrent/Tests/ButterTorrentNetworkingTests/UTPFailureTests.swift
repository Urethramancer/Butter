import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct UTPFailureTests {
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
