import Foundation
import CryptoKit

/// DHTIdentity implements the address-bound node IDs specified by BEP 42.
public enum DHTIdentity {
	public static func make(address: IPAddress?, entropy: Data? = nil) throws -> Data {
		var id = entropy ?? Data((0..<20).map { _ in UInt8.random(in: 0...255) })
		guard id.count == 20 else { throw NetworkFailure.invalid("DHT identity length") }
		if let address {
			let crc = prefix(address, random: id[19])
			id[0] = UInt8(crc >> 24); id[1] = UInt8((crc >> 16) & 255); id[2] = UInt8((crc >> 8) & 248) | (id[2] & 7)
		}
		return id
	}
	public static func valid(_ id: Data, address: IPAddress) -> Bool {
		guard id.count == 20 else { return false }
		if address.isLocal { return true }
		let crc = prefix(address, random: id[19])
		return id[0] == UInt8(crc >> 24) && id[1] == UInt8((crc >> 16) & 255) && id[2] & 248 == UInt8((crc >> 8) & 248)
	}
	private static func prefix(_ address: IPAddress, random: UInt8) -> UInt32 {
		let masks: [UInt8] = address.isIPv6 ? [1, 3, 7, 15, 31, 63, 127, 255] : [3, 15, 63, 255]
		var bytes = zip(address.bytes, masks).map { $0 & $1 }; bytes[0] |= (random & 7) << 5
		var crc = UInt32.max
		for byte in bytes {
			crc ^= UInt32(byte)
			for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0x82f63b78 }
		}
		return ~crc
	}
}

struct DHTContact: Sendable {
	let id: Data
	let endpoint: NetworkEndpoint
	var seen: TimeInterval = 0
	var failures = 0
}

/// Only responsive contacts enter buckets; referrals remain lookup-local until challenged.
struct DHTRoutingTable {
	var id: Data
	var buckets: [Int: [DHTContact]] = [:]
	mutating func insert(_ contact: DHTContact, now: TimeInterval) {
		guard contact.id != id, DHTIdentity.valid(contact.id, address: contact.endpoint.address) else { return }
		let prefix = zip(id, contact.id).reduce(into: (bits: 0, done: false)) { state, pair in
			guard !state.done else { return }
			let delta = pair.0 ^ pair.1
			if delta == 0 { state.bits += 8 } else { state.bits += delta.leadingZeroBitCount; state.done = true }
		}.bits
		var bucket = (buckets[prefix] ?? []).filter { now - $0.seen < 900 && $0.failures < 2 }
		bucket.removeAll { $0.id == contact.id || $0.endpoint == contact.endpoint }
		if bucket.count < 8 { var fresh = contact; fresh.seen = now; fresh.failures = 0; bucket.append(fresh) }
		buckets[prefix] = bucket
	}
	mutating func failed(_ endpoint: NetworkEndpoint) {
		for key in Array(buckets.keys) {
			if let index = buckets[key]?.firstIndex(where: { $0.endpoint == endpoint }) { buckets[key]![index].failures += 1 }
		}
	}
	func closest(_ target: Data, now: TimeInterval, count: Int = 8) -> [DHTContact] {
		Array(buckets.values.flatMap { $0 }.filter { now - $0.seen < 900 && $0.failures < 2 }.sorted { Self.nearer($0.id, $1.id, to: target) }.prefix(count))
	}
	static func nearer(_ a: Data, _ b: Data, to target: Data) -> Bool {
		for index in 0..<20 { let x = a[index] ^ target[index], y = b[index] ^ target[index]; if x != y { return x < y } }; return false
	}
}

struct DHTTokens {
	let secret = SymmetricKey(size: .bits256)
	func token(address: IPAddress, bucket: Int64) -> Data {
		var bytes = address.bytes; PacketBytes.append(bucket, to: &bytes)
		return Data(HMAC<SHA256>.authenticationCode(for: bytes, using: secret).prefix(8))
	}
	func valid(_ token: Data, address: IPAddress, now: TimeInterval) -> Bool {
		let bucket = Int64(now / 300)
		// Fixed-sized tokens, compared without a data-dependent early exit.
		guard token.count == 8 else { return false }
		return [bucket, bucket - 1].contains { candidate in zip(token, self.token(address: address, bucket: candidate)).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0 }
	}
}
