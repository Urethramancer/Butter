import Foundation

public struct MerkleTreeRecord: Codable, Sendable {
	public let hashes: Data
	public let present: Data
}

/// AuthenticatedMerkleTree retains only nodes connected by checked proofs to a file root.
public struct AuthenticatedMerkleTree: Sendable {
	public let file: MerkleIndex.File
	private var hashes: Data
	private var present: Data
	private var nodeCount: Int { file.leaves * 2 - 1 }
	public init(file: MerkleIndex.File, layer: Data? = nil, restored: MerkleTreeRecord? = nil) throws {
		self.file = file
		hashes = Data(repeating: 0, count: (file.leaves * 2 - 1) * 32); present = Data(repeating: 0, count: (file.leaves * 2 + 6) / 8)
		put(0, file.root)
		if let layer {
			guard layer.count == file.pieces * 32 else { throw MetadataError.invalid("piece layer count") }
			var row: [Data] = (0..<file.pieces).map { layer.subdata(in: $0 * 32..<($0 + 1) * 32) }
			row += Array(repeating: MerkleMath.zero(file.base), count: file.leaves - row.count)
			var first = file.leaves - 1
			for (index, hash) in row.enumerated() { put(first + index, hash) }
			while row.count > 1 {
				row = stride(from: 0, to: row.count, by: 2).map { MerkleMath.parent(row[$0], row[$0 + 1]) }; first = (first - 1) / 2
				for (index, hash) in row.enumerated() { put(first + index, hash) }
			}
			guard row[0] == file.root else { throw MetadataError.invalid("piece layer root") }
		}
		if let restored {
			guard restored.hashes.count == hashes.count, restored.present.count == present.count else { throw MetadataError.invalid("hash cache shape") }
			hashes = restored.hashes; present = restored.present
			guard node(0) == file.root else { throw MetadataError.invalid("hash cache root") }
			var authenticated: Set<Int> = [0]
			for index in 0..<nodeCount where node(index) != nil {
				guard authenticated.contains(index) else { throw MetadataError.invalid("unproven cached hash") }
				let left = index * 2 + 1, right = left + 1
				if right < nodeCount, let a = node(left), let b = node(right) {
					guard MerkleMath.parent(a, b) == node(index) else { throw MetadataError.invalid("cached hash proof") }; authenticated.insert(left); authenticated.insert(right)
				}
			}
		}
	}
	public var record: MerkleTreeRecord { MerkleTreeRecord(hashes: hashes, present: present) }
	private func node(_ index: Int) -> Data? {
		guard index < nodeCount, present[index / 8] & (128 >> (index % 8)) != 0 else { return nil }
		return hashes.subdata(in: index * 32..<(index + 1) * 32)
	}
	private mutating func put(_ index: Int, _ hash: Data) { hashes.replaceSubrange(index * 32..<(index + 1) * 32, with: hash); present[index / 8] |= UInt8(128 >> (index % 8)) }
	public func hash(layer: Int, index: Int) -> Data? {
		guard layer >= file.base, layer <= file.height, index >= 0, index < 1 << (file.height - layer) else { return nil }
		return node((1 << (file.height - layer)) - 1 + index)
	}
	public func piece(_ local: Int) -> Data? { hash(layer: file.base, index: local) }
	public mutating func install(_ request: MerkleHashRequest, hashes bytes: Data) throws {
		try file.validate(request)
		guard request.base >= file.base, bytes.count == (request.count + request.proofCount) * 32 else { throw MetadataError.invalid("hash response shape") }
		var updates: [(Int, Int, Data)] = []
		var row = (0..<request.count).map { bytes.subdata(in: $0 * 32..<($0 + 1) * 32) }, layer = request.base, index = request.index
		while true {
			for (offset, hash) in row.enumerated() { updates.append((layer, index + offset, hash)) }
			if row.count == 1 { break }
			row = stride(from: 0, to: row.count, by: 2).map { MerkleMath.parent(row[$0], row[$0 + 1]) }; index /= 2; layer += 1
		}
		var result = row[0]
		for proof in 0..<request.proofCount {
			let start = (request.count + proof) * 32, uncle = bytes.subdata(in: start..<(start + 32))
			updates.append((layer, index ^ 1, uncle)); result = index % 2 == 0 ? MerkleMath.parent(result, uncle) : MerkleMath.parent(uncle, result)
			index /= 2; layer += 1; updates.append((layer, index, result))
		}
		guard layer == file.height, index == 0, result == file.root else { throw MetadataError.invalid("hash proof root") }
		for (layer, index, hash) in updates {
			if let known = self.hash(layer: layer, index: index), known != hash { throw MetadataError.invalid("conflicting hash proof") }
		}
		for (layer, index, hash) in updates { put((1 << (file.height - layer)) - 1 + index, hash) }
	}
	public func response(_ request: MerkleHashRequest) throws -> Data? {
		try file.validate(request); guard request.base >= file.base else { return nil }
		var bytes = Data()
		for index in request.index..<(request.index + request.count) { guard let hash = hash(layer: request.base, index: index) else { return nil }; bytes.append(hash) }
		var layer = request.base + MerkleMath.log2(request.count), index = request.index / request.count
		for _ in 0..<request.proofCount {
			guard let hash = hash(layer: layer, index: index ^ 1) else { return nil }; bytes.append(hash); layer += 1; index /= 2
		}
		return bytes
	}
}
