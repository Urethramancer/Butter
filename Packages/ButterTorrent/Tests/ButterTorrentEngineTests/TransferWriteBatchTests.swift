import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite struct TransferWriteBatchTests {
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
