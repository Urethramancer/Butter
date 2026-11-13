import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentEngine

private final class BudgetPeerStream: PeerByteStream, Sendable {
	var remoteEndpoint: NetworkEndpoint? { nil }
	let kind: PeerTransportKind
	init(kind: PeerTransportKind = .tcp) { self.kind = kind }
	func read(maximumBytes: Int, timeout: TimeInterval) async throws -> Data { throw NetworkFailure.closed }
	func write(_ data: Data, timeout: TimeInterval) async throws { throw NetworkFailure.closed }
	func close() {}
}

@Suite struct PeerOutputBudgetTests {
	@Test(arguments: [0, 1, 8, 17, 32], [false, true]) func readyRequestBurstsKeepWireOrderAndMessageBounds(_ count: Int, _ utp: Bool) throws {
		let session = PeerSession(stream: BudgetPeerStream(kind: utp ? .utp : .tcp))
		defer { session.close() }
		let blocks = (0..<count).map { PeerBlock(piece: $0 == count - 1 ? Int(UInt32.max) : $0, offset: $0 * 16384, length: 16384) }
		try session.send(.interested); try session.sendRequests(blocks); try session.send(.choke)
		var frames: [PeerSession.Outbound] = []
		while true {
			let batch = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
			if batch.isEmpty { break }; #expect(batch.count <= 16); frames += batch
		}
		let expected = [try PeerMessage.interested.encoded()] + (try blocks.map { try PeerMessage.request($0).encoded() }) + [try PeerMessage.choke.encoded()]
		#expect(frames.map(\.bytes) == expected)
		#expect(frames.allSatisfy { $0.payload == 0 && $0.token == nil && $0.block == nil })
		#expect(PeerSession.outputBytes(frames) == expected.reduce(into: Data()) { $0.append($1) })
		let requests = Array(frames.dropFirst().dropLast())
		if count > 1 && !utp {
			#expect(requests.allSatisfy { $0.buffer != nil && $0.buffer === requests.first?.buffer })
		} else { #expect(requests.allSatisfy { $0.buffer == nil }) }
	}
	@Test func requestBurstsKeepReservationAndMessageAdmissionAtomic() throws {
		let session = PeerSession(stream: BudgetPeerStream()), token = UUID()
		defer { session.close() }
		let blocks = (0..<8).map { PeerBlock(piece: 0, offset: $0 * 16384, length: 16384) }
		#expect(session.register(token, bytes: 14))
		for _ in 0..<15 { try session.sendRequests(blocks) }
		#expect(throws: PeerFailure.limit("peer output messages")) { try session.sendRequests(blocks) }
		#expect(session.takeOutgoing(maximumCount: 128, maximumBytes: 262144).count == 120)
		#expect(session.cancel(token))
		for _ in 0..<16 { try session.sendRequests(blocks) }
		#expect(throws: PeerFailure.limit("peer output messages")) { try session.send(.keepAlive) }
		#expect(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144).count == 16)
		try session.sendRequests(blocks)
		#expect(session.takeOutgoing(maximumCount: 128, maximumBytes: 262144).count == 120)
	}
	@Test func requestBurstsKeepByteReservationsAndClosure() throws {
		let session = PeerSession(stream: BudgetPeerStream()), token = UUID()
		defer { session.close() }
		let blocks = Array(repeating: PeerBlock(piece: 0, offset: 0, length: 16384), count: 8)
		#expect(session.register(token, bytes: PeerSession.outputByteLimit - 135))
		#expect(throws: PeerFailure.limit("peer output bytes")) { try session.sendRequests(blocks) }
		#expect(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144).isEmpty)
		#expect(session.cancel(token)); try session.sendRequests(blocks)
		let frames = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(frames.count == 8)
		session.close(); #expect(session.claimOutgoing(frames).isEmpty)
		#expect(throws: PeerFailure.closed) { try session.sendRequests(blocks) }
	}
	@Test(arguments: [PeerBlock(piece: -1, offset: 0, length: 1), PeerBlock(piece: 0, offset: -1, length: 1),
		PeerBlock(piece: Int.max, offset: 0, length: 1), PeerBlock(piece: 0, offset: Int.max, length: 1),
		PeerBlock(piece: 0, offset: 0, length: 0), PeerBlock(piece: 0, offset: 0, length: 16385)])
	func requestBurstsRejectMalformedFramesBeforePublishingAny(_ invalid: PeerBlock) throws {
		let session = PeerSession(stream: BudgetPeerStream())
		defer { session.close() }
		let valid = PeerBlock(piece: 0, offset: 0, length: 1)
		#expect(throws: PeerFailure.self) { try session.sendRequests([valid, invalid]) }
		#expect(throws: PeerFailure.limit("peer request batch messages")) { try session.sendRequests(Array(repeating: valid, count: 33)) }
		#expect(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144).isEmpty)
	}
	@Test func availableOutputKeepsFrameOrderAndFlushesShortBatches() throws {
		let session = PeerSession(stream: BudgetPeerStream())
		defer { session.close() }
		try session.send(.interested); try session.send(.keepAlive); try session.send(.choke)
		let first = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(first.map(\.bytes) == [try PeerMessage.interested.encoded(), try PeerMessage.keepAlive.encoded(), try PeerMessage.choke.encoded()])
		#expect(first.allSatisfy { $0.buffer == nil })
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
	@Test(arguments: [0, 7, 14], [false, true]) func batchedOutputBoundsBytesAndSkipsCancelledPayloadWithoutLosingControls(_ cancelled: Int, _ grouped: Bool) throws {
		let session = PeerSession(stream: BudgetPeerStream()), tokens = (0..<31).map { _ in UUID() }
		defer { session.close() }
		var piece = Data(), requests: [(token: UUID, block: PeerBlock)] = []
		for (index, token) in tokens.enumerated() {
			#expect(session.register(token, bytes: 16397))
			let bytes = Data(repeating: UInt8(index), count: 16384)
			piece.append(bytes)
			requests.append((token, PeerBlock(piece: 0, offset: index * 16384, length: 16384)))
			if !grouped { try session.send(.piece(0, index * 16384, bytes), token: token) }
		}
		if grouped { try session.sendPieces(requests, piece: piece) }
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
		#expect(PeerSession.outputBytes(claimed) == expected.reduce(into: Data()) { $0.append($1) })
		#expect(session.register(UUID(), bytes: 16397))
		let second = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(second.count == 15)
		let last = session.takeOutgoing(maximumCount: 16, maximumBytes: 262144)
		#expect(last.count == 2); #expect(last.last?.bytes == (try PeerMessage.choke.encoded()))
		#expect(session.claimOutgoing(last).count == 2)
	}
	@Test func groupedOutputHandlesSlicesShortGroupsAndMixedControls() throws {
		let session = PeerSession(stream: BudgetPeerStream())
		defer { session.close() }
		let original = Data((0..<80).map(UInt8.init)), piece = original[16..<64]
		let blocks = [PeerBlock(piece: 2, offset: 0, length: 1), PeerBlock(piece: 2, offset: 1, length: 7)]
		let requests = blocks.map { (token: UUID(), block: $0) }
		for request in requests { #expect(session.register(request.token, bytes: request.block.length + 13)) }
		try session.sendPieces(requests, piece: piece)
		let frames = session.claimOutgoing(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144))
		#expect(frames.count == 2 && frames[0].buffer != nil && frames[0].buffer === frames[1].buffer)
		var expected = Data()
		for block in blocks {
			expected.append(try PeerMessage.piece(2, block.offset, piece[(piece.startIndex + block.offset)..<(piece.startIndex + block.offset + block.length)]).encoded())
		}
		#expect(PeerSession.outputBytes(frames) == expected)
		try session.send(.choke)
		let control = session.claimOutgoing(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144))
		expected.append(try PeerMessage.choke.encoded())
		#expect(PeerSession.outputBytes(frames + control) == expected)
		#expect(PeerSession.outputBytes([]).isEmpty)
	}
	@Test(arguments: [PeerBlock(piece: 0, offset: -1, length: 1), PeerBlock(piece: 0, offset: Int.max, length: 1),
		PeerBlock(piece: 0, offset: 0, length: 0), PeerBlock(piece: 0, offset: 0, length: 16385),
		PeerBlock(piece: 0, offset: 16, length: 1), PeerBlock(piece: -1, offset: 0, length: 1)])
	func groupedOutputRejectsInvalidRangesWithoutPublishingFrames(_ block: PeerBlock) throws {
		let session = PeerSession(stream: BudgetPeerStream()), token = UUID()
		defer { session.close() }
		#expect(session.register(token, bytes: max(1, block.length + 13)))
		#expect(throws: PeerFailure.self) { try session.sendPieces([(token, block)], piece: Data(count: 16)) }
		#expect(session.takeOutgoing(maximumCount: 16, maximumBytes: 262144).isEmpty)
		#expect(session.cancel(token))
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
