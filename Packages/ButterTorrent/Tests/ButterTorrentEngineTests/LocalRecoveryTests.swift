import Foundation
import Testing
@testable import ButterTorrentStorage
@testable import ButterTorrentEngine

private func existingUnverifiedTransfer(_ fixture: TransferFixture, corrupt: Bool = false, resources: TransferResources = .shared) async throws -> TCPTransfer {
	let storage = try await TorrentStorage.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("download"), stateDirectory: fixture.root.appendingPathComponent("download-state"))
	try await storage.importFiles(from: fixture.root.appendingPathComponent("source")); try await storage.shutdown()
	if corrupt {
		let file = try FileHandle(forWritingTo: fixture.root.appendingPathComponent("download/bundle/a"))
		try file.write(contentsOf: Data([255])); try file.close()
	}
	return try await fixture.transfer("download", resources: resources)
}

@Suite struct LocalRecoveryTests {
	@Test func existingUncheckpointedPiecesCompleteWithoutNetworkPayload() async throws {
		try await transferFixture { fixture in
			let down = try await existingUnverifiedTransfer(fixture), peer = try await fixture.scripted(down)
			try await peer.seed(pieceCount: 3)
			try await engineDeadline { try await down.waitUntilComplete() }
			#expect(await down.snapshot().downloaded == 0)
			#expect(await down.snapshot().verifiedPieces == [0, 1, 2])
			peer.stream.close()
		}
	}
	@Test func corruptLocalPieceIsRequestedAndOtherPiecesAreReused() async throws {
		try await transferFixture { fixture in
			let down = try await existingUnverifiedTransfer(fixture, corrupt: true)
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
			let resources = try TransferResources(maximumDiskOperations: 1)
			try await resources.disk.acquire()
			let down: TCPTransfer
			do {
				down = try await existingUnverifiedTransfer(fixture, resources: resources)
				try await eventually { await resources.snapshot().waitingDiskOperations == 1 }
				try await engineDeadline { try await down.shutdown() }
			} catch { await resources.disk.release(); throw error }
			await resources.disk.release()
			#expect(await down.localRecoveries.isEmpty)
			#expect(await down.snapshot().stopped)
		}
	}
}
