import Foundation
import Testing
@testable import ButterTorrentStorage
@testable import ButterTorrentEngine

@Suite struct ManagedCheckpointTests {
	@Test func pauseForcesPendingVerifiedProgressWithoutAdvancingTheClock() async throws {
		try await transferFixture { fixture in
			let state = fixture.root.appendingPathComponent("managed-state")
			let managed = try await ManagedTransfer.open(metadata: fixture.metadata, destination: fixture.root.appendingPathComponent("managed"), stateDirectory: state, configuration: plainTransferConfiguration(), clock: EngineClock())
			do {
				try await managed.start(); let engine = try #require(await managed.transfer)
				let peer = try await fixture.scripted(engine); try await peer.seed(pieceCount: 3)
				for block in try await peer.requests(6) where block.piece == 0 { try await peer.reply(block, bytes: fixture.bytes) }
				try await eventually { await engine.snapshot().verifiedPieces == [0] }
				let checkpoint = state.appendingPathComponent("checkpoint.plist")
				let before = try PropertyListDecoder().decode(StorageCheckpoint.self, from: Data(contentsOf: checkpoint))
				#expect(!before.contains(0))
				try await managed.pause()
				let after = try PropertyListDecoder().decode(StorageCheckpoint.self, from: Data(contentsOf: checkpoint))
				#expect(after.contains(0) && after.downloaded == 32768)
				#expect(try await managed.snapshot().running == false)
				peer.stream.close(); try await managed.close()
			} catch { try? await managed.close(); throw error }
		}
	}
}
