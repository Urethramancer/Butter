import Foundation
import Testing
import ButterTorrentNetworking
@testable import ButterTorrentEngine

@Suite struct TCPTransferTests {
	@Test func realBidirectionalTransferAndSelectiveBoundaryStorage() async throws {
		try await transferFixture { fixture in
			let seed = try await fixture.transfer("seed", seed: true), full = try await fixture.transfer("full")
			try await fixture.join(full, seed)
			try await eventually { await full.snapshot().complete }
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("full/bundle/skip")) == fixture.bytes.subdata(in: 10003..<60022))
			let partial = try await fixture.transfer("partial", selected: [true, false, false, false])
			try await fixture.join(partial, full)
			try await eventually { await partial.snapshot().complete }
			let snapshot = await partial.snapshot()
			#expect(snapshot.verifiedPieces == [0] && snapshot.downloaded == 32768)
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("partial/bundle/a")) == fixture.bytes.prefix(10003))
			#expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("partial/bundle/skip").path))
			#expect(await full.snapshot().uploaded == 32768)
		}
	}
	@Test func endgameCancelsDuplicatesAndDisconnectCompletes() async throws {
		try await transferFixture { fixture in
			var config = TCPTransferConfiguration(); config.pipeline = 32
			let engine = try await fixture.transfer("download", configuration: config)
			let first = try await fixture.scripted(engine, identity: 11), second = try await fixture.scripted(engine, identity: 12)
			try await first.seed(pieceCount: 3); let requests = try await first.requests(6)
			try await second.seed(pieceCount: 3); let duplicates = try await second.requests(6)
			#expect(requests == duplicates)
			try await first.reply(requests[0], bytes: fixture.bytes)
			var canceled: PeerBlock?
			while canceled == nil { if case .cancel(let block) = try await second.next() { canceled = block } }
			#expect(canceled == requests[0]); second.stream.close()
			for block in requests.dropFirst() { try await first.reply(block, bytes: fixture.bytes) }
			try await eventually { await engine.snapshot().complete }
		}
	}
	@Test func corruptPeerIsDroppedAndGoodPeerRecovers() async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download"), bad = try await fixture.scripted(engine, identity: 13)
			try await bad.seed(pieceCount: 3)
			let requests = try await bad.requests(6)
			for block in requests.filter({ $0.piece == 0 }) { try await bad.reply(block, bytes: fixture.bytes, corrupt: block.offset == 0) }
			try await eventually { await engine.snapshot().corruptPieces == 1 }
			#expect(await engine.snapshot().verifiedPieces.isEmpty)
			let good = try await fixture.transfer("seed", seed: true); try await fixture.join(engine, good)
			try await eventually { await engine.snapshot().complete }
			#expect(await engine.snapshot().storageError == nil)
		}
	}
	@Test func chokeAndLateBlockDoNotPoisonRecovery() async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download"), stalled = try await fixture.scripted(engine, identity: 14)
			try await stalled.seed(pieceCount: 3); let requests = try await stalled.requests(6)
			try await stalled.send(.choke)
			try await stalled.reply(requests[0], bytes: fixture.bytes)
			let seed = try await fixture.transfer("seed", seed: true); try await fixture.join(engine, seed)
			try await eventually { await engine.snapshot().complete }
			#expect(await engine.snapshot().corruptPieces == 0)
		}
	}
	@Test func malformedPeersAreClosedWithoutStorageProgress() async throws {
		try await transferFixture { fixture in
			let engine = try await fixture.transfer("download")
			let frames = [Data([0, 1, 0, 1]), try PeerMessage.bitfield(Data([255])).encoded(), try PeerMessage.have(99).encoded(), try PeerMessage.piece(0, 0, Data([42])).encoded()]
			for (index, frame) in frames.enumerated() {
				let peer = try await fixture.scripted(engine, identity: UInt8(20 + index))
				try await peer.stream.write(frame)
				try await eventually { await engine.snapshot().peers.isEmpty }
			}
			#expect(await engine.snapshot().verifiedPieces.isEmpty)
			#expect(await engine.snapshot().storageError == nil)
		}
	}
	@Test func concurrentShutdownCancelsRateLimitedUploads() async throws {
		try await transferFixture { fixture in
			var config = TCPTransferConfiguration(); config.uploadLimit = 1024
			let seed = try await fixture.transfer("seed", seed: true, configuration: config), download = try await fixture.transfer("download")
			try await fixture.join(download, seed)
			try await eventually { await download.snapshot().peers.contains { $0.pendingRequests > 0 } }
			try await withThrowingTaskGroup(of: Void.self) { group in
				for _ in 0..<6 { group.addTask { try await seed.shutdown(); try await download.shutdown() } }
				try await group.waitForAll()
			}
			let seedStopped = await seed.snapshot().stopped, downloadStopped = await download.snapshot().stopped
			#expect(seedStopped && downloadStopped)
		}
	}
}
