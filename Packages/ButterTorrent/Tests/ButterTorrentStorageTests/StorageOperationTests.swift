import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct StorageOperationTests {
	@Test func importRenameMoveSelectAndTrash() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let selected = metadata.inspection.files.map { !$0.pad && $0.path.hasSuffix("/a") }
			let storage = try TorrentStorage(metadata: metadata, destination: root.appendingPathComponent("download"), stateDirectory: root.appendingPathComponent("state"), selected: selected)
			try await storage.importFiles(from: root)
			#expect(try Data(contentsOf: root.appendingPathComponent("source/a")) == bytes)
			for piece in 0..<storage.layout.pieceCount { #expect(try await storage.verify(piece: piece)) }
			try await storage.select(metadata.inspection.files.map { !$0.pad })
			#expect(try Data(contentsOf: root.appendingPathComponent("download/source/b")) == Data([1, 2, 3]))
			try await storage.rename([0: "renamed/a"])
			#expect(try await storage.snapshot().paths[0] == "renamed/a")
			try await storage.move(to: root.appendingPathComponent("moved"))
			#expect(try Data(contentsOf: root.appendingPathComponent("moved/renamed/a")) == bytes)
			#expect(try await storage.snapshot().verifiedPieces.count == storage.layout.pieceCount)
			let trash = root.appendingPathComponent("Trash"), receipts = try await storage.trash(directory: trash)
			#expect(receipts.count == 2)
			#expect(try receipts.map { try Data(contentsOf: $0) }.contains(bytes))
			#expect(try await storage.snapshot().verifiedPieces.isEmpty)
			#expect(try await storage.snapshot().trashReceipts == receipts)
			try await storage.shutdown()
			let restored = try TorrentStorage(metadata: metadata, destination: root, stateDirectory: root.appendingPathComponent("state"))
			#expect(try await restored.snapshot().trashReceipts == receipts)
			try await restored.shutdown()
		}
	}
	@Test func collisionAndSharedTransferPreflightLeavesSourcesUntouched() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), destination = root.appendingPathComponent("download")
			let first = try TorrentStorage(metadata: metadata, destination: destination, stateDirectory: root.appendingPathComponent("state1"))
			#expect(throws: StorageFailure.self) { try TorrentStorage(metadata: metadata, destination: destination, stateDirectory: root.appendingPathComponent("state2")) }
			try await first.importFiles(from: root)
			try Data([42]).write(to: destination.appendingPathComponent("collision"))
			await #expect(throws: StorageFailure.self) { try await first.rename([0: "renamed", 2: "collision"]) }
			#expect(try Data(contentsOf: destination.appendingPathComponent("source/a")) == bytes)
			#expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("renamed").path))
			#expect(try await first.snapshot().needsRecovery == false)
			try await first.shutdown()
		}
	}
	@Test func verifiedProgressRejectsExternalChangesBeforeCheckpointAndInvalidRanges() async throws {
		try await storageFixture { root in
			let (metadata, _) = try storageMetadata(root), destination = root.appendingPathComponent("download"), state = root.appendingPathComponent("state")
			let storage = try TorrentStorage(metadata: metadata, destination: destination, stateDirectory: state)
			try await storage.importFiles(from: root)
			#expect(try await storage.verify(piece: 0))
			let file = try FileHandle(forWritingTo: destination.appendingPathComponent("source/a"))
			try file.write(contentsOf: Data([9])); try file.close()
			try await storage.checkpoint(downloaded: 1, uploaded: 0)
			#expect(try await storage.snapshot().verifiedPieces.isEmpty)
			await #expect(throws: StorageFailure.self) { try await storage.read(piece: -1, offset: 0, count: 1) }
			await #expect(throws: StorageFailure.self) { try await storage.write(piece: 1, offset: 10000, data: Data(repeating: 1, count: 10000)) }
			await #expect(throws: StorageFailure.self) { try await storage.write(piece: 1, offset: 4000, data: Data([1])) }
			#expect(try await storage.verify(piece: 0) == false)
			try await storage.shutdown()
			let directory = try StorageDirectory(state)
			var checkpoint = try PropertyListDecoder().decode(StorageCheckpoint.self, from: directory.read("checkpoint.plist", maximum: 16_777_216))
			checkpoint.version = 99; try directory.atomic(checkpoint.encoded(), path: "checkpoint.plist")
			#expect(throws: StorageFailure.self) { try TorrentStorage(metadata: metadata, destination: destination, stateDirectory: state) }
		}
	}
}
