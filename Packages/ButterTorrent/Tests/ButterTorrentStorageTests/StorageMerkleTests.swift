import Foundation
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentStorage

@Suite struct StorageMerkleTests {
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
