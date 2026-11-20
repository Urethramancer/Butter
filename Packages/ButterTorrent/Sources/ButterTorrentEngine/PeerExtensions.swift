import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking

func extensionDictionary(_ fields: [String: BencodeValue]) -> BencodeValue { .dictionary(Dictionary(uniqueKeysWithValues: fields.map { (Data($0.key.utf8), $0.value) })) }

struct ExtensionHandshake {
	var client = ""
	var ids: [String: Int] = [:]
	var metadataSize: Int?
	var port: UInt16?
	var queueLimit = 32
	mutating func apply(_ bytes: Data) throws {
		let root = try BencodeDocument(bytes, limits: .init(bytes: 32_768, depth: 12, values: 1024)).root
		guard root.dictionary != nil else { throw PeerFailure.invalid("extension handshake") }
		if let name = root["v"]?.text { client = String(name.prefix(256)) }
		if let map = root["m"] {
			guard let fields = map.dictionary, fields.count <= 64 else { throw PeerFailure.limit("extension map") }
			for (name, value) in fields {
				guard let name = String(data: name, encoding: .utf8), name.utf8.count <= 64, let id = value.integer, (0...255).contains(id) else { throw PeerFailure.invalid("extension ID") }
				ids[name] = id == 0 ? nil : Int(id)
			}
			guard ids.count <= 64 else { throw PeerFailure.limit("accumulated extension map") }
			guard Set(ids.values).count == ids.count else { throw PeerFailure.invalid("duplicate extension IDs") }
		}
		if let size = root["metadata_size"] {
			guard let count = size.integer, (0...33_554_432).contains(count) else { throw PeerFailure.limit("metadata size") }; metadataSize = count == 0 ? nil : Int(count)
		}
		if let port = root["p"]?.integer { guard (0...65535).contains(port) else { throw PeerFailure.invalid("extension port") }; self.port = port == 0 ? nil : UInt16(port) }
		if let queue = root["reqq"]?.integer { guard (1...65536).contains(queue) else { throw PeerFailure.invalid("request queue") }; queueLimit = min(48, Int(queue)) }
	}
}

public struct ExchangedPeer: Sendable {
	public let endpoint: NetworkEndpoint
	public let flags: UInt8
}
struct PeerExchange {
	let added: [ExchangedPeer]
	let dropped: [NetworkEndpoint]
	init(_ data: Data) throws {
		let root = try BencodeDocument(data, limits: .init(bytes: 16_384, depth: 8, values: 128)).root
		guard root.dictionary != nil else { throw PeerFailure.invalid("PEX dictionary") }
		var added: [ExchangedPeer] = [], dropped: [NetworkEndpoint] = []
		for (suffix, size) in [("", 4), ("6", 16)] {
			for (name, isAdded) in [("added" + suffix, true), ("dropped" + suffix, false)] {
				guard let field = root[name] else { continue }
				guard let bytes = field.bytes, bytes.count % (size + 2) == 0, bytes.count / (size + 2) <= 50 else { throw PeerFailure.limit("PEX contacts") }
				let flags = root[name + ".f"]?.bytes
				guard flags == nil || flags!.count == bytes.count / (size + 2) else { throw PeerFailure.invalid("PEX flags") }
				for offset in stride(from: 0, to: bytes.count, by: size + 2) {
					let address = try IPAddress(bytes: bytes.subdata(in: offset..<(offset + size))), port = UInt16(bytes[offset + size]) << 8 | UInt16(bytes[offset + size + 1])
					guard port > 0, !address.isUnspecified, !address.isMulticast else { throw PeerFailure.invalid("PEX endpoint") }
					let endpoint = NetworkEndpoint(address: address, port: port)
					if isAdded { added.append(ExchangedPeer(endpoint: endpoint, flags: flags?[offset / (size + 2)] ?? 0)) } else { dropped.append(endpoint) }
				}
			}
		}
		guard added.count <= 50, dropped.count <= 50, Set(added.map(\.endpoint)).count == added.count, Set(dropped).count == dropped.count else { throw PeerFailure.invalid("duplicate/excess PEX contacts") }
		self.added = added; self.dropped = dropped
	}
	static func encode(added: [ExchangedPeer], dropped: [NetworkEndpoint]) throws -> Data {
		var fields: [String: BencodeValue] = [:]
		for (suffix, v6) in [("", false), ("6", true)] {
			var contacts = Data(), flags = Data(), removals = Data()
			func append(_ endpoint: NetworkEndpoint, to bytes: inout Data) { bytes.append(endpoint.address.bytes); bytes.append(UInt8(endpoint.port >> 8)); bytes.append(UInt8(endpoint.port & 255)) }
			for peer in added where peer.endpoint.address.isIPv6 == v6 { append(peer.endpoint, to: &contacts); flags.append(peer.flags) }
			for endpoint in dropped where endpoint.address.isIPv6 == v6 { append(endpoint, to: &removals) }
			if !contacts.isEmpty { fields["added" + suffix] = .bytes(contacts); fields["added" + suffix + ".f"] = .bytes(flags) }
			if !removals.isEmpty { fields["dropped" + suffix] = .bytes(removals) }
		}
		return try extensionDictionary(fields).encoded()
	}
}

func allowedFast(address: IPAddress?, infoHash: Data, pieces: Int) -> Set<Int> {
	guard pieces > 0, let address else { return [] }
	var prefix = address.bytes
	if address.isIPv6 { prefix.replaceSubrange(8..<16, with: Data(repeating: 0, count: 8)) } else { prefix[3] = 0 }
	var digest = prefix + infoHash, result: Set<Int> = []
	while result.count < min(10, pieces) {
		digest = TorrentHasher.hash(digest).sha1
		for offset in stride(from: 0, to: 20, by: 4) {
			let index = (offset..<offset + 4).reduce(UInt32(0)) { $0 << 8 | UInt32(digest[$1]) }
			result.insert(Int(index % UInt32(pieces))); if result.count == min(10, pieces) { break }
		}
	}
	return result
}
