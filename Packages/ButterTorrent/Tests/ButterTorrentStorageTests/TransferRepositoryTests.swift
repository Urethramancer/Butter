import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct TransferRepositoryTests {
	@Test func preparationReservesPublicationAcrossRepositoryOwners() async throws {
		try await storageFixture { root in
			let first = TransferRepository(root: root), second = TransferRepository(root: root)
			let prepared = try await first.prepare(id: "first", restore: false)
			await #expect(throws: StorageFailure.self) { try await second.prepare(id: "second", restore: false) }
			try await first.abandon(prepared)
			let next = try await second.prepare(id: "second", restore: false); try await second.abandon(next)
			#expect(!FileManager.default.fileExists(atPath: prepared.directory.path))
		}
	}
	@Test func preparedStorageRemainsAnchoredAndReplacementIsNeverPublishedOrDeleted() async throws {
		try await storageFixture { root in
			let (metadata, _) = try storageMetadata(root), library = root.appendingPathComponent("library")
			let repository = TransferRepository(root: library), prepared = try await repository.prepare(id: "transfer", restore: false)
			let retained = root.appendingPathComponent("retained")
			try FileManager.default.moveItem(at: prepared.directory, to: retained)
			try FileManager.default.createDirectory(at: prepared.directory, withIntermediateDirectories: false)
			let sentinel = prepared.directory.appendingPathComponent("unrelated"), bytes = Data("preserve".utf8); try bytes.write(to: sentinel)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("download"), stateDirectory: prepared.directory, preparedState: prepared)
			try await storage.shutdown()
			#expect(FileManager.default.fileExists(atPath: retained.appendingPathComponent("checkpoint.plist").path))
			#expect(!FileManager.default.fileExists(atPath: prepared.directory.appendingPathComponent("checkpoint.plist").path))
			await #expect(throws: StorageFailure.self) { try await repository.publish(id: "transfer", metadata: metadata, state: prepared) }
			await #expect(throws: StorageFailure.self) { try await repository.abandon(prepared) }
			#expect(try Data(contentsOf: sentinel) == bytes)
			#expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("transfer.native.plist").path))
		}
	}
}
