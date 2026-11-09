import Foundation

/// Magnet represents full v1/v2 identity and the discovery hints in a magnet URI.
public struct Magnet: Equatable, Sendable {
	public let hashes: InfoHashes
	public var name: String
	public var trackers: [String]
	public var webSeeds: [String]
	public var peers: [String]
	public init(hashes: InfoHashes, name: String = "", trackers: [String] = [], webSeeds: [String] = [], peers: [String] = []) {
		self.hashes = hashes; self.name = name; self.trackers = trackers; self.webSeeds = webSeeds; self.peers = peers
	}
	public init(_ uri: String) throws {
		guard uri.utf8.count <= 1024 * 1024 else { throw MetadataError.limit("magnet byte") }
		guard uri.hasPrefix("magnet:?"), !uri.contains("#") else { throw MetadataError.invalid("invalid magnet URI") }
		var v1: Data?, v2: Data?, name = "", trackers: [String] = [], seeds: [String] = [], peers: [String] = []
		for field in uri.dropFirst(8).split(separator: "&", omittingEmptySubsequences: true) {
			let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
			guard pair.count == 2 else { continue }
			let key = try Self.decode(String(pair[0])), value = try Self.decode(String(pair[1]))
			switch key {
			case "xt":
				if value.hasPrefix("urn:btih:") {
					let text = String(value.dropFirst(9))
					let hash = text.count == 32 ? Self.base32(text) : Data(hex: text)
					guard let hash, hash.count == 20, v1 == nil || v1 == hash else { throw MetadataError.invalid("invalid or conflicting btih") }
					v1 = hash
				} else if value.hasPrefix("urn:btmh:") {
					let text = String(value.dropFirst(9))
					guard text.hasPrefix("1220"), let hash = Data(hex: String(text.dropFirst(4))), hash.count == 32,
						v2 == nil || v2 == hash else { throw MetadataError.invalid("invalid or conflicting btmh") }
					v2 = hash
				}
			case "dn": if name.isEmpty { name = value }
			case "tr": trackers.append(value)
			case "ws": seeds.append(value)
			case "x.pe": peers.append(value)
			default: break
			}
		}
		try self.init(hashes: InfoHashes(v1: v1, v2: v2), name: name, trackers: trackers, webSeeds: seeds, peers: peers)
	}
	public var uri: String {
		var fields: [String] = []
		if let v1 = hashes.v1 { fields.append("xt=urn:btih:\(v1.hex)") }
		if let v2 = hashes.v2 { fields.append("xt=urn:btmh:1220\(v2.hex)") }
		if !name.isEmpty { fields.append("dn=\(Self.encode(name))") }
		fields += trackers.map { "tr=\(Self.encode($0))" }
		fields += webSeeds.map { "ws=\(Self.encode($0))" }
		fields += peers.map { "x.pe=\(Self.encode($0))" }
		return "magnet:?" + fields.joined(separator: "&")
	}
	private static func encode(_ value: String) -> String {
		value.utf8.map { byte in
			switch byte {
			case 65...90, 97...122, 48...57, 45, 46, 95, 126: String(UnicodeScalar(byte))
			default: String(format: "%%%02x", byte)
			}
		}.joined()
	}
	private static func decode(_ value: String) throws -> String {
		// Magnet query escaping follows form rules: raw + is a space, %2B is +.
		guard let result = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
			!result.utf8.contains(0) else { throw MetadataError.invalid("invalid magnet escaping") }
		return result
	}
	private static func base32(_ text: String) -> Data? {
		var result = Data(), accumulator: UInt32 = 0, bits = 0
		for byte in text.uppercased().utf8 {
			let digit: UInt32
			switch byte {
			case 65...90: digit = UInt32(byte - 65)
			case 50...55: digit = UInt32(byte - 24)
			default: return nil
			}
			accumulator = (accumulator << 5) | digit; bits += 5
			if bits >= 8 { bits -= 8; result.append(UInt8((accumulator >> bits) & 255)) }
		}
		return bits == 0 ? result : nil
	}
}
