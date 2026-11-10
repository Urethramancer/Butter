import Foundation

extension TorrentMetadata {
	/// Replaces tracker fields while retaining the exact original info dictionary.
	public func withTrackerTiers(_ tiers: [[String]]) throws -> Data {
		guard tiers.count <= 32, tiers.reduce(0, { $0 + $1.count }) <= 128,
			tiers.flatMap({ $0 }).allSatisfy({ !$0.isEmpty && !$0.utf8.contains(0) && $0.utf8.count <= 8192 }) else { throw MetadataError.invalid("tracker tiers") }
		var fields = document.root.dictionary!
		fields.removeValue(forKey: Data("announce".utf8)); fields.removeValue(forKey: Data("announce-list".utf8))
		let tiers = tiers.filter { !$0.isEmpty }
		if let first = tiers.first?.first {
			fields[Data("announce".utf8)] = .bytes(Data(first.utf8))
			fields[Data("announce-list".utf8)] = .list(tiers.map { .list($0.map { .bytes(Data($0.utf8)) }) })
		}
		return try Self.envelope(info: originalInfo, fields: fields)
	}
	/// Validates every supplied magnet identity before exposing received metadata.
	public init(infoBytes: Data, expected: InfoHashes, trackers: [String] = []) throws {
		guard trackers.count <= 128 else { throw MetadataError.limit("tracker hints") }
		let hashes = TorrentHasher.hash(infoBytes)
		guard expected.v1 == nil || expected.v1 == hashes.sha1, expected.v2 == nil || expected.v2 == hashes.sha256 else { throw MetadataError.invalid("received metadata identity") }
		var fields: [Data: BencodeValue] = [:]
		if let first = trackers.first {
			fields[Data("announce".utf8)] = .bytes(Data(first.utf8))
			fields[Data("announce-list".utf8)] = .list(trackers.map { .list([.bytes(Data($0.utf8))]) })
		}
		try self.init(Self.envelope(info: infoBytes, fields: fields))
		guard expected.v1 == nil || self.hashes.v1 == expected.v1, expected.v2 == nil || self.hashes.v2 == expected.v2 else { throw MetadataError.invalid("magnet hash kind") }
	}
	public func withPieceLayers(_ layers: [Data: Data]) throws -> Data {
		var fields = document.root.dictionary!
		fields[Data("piece layers".utf8)] = .dictionary(layers.mapValues(BencodeValue.bytes))
		return try Self.envelope(info: originalInfo, fields: fields)
	}
	private static func envelope(info: Data, fields: [Data: BencodeValue]) throws -> Data {
		guard try BencodeDocument(info).root.dictionary != nil else { throw MetadataError.invalid("info dictionary") }
		var fields = fields; fields[Data("info".utf8)] = .integer(0)
		var bytes = Data([100])
		for key in fields.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
			bytes.append(try BencodeValue.bytes(key).encoded())
			bytes.append(try key == Data("info".utf8) ? info : fields[key]!.encoded())
			guard bytes.count < 33_554_432 else { throw MetadataError.limit("metadata envelope") }
		}
		bytes.append(101); return bytes
	}
}
