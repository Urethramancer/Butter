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
	@Test func availableOutputKeepsFrameOrderAndFlushesShortBatches() throws {
		let session = PeerSession(stream: BudgetPeerStream())
		defer { session.close() }
		try session.send(.interested); try session.send(.keepAlive); try session.send(.choke)
		let first = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(first.map(\.bytes) == [try PeerMessage.interested.encoded(), try PeerMessage.keepAlive.encoded(), try PeerMessage.choke.encoded()])
		#expect(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144).isEmpty)
		try session.send(.unchoke)
		let last = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(last.map(\.bytes) == [try PeerMessage.unchoke.encoded()])
		session.close(); #expect(session.claimOutgoing(last).isEmpty)
	}
	@Test func smallFramesRespectTheBatchMessageBound() throws {
		let session = PeerSession(stream: BudgetPeerStream())
		defer { session.close() }
		for _ in 0..<17 { try session.send(.keepAlive) }
		#expect(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144).count == 16)
		#expect(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144).count == 1)
	}
	@Test(arguments: [0, 7, 14]) func batchedOutputBoundsBytesAndSkipsCancelledPayloadWithoutLosingControls(_ cancelled: Int) throws {
		let session = PeerSession(stream: BudgetPeerStream()), tokens = (0..<31).map { _ in UUID() }
		defer { session.close() }
		for (index, token) in tokens.enumerated() {
			#expect(session.register(token, bytes: 16397))
			try session.send(.piece(0, index * 16384, Data(repeating: UInt8(index), count: 16384)), token: token)
		}
		try session.send(.choke)
		#expect(!session.register(UUID(), bytes: 16397))
		let first = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(first.count == 15); #expect(first.reduce(0) { $0 + $1.bytes.count } <= 262144)
		#expect(session.cancel(tokens[cancelled]))
		let claimed = session.claimOutgoing(first)
		let expected = try (0..<15).filter { $0 != cancelled }.map {
			try PeerMessage.piece(0, $0 * 16384, Data(repeating: UInt8($0), count: 16384)).encoded()
		}
		#expect(claimed.count == 14 && claimed.map(\.bytes) == expected)
		#expect(session.register(UUID(), bytes: 16397))
		let second = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(second.count == 15)
		let last = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(last.count == 2); #expect(last.last?.bytes == (try PeerMessage.choke.encoded()))
		#expect(session.claimOutgoing(last).count == 2)
	}
	@Test(arguments: [false, true]) func outputWriterWakesAfterEveryEmptyQueue(_ encrypted: Bool) async throws {
		try await transferFixture { fixture in
			var config = plainTransferConfiguration()
			if encrypted { config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4) }
			let seed = try await fixture.transfer("seed", seed: true, configuration: config)
			let peer = try await fixture.scripted(seed, encryption: encrypted ? config.encryption : nil)
			try await peer.send(.interested)
			while try await peer.next() != .unchoke {}
			for offset in 0..<32 {
				try await peer.send(.request(PeerBlock(piece: 0, offset: offset, length: 1)))
				while true {
					if case .piece(let piece, let start, let bytes) = try await peer.next() {
						#expect(piece == 0 && start == offset && bytes == fixture.bytes[offset..<(offset + 1)]); break
					}
				}
			}
			try await eventually { await seed.uploaded == 32 }
		}
	}
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
