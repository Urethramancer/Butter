import Foundation
import CryptoKit
import ButterTorrentMetadata

private struct HashCheckpoint: Codable {
	var version = 1
	let identity: Data
	let records: [Data: MerkleTreeRecord]
}

extension TorrentStorage {
	public func availableHashes() async throws -> Set<Int> {
		try await worker.run { [state] _ in
			try state.ready(); return state.merkle.index.enabled ? state.merkle.available : Set(0..<state.layout.pieceCount)
		}
	}
	public func installHashes(_ request: MerkleHashRequest, hashes: Data) async throws {
		try await worker.run { [state] cancellation in
			try state.ready(); try cancellation.check()
			var candidate = state.merkle; try candidate.install(request, hashes: hashes)
			let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
			let bytes = try encoder.encode(HashCheckpoint(identity: state.record.metadataHash, records: candidate.records))
			guard bytes.count <= 100_663_296 else { throw StorageFailure.limit("hash checkpoint") }
			try state.state.atomic(bytes, path: "hashes.plist"); state.merkle = candidate
			state.event(.pieceLayersChanged)
		}
	}
	public func hashResponse(_ request: MerkleHashRequest) async throws -> Data? {
		try await worker.run { [state] cancellation in try state.hashResponse(request, check: cancellation.check) }
	}
	public func exportMetadata() async throws -> Data {
		try await worker.run { [state] _ in
			try state.ready()
			return state.merkle.index.enabled ? try state.metadata.withPieceLayers(state.merkle.completeLayers()) : state.metadata.document.original
		}
	}
}

extension StorageState {
	func restoreHashes() throws {
		guard try state.inspect("hashes.plist") != nil else { return }
		let cache = try PropertyListDecoder().decode(HashCheckpoint.self, from: state.read("hashes.plist", maximum: 100_663_296))
		guard cache.version == 1, cache.identity == record.metadataHash else { throw StorageFailure.invalid("hash checkpoint identity or version") }
		merkle = try MerkleCatalog(metadata: metadata, restored: cache.records)
	}
	func hashResponse(_ request: MerkleHashRequest, check: () throws -> Void) throws -> Data? {
		try ready(); try check()
		guard let file = merkle.index.files[request.root] else { return nil }
		try file.validate(request)
		if request.base >= file.base { return try merkle.response(request) }
		guard request.base == 0 else { return nil }
		var loaded: [Int: Data] = [:]
		func node(_ layer: Int, _ index: Int) throws -> Data? {
			if layer >= file.base { return merkle.hash(root: file.root, layer: layer, index: index) }
			var hashes: [Data] = []
			for block in (index << layer)..<((index + 1) << layer) {
				try check()
				let offset = Int64(block) * 16384
				if offset >= file.size { hashes.append(Data(repeating: 0, count: 32)); continue }
				let local = Int(offset / metadata.pieceLength)
				guard let fileStart = merkle.index.starts[file.root]?.first(where: { record.contains($0 + local) }) else { return nil }
				let piece = fileStart + local
				if loaded[local] == nil { loaded[local] = try verifiedPiece(piece, check: check) }
				let start = Int(offset % metadata.pieceLength), count = Int(min(16384, file.size - offset))
				hashes.append(Data(SHA256.hash(data: loaded[local]!.subdata(in: start..<(start + count)))))
			}
			return try MerkleMath.root(hashes)
		}
		var result = Data()
		for index in request.index..<(request.index + request.count) { guard let hash = try node(request.base, index) else { return nil }; result.append(hash) }
		var layer = request.base + MerkleMath.log2(request.count), index = request.index / request.count
		for _ in 0..<request.proofCount {
			guard let hash = try node(layer, index ^ 1) else { return nil }; result.append(hash); layer += 1; index /= 2
		}
		return result
	}
}
