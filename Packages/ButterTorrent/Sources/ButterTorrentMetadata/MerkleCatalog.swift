import Foundation

public struct MerkleCatalog: Sendable {
	public let index: MerkleIndex
	private var trees: [Data: AuthenticatedMerkleTree] = [:]
	public init(metadata: TorrentMetadata, restored: [Data: MerkleTreeRecord] = [:]) throws {
		index = try MerkleIndex(metadata: metadata)
		guard Set(metadata.pieceLayers.keys).isSubset(of: Set(index.files.keys)), Set(restored.keys).isSubset(of: Set(index.files.keys)) else { throw MetadataError.invalid("unreferenced piece layers") }
		var bytes = 0
		for (root, file) in index.files {
			bytes += (file.leaves * 2 - 1) * 32 + (file.leaves * 2 + 6) / 8
			guard bytes <= 67_108_864 else { throw MetadataError.limit("authenticated hash cache") }
			trees[root] = try AuthenticatedMerkleTree(file: file, layer: metadata.pieceLayers[root], restored: restored[root])
		}
	}
	public var records: [Data: MerkleTreeRecord] { trees.mapValues(\.record) }
	public var available: Set<Int> { Set(index.pieces.keys.filter { expected($0) != nil }) }
	public func expected(_ piece: Int) -> Data? {
		guard let mapping = index.pieces[piece] else { return nil }; return trees[mapping.root]?.piece(mapping.local)
	}
	public mutating func install(_ request: MerkleHashRequest, hashes: Data) throws {
		guard var tree = trees[request.root] else { throw MetadataError.invalid("unknown hash root") }
		try tree.install(request, hashes: hashes); trees[request.root] = tree
	}
	public func response(_ request: MerkleHashRequest) throws -> Data? { try trees[request.root]?.response(request) }
	public func hash(root: Data, layer: Int, index: Int) -> Data? { trees[root]?.hash(layer: layer, index: index) }
	public func completeLayers() throws -> [Data: Data] {
		var layers: [Data: Data] = [:]
		for (root, file) in index.files where file.pieces > 1 {
			var bytes = Data()
			for local in 0..<file.pieces { guard let hash = trees[root]?.piece(local) else { throw MetadataError.invalid("piece layers are incomplete") }; bytes.append(hash) }
			layers[root] = bytes
		}
		return layers
	}
}
