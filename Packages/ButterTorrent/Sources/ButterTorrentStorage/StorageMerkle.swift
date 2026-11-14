import Foundation
import CryptoKit
import ButterTorrentMetadata

private struct HashCheckpoint: Codable {
	var version = 1
	let identity: Data
	let records: [Data: MerkleTreeRecord]
}

public enum HybridLayerVerification: Sendable, Equatable {
	case incomplete(legacyPieces: Set<Int>)
	case verified(Set<Int>)
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
			try state.persistHashes(candidate)
		}
	}
	/// Checks a fully received hybrid piece against v1 without recording verified progress.
	public func verifyLegacyCandidate(piece: Int) async throws -> Bool {
		try await worker.run { [state] cancellation in
			let profile = state.beginVerificationProfile(); defer { state.finishVerificationProfile(profile) }
			try state.ready(); let (file, _) = try state.hybridFile(containing: piece)
			state.writeDescriptors.discard(files: file.index..<(file.index + 1))
			let stamps = try state.observe(piece: piece)
			let valid = try state.digestPiece(piece, check: cancellation.check).legacyValid
			guard try state.observe(piece: piece) == stamps else { throw StorageFailure.invalid("payload changed during verification") }
			return valid
		}
	}
	/// Reconstructs one full v2 file layer from v1-verified bytes and publishes progress only after both checks.
	public func reconstructHybridLayer(containing piece: Int) async throws -> HybridLayerVerification {
		let result = try await worker.run(bulk: true) { [state] cancellation in
			let profile = state.beginVerificationProfile(); defer { state.finishVerificationProfile(profile) }
			let result = try state.reconstructHybridLayer(containing: piece, check: cancellation.check); return (result, state.checkpointDeadline)
		}
		armCheckpointTimer(result.1); return result.0
	}
	public func hashResponse(_ request: MerkleHashRequest) async throws -> Data? {
		try await worker.run { [state] cancellation in try state.hashResponse(request, check: cancellation.check) }
	}
	public func exportMetadata() async throws -> Data {
		try await flush()
		return try await worker.run { [state] _ in
			try state.ready()
			return state.merkle.index.enabled ? try state.metadata.withPieceLayers(state.merkle.completeLayers()) : state.metadata.document.original
		}
	}
}

extension StorageState {
	func persistHashes(_ candidate: MerkleCatalog) throws {
		let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
		let bytes = try encoder.encode(HashCheckpoint(identity: record.metadataHash, records: candidate.records))
		guard bytes.count <= 100_663_296 else { throw StorageFailure.limit("hash checkpoint") }
		try state.atomic(bytes, path: "hashes.plist")
		for piece in candidate.available.subtracting(merkle.available) {
			recoveryChecked[piece / 8] &= ~UInt8(128 >> (piece % 8))
		}
		merkle = candidate
		event(.pieceLayersChanged)
	}
	func hybridFile(containing piece: Int) throws -> (file: MerkleIndex.File, start: Int) {
		guard metadata.hashes.v1 != nil, let mapping = merkle.index.pieces[piece], let file = merkle.index.files[mapping.root] else {
			throw StorageFailure.invalid("hybrid piece required")
		}
		return (file, piece - mapping.local)
	}
	func reconstructHybridLayer(containing piece: Int, check: () throws -> Void) throws -> HybridLayerVerification {
		try ready(); try invalidateChangedFiles()
		let (file, start) = try hybridFile(containing: piece)
		writeDescriptors.discard(files: file.index..<(file.index + 1))
		let before = try stamps()
		var layer = Data(capacity: file.pieces * 32), legacyPieces: Set<Int> = []
		for index in start..<(start + file.pieces) {
			try check()
			do {
				let digest = try digestPiece(index, check: check)
				if digest.legacyValid, let root = digest.root { layer.append(root); legacyPieces.insert(index) }
			} catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { }
			catch StorageFailure.invalid("short payload read") { }
		}
		guard try stamps() == before else { throw StorageFailure.invalid("payload changed during verification") }
		guard legacyPieces.count == file.pieces else { return .incomplete(legacyPieces: legacyPieces) }
		var candidate = merkle
		try candidate.installLayer(layer, root: file.root)
		try check(); try persistHashes(candidate)
		let newlyVerified = legacyPieces.filter { !record.contains($0) }
		for index in legacyPieces.sorted() {
			try prepareVerification(of: index)
			guard try stamps() == before else { throw StorageFailure.invalid("payload changed during verification") }
			try requireFlush(piece: index); record.set(index, true)
			if case .batched = checkpointPolicy, newlyVerified.contains(index) { try self.newlyVerified(index) }
			guard try stamps() == before else { throw StorageFailure.invalid("payload changed during verification") }
		}
		if case .immediate = checkpointPolicy {
			do { try save() }
			catch { for index in newlyVerified { record.set(index, false) }; throw error }
		}
		return .verified(Set(legacyPieces.filter(record.contains)))
	}

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
