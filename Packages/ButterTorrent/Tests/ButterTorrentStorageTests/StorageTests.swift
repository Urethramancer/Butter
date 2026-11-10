import Foundation
import Darwin
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

func storageFixture(_ body: (URL) async throws -> Void) async throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent("butter-storage-" + UUID().uuidString).resolvingSymlinksInPath()
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	try await body(root)
}
func storageMetadata(_ root: URL) throws -> (TorrentMetadata, Data) {
	let source = root.appendingPathComponent("source")
	try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
	let bytes = Data((0..<20000).map { UInt8($0 % 251) })
	try bytes.write(to: source.appendingPathComponent("a")); try Data([1, 2, 3]).write(to: source.appendingPathComponent("b"))
	return (try TorrentMetadata(TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 16384)), bytes)
}

@Suite struct StorageTests {
	@Test func mappingPaddingSelectiveWritesAndRestart() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root), layout = try StorageLayout(metadata: metadata)
			let selected = metadata.inspection.files.map { !$0.pad && $0.path.hasSuffix("/a") }
			let destination = root.appendingPathComponent("download"), state = root.appendingPathComponent("state")
			var storage: TorrentStorage? = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state, selected: selected)
			let original = try PropertyListDecoder().decode(StorageCheckpoint.self, from: Data(contentsOf: state.appendingPathComponent("checkpoint.plist")))
			#expect(original.corruptBytes == nil && original.redundantBytes == nil)
			let payload = bytes + Data(repeating: 0, count: 32768 - bytes.count) + Data([1, 2, 3]) + Data(repeating: 0, count: 16384 - 3)
			for piece in 0..<layout.pieceCount {
				let count = try layout.length(of: piece)
				try await storage!.write(piece: piece, offset: 0, data: payload.subdata(in: piece * layout.pieceLength..<(piece * layout.pieceLength + count)))
				#expect(try await storage!.verify(piece: piece))
			}
			#expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("source/b").path))
			#expect(try Data(contentsOf: destination.appendingPathComponent("source/a")) == bytes)
			#expect(try await storage!.read(piece: 0, offset: 7, count: 17) == bytes.subdata(in: 7..<24))
			try await storage!.checkpoint(downloaded: 20003, uploaded: 9, corruptBytes: 13, redundantBytes: 17)
			try await storage!.shutdown(); storage = nil
			let restored = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: state)
			let snapshot = try await restored.snapshot()
			#expect(snapshot.selected == selected && snapshot.verifiedPieces.count == layout.pieceCount && snapshot.uploaded == 9)
			#expect(snapshot.downloaded == 20003 && snapshot.corruptBytes == 13 && snapshot.redundantBytes == 17)
			for (received, corrupt, redundant): (Int64, Int64, Int64) in [(-1, 0, 0), (1, -1, 0), (1, 0, -1), (1, 2, 0), (1, 1, 1), (.max, .max, 1)] {
				await #expect(throws: StorageFailure.self) { try await restored.checkpoint(downloaded: received, uploaded: 9, corruptBytes: corrupt, redundantBytes: redundant) }
			}
			try await restored.checkpoint(downloaded: 20003, uploaded: 10)
			let retained = try await restored.snapshot()
			#expect(retained.downloaded == 20003 && retained.corruptBytes == 13 && retained.redundantBytes == 17)
			try Data([7]).write(to: destination.appendingPathComponent("source/a"))
			#expect(try await restored.snapshot().verifiedPieces == [2])
			try await restored.shutdown()
		}
	}
	@Test func refusesSymlinksHardLinksAndCollidingPaths() async throws {
		try await storageFixture { root in
			let (metadata, _) = try storageMetadata(root)
			let destination = root.appendingPathComponent("download"), external = root.appendingPathComponent("external")
			try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
			try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
			try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("source"), withDestinationURL: external)
			await #expect(throws: (any Error).self) { try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: root.appendingPathComponent("state")) }
			try FileManager.default.removeItem(at: destination.appendingPathComponent("source"))
			try FileManager.default.createDirectory(at: destination.appendingPathComponent("source"), withIntermediateDirectories: true)
			let file = destination.appendingPathComponent("source/a")
			try Data([42]).write(to: file)
			try FileManager.default.linkItem(at: file, to: external.appendingPathComponent("link"))
			await #expect(throws: StorageFailure.self) { try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: root.appendingPathComponent("state")) }
			#expect(try Data(contentsOf: file) == Data([42]))
			#expect(throws: StorageFailure.self) { try StorageLayout.validatePaths(["a", "a/b"]) }
			#expect(throws: StorageFailure.self) { try StorageLayout.validatePaths(["A", "a"]) }
			#expect(throws: StorageFailure.self) { try StorageLayout.validatePaths(["Σ", "ς"]) }
			#expect(throws: StorageFailure.self) { try StorageLayout.components("../a") }
			await #expect(throws: StorageFailure.self) {
				try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("overlap"), stateDirectory: root.appendingPathComponent("overlap/source"))
			}
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("overlap/source/metadata.torrent").path))
		}
	}
}
