import Foundation
import ButterTorrentMetadata

enum DHTWire {
	static func dictionary(_ fields: [String: BencodeValue]) -> BencodeValue { .dictionary(Dictionary(uniqueKeysWithValues: fields.map { (Data($0.key.utf8), $0.value) })) }
	static func encode(_ fields: [String: BencodeValue]) throws -> Data {
		let data = try dictionary(fields).encoded()
		guard data.count <= 1024 else { throw NetworkFailure.limit("DHT datagram") }; return data
	}
	static func decode(_ data: Data) throws -> BencodeValue {
		let value = try BencodeDocument(data, limits: .init(bytes: 4096, depth: 12, values: 512)).root
		guard value.dictionary != nil else { throw NetworkFailure.invalid("DHT packet") }; return value
	}
	static func compact(_ endpoint: NetworkEndpoint) -> Data {
		var bytes = endpoint.address.bytes; PacketBytes.append(endpoint.port, to: &bytes); return bytes
	}
	static func endpoint(_ bytes: Data) throws -> NetworkEndpoint {
		guard bytes.count == 6 || bytes.count == 18 else { throw NetworkFailure.invalid("DHT compact endpoint") }
		let endpoint = NetworkEndpoint(address: try IPAddress(bytes: bytes.dropLast(2)), port: try PacketBytes.uint16(bytes, at: bytes.count - 2))
		guard endpoint.port > 0, !endpoint.address.isUnspecified, !endpoint.address.isMulticast else { throw NetworkFailure.invalid("DHT endpoint") }; return endpoint
	}
	static func contacts(_ value: BencodeValue, source: NetworkEndpoint) throws -> [DHTContact] {
		var contacts: [DHTContact] = []
		for (key, size) in [("nodes", 26), ("nodes6", 38)] {
			guard let field = value[key] else { continue }
			guard let bytes = field.bytes, bytes.count % size == 0 else { throw NetworkFailure.invalid("DHT node list") }
			// Routers may return more than one bucket. Accept the reply without
			// increasing the number of referrals admitted from either address family.
			let limit = contacts.count + 8
			for offset in stride(from: 0, to: bytes.count, by: size) {
				let id = bytes.subdata(in: offset..<offset + 20), peer = try endpoint(bytes.subdata(in: offset + 20..<offset + size))
				guard source.address.isLocal || !peer.address.isLocal, DHTIdentity.valid(id, address: peer.address) else { continue }
				contacts.append(DHTContact(id: id, endpoint: peer))
				if contacts.count == limit { break }
			}
		}
		return contacts
	}
}
