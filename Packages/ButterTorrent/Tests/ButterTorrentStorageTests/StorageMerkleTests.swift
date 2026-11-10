import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct StorageMerkleTests {
	@Test func legacyCandidatesNeedTheV2RootBeforePublishingProgress() async throws {
		try await storageFixture { root in
			let source = root.appendingPathComponent("payload"), bytes = Data((0..<115027).map { UInt8($0 % 251) })
			try bytes.write(to: source)
			let original = try TorrentMetadata(TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 32768))
			let sparse = try TorrentMetadata(infoBytes: original.originalInfo, expected: original.hashes)
			let destination = root.appendingPathComponent("download"), state = root.appendingPathComponent("state")
			let download = try await TorrentStorage.open(metadata: sparse, destination: destination, stateDirectory: state)
			try await download.importFiles(from: root)
			try await download.write(piece: 0, offset: 0, data: Data([255]))
			#expect(try await !download.verifyLegacyCandidate(piece: 0))
			#expect(try await download.verifyLegacyCandidate(piece: 1))
			#expect(try await download.reconstructHybridLayer(containing: 0) == .incomplete(legacyPieces: [1, 2, 3]))
			#expect(try await download.snapshot().verifiedPieces.isEmpty)
			await #expect(throws: StorageFailure.invalid("piece has not been verified")) { try await download.readVerifiedPiece(1) }
			try await download.write(piece: 0, offset: 0, data: bytes.prefix(1))
			#expect(try await download.reconstructHybridLayer(containing: 0) == .verified([0, 1, 2, 3]))
			try await download.shutdown()
			let restored = try await TorrentStorage.open(metadata: sparse, destination: destination, stateDirectory: state)
			#expect(try await restored.snapshot().verifiedPieces == [0, 1, 2, 3])
			#expect(try TorrentMetadata(await restored.exportMetadata()).pieceLayers == original.pieceLayers)
			try await restored.shutdown()
		}
	}

	@Test func validLegacyBytesWithAConflictingV2RootPublishNothing() async throws {
		try await storageFixture { root in
			let source = root.appendingPathComponent("payload"), bytes = Data(repeating: 19, count: 90000)
			try bytes.write(to: source)
			let original = try TorrentMetadata(TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 32768))
			var info = original.document.root["info"]!.dictionary!, v1 = try #require(info[Data("pieces".utf8)]?.bytes)
			var altered = bytes; altered[0] = 42
			v1.replaceSubrange(0..<20, with: TorrentHasher.hash(altered.prefix(32768)).sha1)
			info[Data("pieces".utf8)] = .bytes(v1)
			let conflicting = try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
			try altered.write(to: source)
			let storage = try await TorrentStorage.open(metadata: conflicting, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			try await storage.importFiles(from: root)
			#expect(try await storage.verifyLegacyCandidate(piece: 0))
			await #expect(throws: MetadataError.invalid("piece layer root")) { try await storage.reconstructHybridLayer(containing: 0) }
			#expect(try await storage.snapshot().verifiedPieces.isEmpty)
			#expect(try await storage.availableHashes().isEmpty)
			try await storage.shutdown()
		}
	}
	@Test func hybridAndV2VerificationAndAuthenticatedMagnetRestart() async throws {
		try await storageFixture { root in
			let (hybrid, _) = try storageMetadata(root)
			var info = hybrid.document.root["info"]!.dictionary!
			for key in ["pieces", "files", "length"] { info[Data(key.utf8)] = nil }
			let bytes = try BencodeValue.dictionary([Data("info".utf8): .dictionary(info), Data("piece layers".utf8): .dictionary(hybrid.pieceLayers.mapValues(BencodeValue.bytes))]).encoded()
			for (index, metadata) in [hybrid, try TorrentMetadata(bytes)].enumerated() {
				let seed = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("seed-\(index)"), stateDirectory: root.appendingPathComponent("seed-state-\(index)"))
				try await seed.importFiles(from: root)
				for piece in 0..<seed.layout.pieceCount { #expect(try await seed.verify(piece: piece)) }
				let infoOnly = try TorrentMetadata(infoBytes: metadata.originalInfo, expected: metadata.hashes)
				let state = root.appendingPathComponent("state-\(index)"), destination = root.appendingPathComponent("data-\(index)")
				let download = try await TorrentStorage.open(metadata: infoOnly, destination: destination, stateDirectory: state)
				try await download.importFiles(from: root)
				await #expect(throws: StorageFailure.missingHashes) { try await download.verify(piece: 0) }
				let request = download.merkleIndex.request(for: 0)!, response = try await seed.hashResponse(request)!
				var bad = response; bad[0] ^= 255
				await #expect(throws: MetadataError.self) { try await download.installHashes(request, hashes: bad) }
				try await download.installHashes(request, hashes: response)
				for piece in 0..<download.layout.pieceCount { #expect(try await download.verify(piece: piece)) }
				try await download.shutdown()
				let reopened = try await TorrentStorage.open(metadata: infoOnly, destination: destination, stateDirectory: state)
				#expect(try await reopened.snapshot().verifiedPieces.count == reopened.layout.pieceCount)
				let exported = try TorrentMetadata(await reopened.exportMetadata())
				#expect(exported.hashes == metadata.hashes && exported.pieceLayers == metadata.pieceLayers)
				try await reopened.shutdown(); try await seed.shutdown()
			}
		}
	}
	@Test func servesLeafProofsAndRejectsV2CorruptBytes() async throws {
		try await storageFixture { root in
			let source = root.appendingPathComponent("payload"), data = Data(repeating: 17, count: 200003)
			try data.write(to: source)
			let metadata = try TorrentMetadata(TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 65536))
			let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent("data"), stateDirectory: root.appendingPathComponent("state"))
			try await storage.importFiles(from: root)
			for piece in 0..<storage.layout.pieceCount { #expect(try await storage.verify(piece: piece)) }
			let file = storage.merkleIndex.files.values.first!
			let request = MerkleHashRequest(root: file.root, base: 0, index: 0, count: 2, proofLayers: file.height - 1)
			let response = try await storage.hashResponse(request)!
			#expect(response.count == (2 + request.proofCount) * 32)
			#expect(response.prefix(32) == TorrentHasher.hash(data.prefix(16384)).sha256)
			try await storage.write(piece: 0, offset: 0, data: Data([255]))
			#expect(try await storage.verify(piece: 0) == false)
			try await storage.shutdown()
		}
	}
}
