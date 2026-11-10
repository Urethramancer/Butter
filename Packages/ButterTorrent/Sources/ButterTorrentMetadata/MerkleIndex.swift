import Foundation
import CryptoKit

public struct MerkleHashRequest: Codable, Hashable, Sendable {
	public let root: Data
	public let base: Int
	public let index: Int
	public let count: Int
	public let proofLayers: Int
	public init(root: Data, base: Int, index: Int, count: Int, proofLayers: Int) {
		self.root = root; self.base = base; self.index = index; self.count = count; self.proofLayers = proofLayers
	}
	public var proofCount: Int { max(0, proofLayers - (MerkleMath.log2(count) - 1)) }
}
public enum MerkleMath {
	public static func power2(_ value: Int) -> Int { var n = 1; while n < value { n *= 2 }; return n }
	public static func log2(_ value: Int) -> Int { var n = value, result = 0; while n > 1 { n /= 2; result += 1 }; return result }
	public static func parent(_ a: Data, _ b: Data) -> Data { Data(SHA256.hash(data: a + b)) }
	public static func zero(_ layer: Int) -> Data { var value = Data(repeating: 0, count: 32); for _ in 0..<layer { value = parent(value, value) }; return value }
	public static func root(_ hashes: [Data], zero: Data = Data(repeating: 0, count: 32)) throws -> Data {
		guard !hashes.isEmpty, hashes.count <= 1_048_576, hashes.allSatisfy({ $0.count == 32 }) else { throw MetadataError.invalid("Merkle leaves") }
		var row = hashes + Array(repeating: zero, count: power2(hashes.count) - hashes.count)
		while row.count > 1 { row = stride(from: 0, to: row.count, by: 2).map { parent(row[$0], row[$0 + 1]) } }; return row[0]
	}
}

/// MerkleIndex binds file/piece geometry to the roots inside the authenticated info dictionary.
public struct MerkleIndex: Sendable {
	public struct File: Sendable {
		public let index: Int
		public let root: Data
		public let size: Int64
		public let start: Int
		public let pieces: Int
		public let height: Int
		public let base: Int
		public var leaves: Int { 1 << (height - base) }
		public func validate(_ request: MerkleHashRequest) throws {
			guard request.root == root, request.base >= 0, request.base <= height, request.index >= 0,
				(2...512).contains(request.count), request.count.nonzeroBitCount == 1, request.index % request.count == 0,
				request.index <= (1 << (height - request.base)) - request.count,
				request.proofLayers >= 0, request.proofLayers <= max(0, height - request.base - 1) else { throw MetadataError.invalid("hash request geometry") }
		}
	}
	public struct Piece: Sendable {
		public let root: Data
		public let local: Int
		public let length: Int
	}
	public let files: [Data: File]
	public let pieces: [Int: Piece]
	public let starts: [Data: [Int]]
	public let enabled: Bool
	public init(metadata: TorrentMetadata) throws {
		enabled = metadata.hashes.v2 != nil
		guard metadata.pieceLength <= 16_777_216, metadata.inspection.files.count <= 50_000 else { throw MetadataError.limit("Merkle layout") }
		var files: [Data: File] = [:], pieces: [Int: Piece] = [:], starts: [Data: [Int]] = [:], offset: Int64 = 0
		for file in metadata.inspection.files {
			defer { offset += file.size }
			guard enabled, !file.pad, file.size > 0, let root = metadata.fileRoots[file.index] else { continue }
			guard offset % metadata.pieceLength == 0 else { throw MetadataError.invalid("v2 file alignment") }
			let count = Int((file.size - 1) / metadata.pieceLength + 1), start = Int(offset / metadata.pieceLength)
			guard start <= 400_000, count <= 400_000 - start else { throw MetadataError.limit("Merkle pieces") }
			let height = MerkleMath.log2(MerkleMath.power2(Int((file.size - 1) / 16384 + 1)))
			let descriptor = File(index: file.index, root: root, size: file.size, start: start, pieces: count, height: height, base: min(height, MerkleMath.log2(Int(metadata.pieceLength) / 16384)))
			if let old = files[root], old.size != file.size { throw MetadataError.invalid("conflicting root geometry") }
			files[root] = descriptor
			starts[root, default: []].append(start)
			for local in 0..<count { pieces[start + local] = Piece(root: root, local: local, length: Int(min(metadata.pieceLength, file.size - Int64(local) * metadata.pieceLength))) }
		}
		self.files = files; self.pieces = pieces; self.starts = starts
	}
	public func request(for piece: Int) -> MerkleHashRequest? {
		guard let mapping = pieces[piece], let file = files[mapping.root], file.leaves > 1 else { return nil }
		let count = min(512, file.leaves)
		return MerkleHashRequest(root: file.root, base: file.base, index: mapping.local / count * count, count: count, proofLayers: file.height - file.base - 1)
	}
}
