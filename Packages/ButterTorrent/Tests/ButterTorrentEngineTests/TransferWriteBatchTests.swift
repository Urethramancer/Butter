import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentStorage
@testable import ButterTorrentEngine

// Collect a known fixture burst to deterministically exercise a multi-feed read.
private final class CoalescingPeerStream: PeerByteStream, @unchecked Sendable {
	let raw: TCPStream
	private let lock = NSLock()
	private var target: Int?
	private var largest = 0
	init(_ raw: TCPStream) { self.raw = raw }
	var remoteEndpoint: NetworkEndpoint? { raw.remoteEndpoint }
	var kind: PeerTransportKind { .tcp }
	var largestRead: Int { lock.withLock { largest } }
	func coalesce(_ count: Int) { lock.withLock { target = count } }
	func read(maximumBytes: Int, timeout: TimeInterval) async throws -> Data {
		var bytes = try await raw.read(maximumBytes: maximumBytes, timeout: timeout)
		let goal = lock.withLock { let count = min(target ?? bytes.count, maximumBytes); target = nil; return count }
		while bytes.count < goal {
			let next = try await raw.read(maximumBytes: goal - bytes.count, timeout: timeout)
			if next.isEmpty { break }; bytes.append(next)
		}
		lock.withLock { largest = max(largest, bytes.count) }; return bytes
	}
	func write(_ bytes: Data, timeout: TimeInterval) async throws { try await raw.write(bytes, timeout: timeout) }
	func close() { raw.close() }
}

@Suite struct TransferWriteBatchTests {
	@Test(arguments: [false, true], [false, true]) func availableReadSpansDecoderFeedsAndFlushesBeforeControl(_ encrypted: Bool, _ limited: Bool) async throws {
		try await transferFixture { fixture in
			var config = plainTransferConfiguration(); config.downloadLimit = limited ? 1048576 : 0
			if encrypted { config.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4) }
			let down = try await fixture.transfer("download", configuration: config), listener = try await fixture.listen()
			let endpoint = try NetworkEndpoint("127.0.0.1", port: listener.port), hash = fixture.metadata.hashes.v1!, encryption = config.encryption
			let connecting = Task { try await PeerStream.connect(to: endpoint, hash: hash, configuration: encryption) }
			do {
				let stream = CoalescingPeerStream(try await listener.accept(timeout: 3))
				_ = try await down.attach(stream)
				let channel = try await connecting.value; defer { channel.close() }
				let peer = WirePeer(channel: channel)
				try await peer.hello(hash: hash, identity: 42); try await peer.seed(pieceCount: 3)
				let requests = try await peer.requests(6)
				var frames = Data()
				for block in requests {
					let start = block.piece * 32768 + block.offset
					frames.append(try PeerMessage.piece(block.piece, block.offset, fixture.bytes.subdata(in: start..<(start + block.length))).encoded())
				}
				frames.append(try PeerMessage.choke.encoded()); stream.coalesce(frames.count)
				try await channel.write(frames)
				try await eventually {
					let status = await down.snapshot()
					return status.verifiedPieces == [0, 1, 2] && status.peers.first?.remoteChoking == true && status.peers.first?.pendingRequests == 0
				}
				#expect((stream.largestRead > 65536) == !limited)
				#expect(stream.largestRead <= (limited ? 65536 : 262144))
				#expect(await down.snapshot().downloaded == Int64(fixture.bytes.count))
			} catch { connecting.cancel(); if let channel = try? await connecting.value { channel.close() }; throw error }
		}
	}
	@Test func flushesAvailablePiecesBeforeProcessingAChoke() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download"), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3); let requests = try await peer.requests(6)
			var frames = Data()
			for block in requests where block.piece == 0 {
				frames.append(try PeerMessage.piece(block.piece, block.offset, fixture.bytes.subdata(in: block.offset..<(block.offset + block.length))).encoded())
			}
			frames.append(try PeerMessage.choke.encoded()); try await peer.stream.write(frames)
			try await eventually {
				let status = await down.snapshot()
				return status.verifiedPieces == [0] && status.peers.first?.remoteChoking == true && status.peers.first?.pendingRequests == 0
			}
			#expect(await down.snapshot().downloaded == 32768)
			peer.stream.close()
		}
	}
	@Test func shortAvailableBatchDoesNotWaitForAnotherFrame() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download"), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3); let block = try await peer.requests(6)[0]
			#expect(block.piece == 0 && block.offset == 0)
			try await peer.reply(block, bytes: fixture.bytes)
			let file = fixture.root.appendingPathComponent("download/bundle/a"), expected = Data(fixture.bytes.prefix(10003))
			try await eventually {
				let status = await down.snapshot()
				return status.writingBlocks == 0 && (try? Data(contentsOf: file)) == expected
			}
			#expect(await down.snapshot().downloaded == 16384)
			peer.stream.close()
		}
	}
	@Test func cancellationAbortsEveryQueuedBlockAndAccountsForLostPayloadOnce() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download"), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3)
			let requests = try await peer.requests(6).filter { $0.piece == 0 }
			let blocks = requests.map { IncomingPieceBlock(piece: $0.piece, offset: $0.offset, bytes: fixture.bytes.subdata(in: $0.offset..<($0.offset + $0.length))) }
			let id = await down.snapshot().peers[0].id
			let worker = await fixture.stores[0].worker, entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
			let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 6) } }
			defer { release.signal(); peer.stream.close() }
			try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
			let writing = Task { try await down.receivedBlocks(id, blocks: blocks) }
			try await eventually { await down.snapshot().writingBlocks == 2 }
			writing.cancel(); release.signal(); try await blocker.value
			await #expect(throws: CancellationError.self) { try await writing.value }
			#expect(await down.snapshot().writingBlocks == 0)
			#expect(await down.snapshot().redundantBytes == 32768)
			let seed = try await fixture.transfer("seed", seed: true); try await fixture.join(down, seed)
			try await engineDeadline { try await down.waitUntilComplete() }
			let status = await down.snapshot()
			#expect(status.downloaded == Int64(fixture.bytes.count) + 32768 && status.redundantBytes == 32768 && status.corruptBytes == 0)
		}
	}
	@Test func verifiesStoredBytesAndRejectsACorruptCompletedPiece() async throws {
		try await transferFixture { fixture in
			let down = try await fixture.transfer("download"), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3)
			let requests = try await peer.requests(6).filter { $0.piece == 0 }, id = await down.snapshot().peers[0].id
			let blocks = requests.map { block in
				var bytes = fixture.bytes.subdata(in: block.offset..<(block.offset + block.length))
				if block.offset == 0 { bytes[0] ^= 255 }
				return IncomingPieceBlock(piece: block.piece, offset: block.offset, bytes: bytes)
			}
			try await down.receivedBlocks(id, blocks: blocks)
			let status = await down.snapshot()
			#expect(status.verifiedPieces.isEmpty && status.corruptPieces == 1 && status.corruptBytes == 32768 && status.storageError == nil)
			peer.stream.close()
		}
	}
}
