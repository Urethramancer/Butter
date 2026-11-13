import Foundation
import Testing
@testable import ButterTorrentStorage

@Suite struct StorageFolderRepairTests {
	@Test(arguments: [false, true], [false, true]) func matchesBothRootChoicesAndStagesBoundaryFilesTogether(parent: Bool, selective: Bool) async throws {
		try await storageFixture { root in
			let folder = root.appendingPathComponent("copies/bundle")
			try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try Data(0..<5).write(to: folder.appendingPathComponent("a")); try Data(5..<12).write(to: folder.appendingPathComponent("b"))
			try Data([99]).write(to: folder.appendingPathComponent("unrelated"))
			let storage = try await TorrentStorage.open(metadata: repairMetadata(), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: [true, !selective])
			try await storage.rename([0: "renamed/a", 1: "renamed/b"])
			let result = try await storage.repairFolder(from: parent ? folder.deletingLastPathComponent() : folder)
			#expect(result.repairedFiles == 2 && result.verifiedPieces == 2 && result.pendingPieces == 0)
			#expect(try await storage.snapshot().verifiedPieces == [0, 1])
			#expect(try Data(contentsOf: folder.appendingPathComponent("unrelated")) == Data([99]))
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/unrelated").path))
			#expect(try Data(contentsOf: root.appendingPathComponent(selective ? "state/unwanted/1" : "data/renamed/b")) == Data(5..<12))
			try await storage.shutdown()
		}
	}
	@Test func partialFoldersRetainUnmatchedFilesAndVerifiedDependencies() async throws {
		try await storageFixture { root in
			let folder = root.appendingPathComponent("copies"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
			try Data(0..<5).write(to: folder.appendingPathComponent("a"))
			let storage = try await TorrentStorage.open(metadata: repairMetadata(), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			let partial = try await storage.repairFolder(from: folder)
			#expect(partial.repairedFiles == 1 && partial.pendingPieces == 1)
			try Data(5..<12).write(to: folder.appendingPathComponent("b"))
			_ = try await storage.repairFolder(from: folder)
			try await storage.write(piece: 1, offset: 0, data: Data(repeating: 255, count: 4))
			try Data([99]).write(to: folder.appendingPathComponent("a")) // Already verified local a remains the dependency.
			let result = try await storage.repairFolder(from: folder)
			#expect(result.repairedFiles == 1 && result.verifiedPieces == 2)
			#expect(try Data(contentsOf: root.appendingPathComponent("data/bundle/a")) == Data(0..<5))
			#expect(try Data(contentsOf: folder.appendingPathComponent("a")) == Data([99]))
			try await storage.shutdown()
		}
	}
	@Test(arguments: ["ambiguous", "length", "hash", "unrelated"])
	func rejectsInvalidSetsBeforePublication(_ kind: String) async throws {
		try await storageFixture { root in
			let folder = root.appendingPathComponent("copies")
			try FileManager.default.createDirectory(at: folder.appendingPathComponent("bundle"), withIntermediateDirectories: true)
			try Data(0..<5).write(to: folder.appendingPathComponent(kind == "unrelated" ? "unrelated" : "a"))
			if kind == "ambiguous" { try Data(0..<5).write(to: folder.appendingPathComponent("bundle/a")) }
			if kind == "length" { try Data(5..<11).write(to: folder.appendingPathComponent("b")) }
			if kind == "hash" { try Data(repeating: 255, count: 7).write(to: folder.appendingPathComponent("b")) }
			let storage = try await TorrentStorage.open(metadata: repairMetadata(), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			await #expect(throws: StorageFailure.self) { try await storage.repairFolder(from: folder) }
			#expect(try await storage.snapshot().verifiedPieces.isEmpty)
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/bundle/a").path))
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("state/operation.plist").path))
			try await storage.shutdown()
		}
	}
}
