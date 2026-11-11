import Foundation
import Testing
@testable import ButterTorrentStorage
@testable import ButterTorrentEngine

private func existingUnverifiedTransfer(_ fixture: TransferFixture) async throws -> TCPTransfer {
	let storage = try await TorrentStorage.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("download-state"))
	try await storage.importFiles(from: fixture.root.appendingPathComponent("source")); try await storage.shutdown()
	return try await fixture.transfer("download")
}

@Suite struct LocalRecoveryTests {
	@Test func existingUncheckpointedPiecesCompleteWithoutNetworkPayload() async throws {
		try await transferFixture { fixture in
			let down = try await existingUnverifiedTransfer(fixture), peer = try await fixture.scripted(down)
			#expect(await down.snapshot().verifiedPieces.isEmpty)
			try await peer.seed(pieceCount: 3)
			try await engineDeadline { try await down.waitUntilComplete() }
			#expect(await down.snapshot().downloaded == 0)
			#expect(await down.snapshot().verifiedPieces == [0, 1, 2])
			peer.stream.close()
		}
	}
	@Test func corruptLocalPieceIsRequestedAndOtherPiecesAreReused() async throws {
		try await transferFixture { fixture in
			let down = try await existingUnverifiedTransfer(fixture)
			let file = try FileHandle(forWritingTo: fixture.root.appendingPathComponent("download/bundle/a"))
			try file.write(contentsOf: Data([255])); try file.close()
			let peer = try await fixture.scripted(down); try await peer.seed(pieceCount: 3)
			let requests = try await peer.requests(2)
			#expect(requests.allSatisfy { $0.piece == 0 })
			for block in requests { try await peer.reply(block, bytes: fixture.bytes) }
			try await engineDeadline { try await down.waitUntilComplete() }
			let status = await down.snapshot()
			#expect(status.downloaded == 32768 && status.corruptPieces == 0 && status.corruptBytes == 0)
			peer.stream.close()
		}
	}
	@Test func shutdownCancelsAndDrainsQueuedLocalChecks() async throws {
		try await transferFixture { fixture in
			let down = try await existingUnverifiedTransfer(fixture), peer = try await fixture.scripted(down)
			let worker = await fixture.stores[0].worker, entered = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
			let blocker = Task { try await worker.run { _ in entered.continuation.yield(()); _ = release.wait(timeout: .now() + 6) } }
			defer { release.signal(); peer.stream.close() }
			try await engineDeadline { for await _ in entered.stream { return }; throw PeerFailure.closed }
			try await peer.seed(pieceCount: 3)
			try await eventually { await down.localRecoveries.count > 0 }
			let closing = Task { try await down.shutdown() }; release.signal(); try await blocker.value
			try await engineDeadline { try await closing.value }
			#expect(await down.localRecoveries.isEmpty)
			#expect(await down.snapshot().stopped)
		}
	}
}
