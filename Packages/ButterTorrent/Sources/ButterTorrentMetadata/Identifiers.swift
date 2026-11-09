import Foundation
import CryptoKit

/// TorrentHasher incrementally computes the SHA-1 and SHA-256 digests used by BitTorrent.
public struct TorrentHasher: Sendable {
	private var sha1 = Insecure.SHA1()
	private var sha256 = SHA256()
	public init() {}
	public mutating func update(_ data: Data) { sha1.update(data: data); sha256.update(data: data) }
	public func finalise() -> (sha1: Data, sha256: Data) { (Data(sha1.finalize()), Data(sha256.finalize())) }
	public static func hash(_ data: Data) -> (sha1: Data, sha256: Data) {
		var hasher = Self(); hasher.update(data); return hasher.finalise()
	}
}

/// InfoHashes retains full v1 and v2 identifiers, never a truncated v2 identity.
public struct InfoHashes: Equatable, Hashable, Sendable {
	public let v1: Data?
	public let v2: Data?
	public init(v1: Data? = nil, v2: Data? = nil) throws {
		guard v1 != nil || v2 != nil, v1 == nil || v1?.count == 20, v2 == nil || v2?.count == 32 else {
			throw MetadataError.invalid("invalid info hash length")
		}
		self.v1 = v1; self.v2 = v2
	}
	public var hex: [String] { [v1, v2].compactMap { $0?.hex } }
	public init(hex: [String]) throws {
		var first: Data?, second: Data?
		for text in hex {
			guard let bytes = Data(hex: text) else { throw MetadataError.invalid("invalid hexadecimal hash") }
			switch bytes.count {
			case 20 where first == nil: first = bytes
			case 32 where second == nil: second = bytes
			default: throw MetadataError.invalid("duplicate or invalid info hash")
			}
		}
		try self.init(v1: first, v2: second)
	}
}

extension Data {
	var hex: String { map { String(format: "%02x", $0) }.joined() }
	init?(hex: String) {
		let bytes = Array(hex.utf8)
		guard bytes.count.isMultiple(of: 2) else { return nil }
		var result = Data(); result.reserveCapacity(bytes.count / 2)
		func nibble(_ byte: UInt8) -> UInt8? {
			switch byte {
			case 48...57: byte - 48
			case 65...70: byte - 55
			case 97...102: byte - 87
			default: nil
			}
		}
		for index in stride(from: 0, to: bytes.count, by: 2) {
			guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
			result.append(high << 4 | low)
		}
		self = result
	}
}
