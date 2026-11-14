import Foundation
import Testing
@testable import ButterTorrentStorage

@Suite struct StorageWriteVerificationTests {
	@Test(arguments: [false, true]) func writesAndVerifiesWithEitherBatchPolicy(_ coalesced: Bool) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), budget = DownloadWriteBufferBudget()
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			let writes = [StorageWrite(piece: 0, offset: 0, data: bytes.prefix(8192)), StorageWrite(piece: 0, offset: 8192, data: bytes.subdata(in: 8192..<16384))]
			let result = try await storage.writeAndVerifyBatch(writes, piece: 0, bufferBudget: coalesced ? budget : nil)
			#expect(try result.get())
			#expect(try await storage.readVerifiedPiece(0) == bytes.prefix(16384))
			#expect(budget.usage == 0)
			try await storage.shutdown()
			let saved = try PropertyListDecoder().decode(StorageCheckpoint.self, from: Data(contentsOf: root.appendingPathComponent("state/checkpoint.plist")))
			#expect(saved.contains(0))
		}
	}
	@Test func invalidWritesThrowBeforeVerificationOrPayloadChanges() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			let writes = [StorageWrite(piece: 0, offset: 0, data: bytes.prefix(16384)), StorageWrite(piece: 1, offset: 3616, data: Data([1]))]
			await #expect(throws: StorageFailure.self) { try await storage.writeAndVerifyBatch(writes, piece: 0) }
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/source/a").path))
			#expect(try await storage.snapshot().verifiedPieces.isEmpty)
			try await storage.shutdown()
		}
	}
	@Test func verificationFailureIsReturnedAfterSuccessfulWrites() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), state = root.appendingPathComponent("state")
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: state)
			let checkpoint = state.appendingPathComponent("checkpoint.plist"), backup = root.appendingPathComponent("checkpoint-backup")
			try FileManager.default.moveItem(at: checkpoint, to: backup)
			try FileManager.default.createDirectory(at: checkpoint, withIntermediateDirectories: false)
			let result = try await storage.writeAndVerifyBatch([StorageWrite(piece: 0, offset: 0, data: bytes.prefix(16384))], piece: 0)
			#expect(throws: (any Error).self) { try result.get() }
			#expect(try await storage.read(piece: 0, offset: 0, count: 16384, verifiedOnly: false) == bytes.prefix(16384))
			try FileManager.default.removeItem(at: checkpoint); try FileManager.default.moveItem(at: backup, to: checkpoint)
			try await storage.shutdown()
		}
	}
}
