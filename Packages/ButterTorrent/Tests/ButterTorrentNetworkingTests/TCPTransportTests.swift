import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct TCPTransportTests {
	@Test func addressesAndResolution() async throws {
		#expect(try IPAddress("::ffff:127.0.0.1") == IPAddress("127.0.0.1"))
		#expect(try IPAddress("::1").isLoopback)
		#expect(try IPAddress("100.64.0.1").isLocal)
		#expect(try IPAddress("64:ff9b::7f00:1").isLoopback)
		#expect(try IPAddress("fec0::1").isLocal)
		let addresses = try await SystemAddressResolver().resolve(host: "localhost", port: 1234, timeout: 3)
		#expect(!addresses.isEmpty && addresses.allSatisfy { $0.port == 1234 && $0.address.isLoopback })
		#expect(try NetworkEnvironment.interfaces(includeLoopback: true).contains { $0.address.isLoopback })
		#expect(try NetworkEnvironment.sourceAddress(for: NetworkEndpoint("127.0.0.1", port: 9)).isLoopback)
		for text in ["", "localhost", "127.0.0.256", "::1%0"] { #expect(throws: NetworkFailure.self) { try IPAddress(text) } }
	}
	@Test func ipv4AndIPv6RoundTripAndCancellation() async throws {
		for address in ["127.0.0.1", "::1"] {
			let clock = ManualTransportClock()
			let ip = try IPAddress(address), listener = try await TCPListener.listen(address: IPAddress(address), maximumPeers: 1)
			let client = try await TCPStream.connect(to: NetworkEndpoint(address: ip, port: listener.port), clock: clock)
			let server = try await listener.accept(timeout: 3)
			try await client.write(Data("fragment".utf8))
			#expect(try await server.read(maximumBytes: 3) == Data("fra".utf8))
			#expect(try await server.read() == Data("gment".utf8))
			try await server.write(Data([0, 255]))
			#expect(try await client.read() == Data([0, 255]))
			let blocked = Task { try await client.read(timeout: 7) }
			try await clock.waitForSleep(7); blocked.cancel()
			do { _ = try await blocked.value; Issue.record("Cancelled read succeeded") } catch { #expect(error is CancellationError) }
			#expect(client.isClosed)
			server.close(); try await listener.shutdown()
		}
	}
	@Test(arguments: ["127.0.0.1", "::1"]) func repeatedEphemeralConnectionsReleaseTheirPortsAndBudget(_ host: String) async throws {
		for _ in 0..<256 {
			let budget = TCPPeerBudget(limit: 2)
			let listener = try await TCPListener.listen(address: IPAddress(host), maximumPeers: 1, budget: budget)
			do {
				let client = try await TCPStream.connect(to: NetworkEndpoint(host, port: listener.port), timeout: 3, budget: budget)
				defer { client.close() }
				let peer = try await listener.accept(timeout: 3); defer { peer.close() }
				#expect(budget.count == 2)
				try await client.write(Data([42]), timeout: 3)
				#expect(try await peer.read(maximumBytes: 1, timeout: 3) == Data([42]))
				client.close(); peer.close()
				#expect(budget.count == 0)
				try await listener.shutdown()
			} catch { try? await listener.shutdown(); throw error }
		}
	}
	@Test func occupiedPortTimeoutAndPeerLimit() async throws {
		let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"), maximumPeers: 1)
		do { let other = try await TCPListener.listen(port: listener.port, address: IPAddress("127.0.0.1")); other.close(); Issue.record("Occupied port rebound") } catch { }
		let client = try await TCPStream.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port))
		let peer = try await listener.accept(timeout: 3)
		let extra = try await TCPStream.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port))
		do { _ = try await listener.accept(timeout: 0.1); Issue.record("Peer limit exceeded") }
		catch { #expect(error as? NetworkFailure == .timedOut) }
		#expect(listener.peerCount == 1)
		do { _ = try await peer.read(timeout: 0.1); Issue.record("Read deadline ignored") }
		catch { #expect(error as? NetworkFailure == .timedOut) }
		#expect(peer.isClosed)
		client.close(); extra.close(); try await listener.shutdown()
	}
	@Test func incomingAndOutgoingShareOneBudget() async throws {
		let budget = TCPPeerBudget(limit: 2)
		let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"), budget: budget)
		let endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port)
		let client = try await TCPStream.connect(to: endpoint, budget: budget)
		let peer = try await listener.accept(timeout: 3)
		#expect(budget.count == 2)
		do { let extra = try await TCPStream.connect(to: endpoint, budget: budget); extra.close(); Issue.record("Shared peer budget exceeded") }
		catch { #expect(error as? NetworkFailure == .limit("peer connections")) }
		client.close(); peer.close()
		#expect(budget.count == 0)
		try await listener.shutdown()
	}
	@Test func rejectedOverlappingReadDoesNotDisturbItsOwner() async throws {
		let clock = ManualTransportClock(), listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"), maximumPeers: 1)
		defer { listener.close() }
		let client = try await TCPStream.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port), clock: clock)
		let server = try await listener.accept(timeout: 3)
		defer { client.close(); server.close() }
		let first = Task { try await client.read(timeout: 7) }
		try await clock.waitForSleep(7)
		await #expect(throws: NetworkFailure.busy) { try await client.read(timeout: 3) }
		#expect(!client.isClosed)
		try await server.write(Data([42]))
		#expect(try await first.value == Data([42]))
		let second = Task { try await client.read(timeout: 3) }
		try await clock.waitForSleep(3)
		first.cancel()
		#expect(!client.isClosed)
		try await server.write(Data([43]))
		#expect(try await second.value == Data([43]))
		client.close(); server.close(); try await listener.shutdown()
	}
	@Test func readCompletionCancellationAndCloseRaceReleasesTheBudget() async throws {
		let budget = TCPPeerBudget(limit: 2)
		let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"), maximumPeers: 1, budget: budget)
		defer { listener.close() }
		for _ in 0..<64 {
			let clock = ManualTransportClock()
			let client = try await TCPStream.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port), clock: clock, budget: budget)
			let server = try await listener.accept(timeout: 3)
			let reading = Task { try await client.read(timeout: 1) }
			try await clock.waitForSleep(1)
			await withTaskGroup(of: Void.self) { group in
				group.addTask { reading.cancel() }
				group.addTask { try? await server.write(Data([42])) }
				group.addTask { client.close() }
			}
			do { #expect(try await reading.value == Data([42])) }
			catch { #expect(error is CancellationError || error as? NetworkFailure == .closed) }
			client.close(); server.close()
			try await deadline {
				while budget.count != 0 { try await Task.sleep(for: .milliseconds(1)) }
			}
		}
		try await listener.shutdown()
	}
}
