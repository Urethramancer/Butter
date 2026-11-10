import Foundation
import Testing
@testable import ButterTorrentMetadata

func merkleFixture(_ body: (TorrentMetadata, URL) throws -> Void) throws {
	let root = FileManager.default.temporaryDirectory.appendingPathComponent("butter-merkle-" + UUID().uuidString)
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	defer { try? FileManager.default.removeItem(at: root) }
	try Data(repeating: 7, count: 10003).write(to: root.appendingPathComponent("a"))
	try Data(repeating: 31, count: 200003).write(to: root.appendingPathComponent("b"))
	let metadata = try TorrentMetadata(TorrentCreator.create(source: root, trackers: [], isPrivate: false, pieceLength: 65536))
	try body(metadata, root)
}

@Suite struct MerkleTests {
	@Test func authenticatedLayersSparseProofsAndCachedNodes() throws {
		try merkleFixture { metadata, _ in
			let index = try MerkleIndex(metadata: metadata), file = index.files.values.first { $0.pieces > 1 }!
			let full = try AuthenticatedMerkleTree(file: file, layer: metadata.pieceLayers[file.root])
			let request = MerkleHashRequest(root: file.root, base: file.base, index: 2, count: 2, proofLayers: 1)
			let response = try full.response(request)!
			var sparse = try AuthenticatedMerkleTree(file: file)
			#expect(sparse.piece(2) == nil)
			try sparse.install(request, hashes: response)
			#expect(sparse.piece(0) == nil && sparse.piece(2) == full.piece(2))
			let restored = try AuthenticatedMerkleTree(file: file, restored: sparse.record)
			#expect(restored.piece(3) == full.piece(3))
			var corrupt = response; corrupt[0] ^= 255
			#expect(throws: MetadataError.self) { try sparse.install(request, hashes: corrupt) }
			#expect(sparse.piece(2) == full.piece(2))
			var layer = metadata.pieceLayers[file.root]!; layer[0] ^= 255
			#expect(throws: MetadataError.self) { try AuthenticatedMerkleTree(file: file, layer: layer) }
		}
	}
	@Test func exactInfoEnvelopeAndMetadataMessagePrefix() throws {
		try merkleFixture { metadata, _ in
			let received = try TorrentMetadata(infoBytes: metadata.originalInfo, expected: metadata.hashes, trackers: ["http://127.0.0.1/announce"])
			#expect(received.originalInfo == metadata.originalInfo && received.pieceLayers.isEmpty)
			let restored = try TorrentMetadata(received.withPieceLayers(metadata.pieceLayers))
			#expect(restored.hashes == metadata.hashes && restored.fileRoots == metadata.fileRoots)
			let header = Data("d8:msg_typei1e5:piecei0ee".utf8), binary = Data([0, 255, 101])
			let parsed = try BencodeDocument.prefix(header + binary)
			#expect(parsed.length == header.count && parsed.value["piece"]?.integer == 0)
			let wrong = try InfoHashes(v1: Data(repeating: 1, count: 20))
			#expect(throws: MetadataError.self) { try TorrentMetadata(infoBytes: metadata.originalInfo, expected: wrong) }
		}
	}
	@Test func rejectsUnprovenCacheAndInvalidRequestGeometry() throws {
		try merkleFixture { metadata, _ in
			let file = try MerkleIndex(metadata: metadata).files.values.first { $0.pieces > 1 }!
			let tree = try AuthenticatedMerkleTree(file: file)
			var bytes = tree.record.hashes, bits = tree.record.present
			bytes.replaceSubrange(32..<64, with: Data(repeating: 42, count: 32)); bits[0] |= 64
			#expect(throws: MetadataError.self) { try AuthenticatedMerkleTree(file: file, restored: MerkleTreeRecord(hashes: bytes, present: bits)) }
			for count in [0, 1, 3, 513] {
				#expect(throws: MetadataError.self) { try file.validate(MerkleHashRequest(root: file.root, base: 0, index: 0, count: count, proofLayers: 0)) }
			}
		}
	}
}
