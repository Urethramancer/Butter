import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

private func batchMetadata(fileCount: Int, fileSize: Int, pieceLength: Int = 16384) throws -> (TorrentMetadata, Data) {
	let payload = Data((0..<(fileCount * fileSize)).map { UInt8(($0 * 17 + $0 / 97) % 251) })
	var pieces = Data()
	for offset in stride(from: 0, to: payload.count, by: pieceLength) { pieces.append(TorrentHasher.hash(payload.subdata(in: offset..<min(offset + pieceLength, payload.count))).sha1) }
	let files: [BencodeValue] = (0..<fileCount).map { index in .dictionary([
		Data("length".utf8): .integer(Int64(fileSize)), Data("path".utf8): .list([.bytes(Data("file-\(index)".utf8))])]) }
	let info: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("bundle".utf8)), Data("files".utf8): .list(files),
		Data("piece length".utf8): .integer(Int64(pieceLength)), Data("pieces".utf8): .bytes(pieces)]
	return (try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded()), payload)
}

@Suite struct StorageWriteBatchTests {
	@Test(arguments: [false, true]) func crossesManyFilesAndEvictsDescriptorsWithoutChangingSelectiveStorage(selective: Bool) async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try batchMetadata(fileCount: 32, fileSize: 1024)
			let selected = (0..<32).map { !selective || $0 % 2 == 0 }
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: selected)
			try await storage.writeBatch([StorageWrite(piece: 0, offset: 0, data: bytes.prefix(16384)), StorageWrite(piece: 1, offset: 0, data: bytes.suffix(16384))])
			#expect(try await storage.verify(piece: 0)); #expect(try await storage.verify(piece: 1))
			for index in 0..<32 {
				let path = selected[index] ? "data/bundle/file-\(index)" : "state/unwanted/\(index)"
				#expect(try Data(contentsOf: root.appendingPathComponent(path)) == bytes.subdata(in: (index * 1024)..<((index + 1) * 1024)))
				if !selected[index] { #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/bundle/file-\(index)").path)) }
			}
			#expect(try await storage.read(piece: 0, offset: 1020, count: 12) == bytes.subdata(in: 1020..<1032))
			try await storage.shutdown()
		}
	}
	@Test func validatesEveryPaddingByteBeforeWritingAnyBlock() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try storageMetadata(root)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			var last = Data([1, 2, 3]) + Data(repeating: 0, count: 16381); last[last.count - 1] = 255
			let first = StorageWrite(piece: 0, offset: 0, data: bytes.prefix(16384))
			let badLast = last
			await #expect(throws: StorageFailure.invalid("nonzero padding")) { try await storage.writeBatch([first, StorageWrite(piece: 2, offset: 0, data: badLast)]) }
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/source/a").path))
			last[last.count - 1] = 0
			try await storage.writeBatch([first, StorageWrite(piece: 1, offset: 0, data: bytes.suffix(3616) + Data(repeating: 0, count: 12768)), StorageWrite(piece: 2, offset: 0, data: last)])
			for piece in 0..<3 { #expect(try await storage.verify(piece: piece)) }
			try await storage.shutdown()
		}
	}
	@Test func cancellationRetainsPartialWritesForFlushingAndLaterVerification() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try batchMetadata(fileCount: 1, fileSize: 65536, pieceLength: 32768)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { _ in }, check: {})
			let writes = [StorageWrite(piece: 0, offset: 0, data: bytes.prefix(16384)), StorageWrite(piece: 0, offset: 16384, data: bytes.subdata(in: 16384..<32768))]
			var checks = 0
			#expect(throws: CancellationError.self) { try state.writeOperations(writes, maximumBytes: 262144, maximumCount: 16, check: { checks += 1; if checks == 3 { throw CancellationError() } }) }
			#expect(state.pendingFlush == [0] && !state.record.contains(0))
			#expect(try Data(contentsOf: root.appendingPathComponent("data/bundle/file-0")) == bytes.prefix(16384))
			try state.save(); #expect(state.pendingFlush.isEmpty)
			try state.writeOperations([writes[1]], maximumBytes: 262144, maximumCount: 16, check: {})
			#expect(try state.verify(piece: 0, check: {}))
		}
	}
	@Test func pathReplacementBetweenBlocksCannotRedirectACachedDescriptor() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try batchMetadata(fileCount: 1, fileSize: 65536, pieceLength: 32768)
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { _ in }, check: {})
			let file = root.appendingPathComponent("data/bundle/file-0"), original = root.appendingPathComponent("original"), replacement = Data([4, 5, 6])
			var checks = 0
			#expect(throws: (any Error).self) {
				try state.writeOperations([StorageWrite(piece: 0, offset: 0, data: bytes.prefix(16384)), StorageWrite(piece: 0, offset: 16384, data: bytes.subdata(in: 16384..<32768))], maximumBytes: 262144, maximumCount: 16, check: {
					checks += 1
					if checks == 3 { try FileManager.default.moveItem(at: file, to: original); try replacement.write(to: file) }
				})
			}
			#expect(try Data(contentsOf: original) == bytes.prefix(16384)); #expect(try Data(contentsOf: file) == replacement)
		}
	}
	@Test func invalidatesBothCommittedAndPendingTargetsBeforeAMixedOverwrite() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try batchMetadata(fileCount: 1, fileSize: 65536)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), checkpointPolicy: .managed)
			try await storage.write(piece: 0, offset: 0, data: bytes.prefix(16384)); #expect(try await storage.verify(piece: 0)); try await storage.flush()
			try await storage.write(piece: 1, offset: 0, data: bytes.subdata(in: 16384..<32768)); #expect(try await storage.verify(piece: 1))
			try await storage.writeBatch([StorageWrite(piece: 0, offset: 0, data: Data([255])), StorageWrite(piece: 1, offset: 0, data: Data([254]))])
			let saved = try PropertyListDecoder().decode(StorageCheckpoint.self, from: Data(contentsOf: root.appendingPathComponent("state/checkpoint.plist")))
			#expect(!saved.contains(0) && !saved.contains(1))
			#expect(try await storage.verify(piece: 0) == false); #expect(try await storage.verify(piece: 1) == false)
			try await storage.shutdown()
		}
	}
	@Test func replacementAfterInvalidationCannotPreserveOtherVerifiedPieces() async throws {
		try await storageFixture { root in
			let (metadata, bytes) = try batchMetadata(fileCount: 1, fileSize: 32768)
			let file = root.appendingPathComponent("data/bundle/file-0"), armed = root.appendingPathComponent("armed")
			let state = try StorageState(metadata: metadata, layout: StorageLayout(metadata: metadata), destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"), selected: nil, coordinator: StorageCoordinator(), event: { event in
				if case .progressCheckpointDurable = event, FileManager.default.fileExists(atPath: armed.path) {
					do { try FileManager.default.removeItem(at: armed); try FileManager.default.removeItem(at: file); try Data(count: 32768).write(to: file) }
					catch { Issue.record(error) }
				}
			}, check: {})
			try state.write(piece: 0, offset: 0, data: bytes.prefix(16384), check: {}); #expect(try state.verify(piece: 0, check: {}))
			try state.write(piece: 1, offset: 0, data: bytes.suffix(16384), check: {}); #expect(try state.verify(piece: 1, check: {}))
			try Data([1]).write(to: armed)
			try state.writeOperations([StorageWrite(piece: 0, offset: 0, data: Data([255]))], maximumBytes: 262144, maximumCount: 16, check: {})
			#expect(!state.record.contains(1))
			#expect(try state.verify(piece: 1, check: {}) == false)
		}
	}
	@Test func oversizedOrEmptyBatchesCannotModifyPayload() async throws {
		try await storageFixture { root in
			let (metadata, _) = try batchMetadata(fileCount: 1, fileSize: 1_048_576, pieceLength: 1_048_576)
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			for writes in [[], [StorageWrite(piece: 0, offset: 0, data: Data(count: 262145))], Array(repeating: StorageWrite(piece: 0, offset: 0, data: Data([1])), count: 17)] {
				await #expect(throws: StorageFailure.self) { try await storage.writeBatch(writes) }
			}
			#expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("data/bundle/file-0").path))
			// The existing direct-write API still accepts its original 1 MiB maximum.
			try await storage.write(piece: 0, offset: 0, data: Data(count: 1_048_576))
			#expect(try Data(contentsOf: root.appendingPathComponent("data/bundle/file-0")).count == 1_048_576)
			try await storage.shutdown()
		}
	}
}
