import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentEngine

private final class BudgetPeerStream: PeerByteStream, Sendable {
	var remoteEndpoint: NetworkEndpoint? { nil }
	var kind: PeerTransportKind { .tcp }
	func read(maximumBytes: Int, timeout: TimeInterval) async throws -> Data { throw NetworkFailure.closed }
	func write(_ data: Data, timeout: TimeInterval) async throws { throw NetworkFailure.closed }
	func close() {}
}

@Suite struct PeerOutputBudgetTests {
	@Test func reservedFramingBytesPreventOverflowWhenEveryAdmittedUploadEnqueues() throws {
		let session = PeerSession(stream: BudgetPeerStream()), tokens = (0..<31).map { _ in UUID() }
		defer { session.close() }
		for token in tokens { #expect(session.register(token, bytes: 16397)) }
		#expect(!session.register(UUID(), bytes: 16397))
		let tail = UUID(), remaining = 524288 - tokens.count * 16397
		#expect(session.register(tail, bytes: remaining))
		#expect(throws: PeerFailure.limit("peer output bytes")) { try session.send(.keepAlive) }
		for token in tokens { try session.send(.piece(0, 0, Data(count: 16384)), token: token) }
		try session.send(.piece(0, 0, Data(count: remaining - 13)), token: tail)
		// Cancelling a queued frame cannot reclaim capacity until the writer drains it.
		#expect(session.cancel(tokens[0])); #expect(!session.register(UUID(), bytes: 14))
	}
	@Test func cancellingAnUnbuiltUploadReturnsItsByteCreditAndInvalidatesTheToken() throws {
		let session = PeerSession(stream: BudgetPeerStream()), token = UUID()
		defer { session.close() }
		#expect(session.register(token, bytes: 16397)); #expect(session.cancel(token)); #expect(!session.cancel(token))
		#expect(throws: PeerFailure.closed) { try session.send(.piece(0, 0, Data(count: 16384)), token: token) }
		for _ in 0..<31 { #expect(session.register(UUID(), bytes: 16397)) }
		let tail = UUID(); #expect(session.register(tail, bytes: 15981)); #expect(session.cancel(tail))
		try session.send(.keepAlive)
		session.close(); #expect(!session.register(UUID(), bytes: 14))
	}
	@Test func messageReservationsShareTheExistingBoundWithQueuedControls() throws {
		let session = PeerSession(stream: BudgetPeerStream()), token = UUID()
		defer { session.close() }
		#expect(session.register(token, bytes: 14))
		for _ in 0..<127 { try session.send(.keepAlive) }
		#expect(throws: PeerFailure.limit("peer output messages")) { try session.send(.keepAlive) }
		#expect(!session.register(UUID(), bytes: 14)); #expect(session.cancel(token))
		try session.send(.keepAlive)
		#expect(throws: PeerFailure.limit("peer output messages")) { try session.send(.keepAlive) }
	}
}
