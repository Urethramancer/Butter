import Foundation

struct StorageCheckpoint: Codable {
	var version = 1
	var generation: UInt64 = 0
	var metadataHash: Data
	var destination: String
	var paths: [String]
	var selected: [Bool]
	var spilled: [Bool]
	var stamps: [FileStamp?]
	var verified: Data
	var downloaded: Int64 = 0
	var uploaded: Int64 = 0
	var corruptBytes: Int64?
	var redundantBytes: Int64?
	var receipts: [String] = []
	func validate(layout: StorageLayout, identity: Data) throws {
		let count = layout.files.count
		guard version == 1, metadataHash == identity, destination.hasPrefix("/"), !destination.utf8.contains(0),
			paths.count == count, selected.count == count, spilled.count == count, stamps.count == count,
			downloaded >= 0, uploaded >= 0, receipts.count <= 50_000,
			verified.count == (layout.pieceCount + 7) / 8 else { throw StorageFailure.invalid("checkpoint version, identity or fields") }
		let corrupt = corruptBytes ?? 0, redundant = redundantBytes ?? 0
		guard corrupt >= 0, redundant >= 0, corrupt <= downloaded, redundant <= downloaded - corrupt else { throw StorageFailure.invalid("checkpoint payload counters") }
		guard Set(receipts).count == receipts.count, receipts.allSatisfy({ $0.hasPrefix("/") && !$0.utf8.contains(0) && $0.utf8.count <= 4096 }) else { throw StorageFailure.invalid("Trash receipts") }
		if layout.pieceCount % 8 != 0, let byte = verified.last {
			guard byte & UInt8((1 << (8 - layout.pieceCount % 8)) - 1) == 0 else { throw StorageFailure.invalid("checkpoint spare bits") }
		}
		for index in paths.indices {
			_ = try StorageLayout.components(paths[index])
			if layout.files[index].pad && (selected[index] || spilled[index]) { throw StorageFailure.invalid("padding selection") }
		}
		try StorageLayout.validatePaths(paths.indices.filter { !layout.files[$0].pad }.map { paths[$0] })
	}
	func contains(_ piece: Int) -> Bool { verified[piece / 8] & (128 >> (piece % 8)) != 0 }
	mutating func set(_ piece: Int, _ value: Bool) {
		let mask = UInt8(128 >> (piece % 8))
		if value { verified[piece / 8] |= mask } else { verified[piece / 8] &= ~mask }
	}
	func encoded() throws -> Data {
		let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
		let bytes = try encoder.encode(self)
		guard bytes.count <= 16_777_216 else { throw StorageFailure.limit("checkpoint bytes") }
		return bytes
	}
}

public struct StorageSnapshot: Sendable {
	public let destination: URL
	public let paths: [String]
	public let selected: [Bool]
	public let verifiedPieces: Set<Int>
	public let downloaded: Int64
	public let uploaded: Int64
	public let corruptBytes: Int64
	public let redundantBytes: Int64
	public let trashReceipts: [URL]
	public let needsRecovery: Bool
}
