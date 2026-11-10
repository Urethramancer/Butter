import Foundation
import Testing
@testable import ButterTorrentNetworking

@Suite struct PeerAdmissionTests {
	@Test func automaticPortSelectionSkipsAUDPPortCollisionAndDrainsItsTCPListener() async throws {
		let reserved = try await ListeningPort.bind(loopbackOnly: true), available = try await ListeningPort.bind(loopbackOnly: true)
		let candidates = PortCandidates(first: reserved.tcp, second: available.tcp)
		do {
			try await available.udp4.shutdown(); try await available.udp6.shutdown()
			let selected = try await ListeningPort.select(port: 0, loopbackOnly: true, clock: ContinuousTransportClock(), budget: available.peers, incomingTCP: true) { try await candidates.next() }
			#expect(selected.port == available.port && selected.port != reserved.port)
			#expect(await candidates.count == 2)
			await #expect(throws: NetworkFailure.closed) { try await reserved.tcp.accept(timeout: 0.1) }
			try await selected.shutdown(); try await reserved.shutdown(); try await available.shutdown()
		} catch { try? await reserved.shutdown(); try? await available.shutdown(); throw error }
	}
	@Test func filtersMergeNestedRangesAndMatchInclusiveIPv4AndIPv6Boundaries() throws {
		let ranges = try [("10.0.0.1", "10.0.0.100"), ("10.0.0.20", "10.0.0.30"), ("10.0.0.90", "10.0.0.110"), ("::1", "::2")].map {
			try PeerAddressRange(first: IPAddress($0.0), last: IPAddress($0.1))
		}
		let filter = try PeerAddressFilter(ranges: ranges)
		for host in ["10.0.0.1", "10.0.0.20", "10.0.0.70", "10.0.0.110", "::1", "::2", "::ffff:10.0.0.70"] { #expect(try !filter.allows(IPAddress(host))) }
		for host in ["0.0.0.0", "10.0.0.0", "10.0.0.111", "255.255.255.255", "::", "::3", "ffff::1"] { #expect(try filter.allows(IPAddress(host))) }
		#expect(throws: NetworkFailure.self) { try PeerAddressRange(first: IPAddress("::1"), last: IPAddress("10.0.0.1")) }
		#expect(throws: NetworkFailure.self) { try PeerAddressRange(first: IPAddress("10.0.0.2"), last: IPAddress("10.0.0.1")) }
	}
	@Test func sharedBudgetCannotShrinkBelowLiveLeases() throws {
		let budget = TCPPeerBudget(limit: 2), first = try #require(budget.acquire()), second = try #require(budget.acquire())
		#expect(throws: NetworkFailure.busy) { try budget.setLimit(1) }
		#expect(budget.limit == 2 && budget.count == 2)
		second.release(); try budget.setLimit(1); #expect(budget.acquire() == nil)
		first.release(); let replacement = try #require(budget.acquire()); replacement.release()
		#expect(throws: NetworkFailure.self) { try budget.setLimit(0) }
	}
	@Test func catalogBoundsAreCheckedBeforeNegotiation() throws {
		#expect(throws: NetworkFailure.self) { try PeerSwarmCatalog(hashes: []) }
		#expect(throws: NetworkFailure.self) { try PeerSwarmCatalog(hashes: [Data(repeating: 0, count: 19)]) }
		#expect(throws: NetworkFailure.self) { try PeerSwarmCatalog(hashes: Array(repeating: Data(repeating: 0, count: 20), count: 20_001)) }
	}
}

private actor PortCandidates {
	let first: TCPListener
	let second: TCPListener
	var count = 0
	init(first: TCPListener, second: TCPListener) { self.first = first; self.second = second }
	func next() throws -> TCPListener {
		count += 1
		guard count <= 2 else { throw NetworkFailure.invalid("unexpected port candidate") }; return count == 1 ? first : second
	}
}
