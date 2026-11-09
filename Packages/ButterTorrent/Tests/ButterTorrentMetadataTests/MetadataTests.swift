import Foundation
import Testing
@testable import ButterTorrentMetadata

@Suite struct BencodingTests {
	@Test func binaryRoundTripAndCanonicalOrdering() throws {
		let value = BencodeValue.dictionary([
			Data([255]): .bytes(Data([0, 128, 255])),
			Data([0]): .list([.integer(.min), .integer(.max), .bytes(Data())])
		])
		let encoded = try value.encoded()
		#expect(Array(encoded.prefix(4)) == [100, 49, 58, 0])
		#expect(try BencodeDocument(encoded).root == value)
	}
	@Test(arguments: ["", "i", "ie", "i-0e", "i00e", "i+1e", "i01e", "i9223372036854775808e", "i-9223372036854775809e", "00:", "1", "2:a", "99999999999999999999999:", "leX", "li1e", "d1:ai1e1:ai2ee", "di1ei2ee", "d1:ae"])
	func malformedInput(_ text: String) {
		#expect(throws: MetadataError.self) { try BencodeDocument(Data(text.utf8)) }
	}
	@Test func retainsOriginalInfoInsteadOfReencoding() throws {
		// Out-of-order keys are tolerated, but their original bytes determine identity.
		let raw = Data("d4:infod1:zi1e1:ai2ee7:comment4:infoe".utf8)
		let document = try BencodeDocument(raw)
		#expect(document.infoBytes == Data("d1:zi1e1:ai2ee".utf8))
		#expect(try document.root["info"]?.encoded() != document.infoBytes)
		let sliced = Data([0, 0]) + raw
		#expect(try BencodeDocument(sliced.dropFirst(2)).infoBytes == document.infoBytes)
		#expect(try BencodeDocument(Data("ld4:infoi1eee".utf8)).infoBytes == nil)
	}
	@Test func resourceBounds() throws {
		let nested = Data("lllee e".replacingOccurrences(of: " ", with: "").utf8)
		#expect(throws: MetadataError.self) { try BencodeDocument(nested, limits: .init(depth: 1)) }
		#expect(throws: MetadataError.self) { try BencodeDocument(Data("3:abc".utf8), limits: .init(bytes: 4)) }
		#expect(throws: MetadataError.self) { try BencodeDocument(Data("li1ei2ee".utf8), limits: .init(values: 2)) }
		#expect(throws: MetadataError.self) { try BencodeValue.bytes(Data(repeating: 0, count: 8)).encoded(limits: .init(bytes: 8)) }
		#expect(throws: MetadataError.self) { try BencodeValue.list([.list([])]).encoded(limits: .init(depth: 0)) }
		#expect(throws: MetadataError.self) { try BencodeValue.list([.integer(1)]).encoded(limits: .init(values: 1)) }
	}
	@Test func deterministicMalformedCorpus() {
		var state: UInt64 = 0x524F4F54
		for length in 0..<256 {
			let bytes = Data((0..<length).map { _ -> UInt8 in
				state = state &* 6364136223846793005 &+ 1
				return UInt8(truncatingIfNeeded: state >> 32)
			})
			// Resource-bounded arbitrary input must return or throw without trapping.
			_ = try? BencodeDocument(bytes, limits: .init(bytes: 256, depth: 8, values: 64))
		}
	}
}

@Suite struct IdentifierTests {
	@Test(arguments: [
		("", "da39a3ee5e6b4b0d3255bfef95601890afd80709", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
		("abc", "a9993e364706816aba3e25717850c26c9cd0d89d", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
		("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", "84983e441c3bd26ebaae4aa1f95129e5e54670f1", "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
	])
	func knownVectors(_ vector: (String, String, String)) {
		var incremental = TorrentHasher()
		for byte in vector.0.utf8 { incremental.update(Data([byte])) }
		let digest = incremental.finalise(), bulk = TorrentHasher.hash(Data(vector.0.utf8))
		#expect(digest.sha1.hex == vector.1 && digest.sha256.hex == vector.2)
		#expect(digest.sha1 == bulk.sha1 && digest.sha256 == bulk.sha256)
		#expect(incremental.finalise().sha1 == digest.sha1)
	}
	@Test func millionByteVectorsAcrossBlockBoundaries() {
		var hasher = TorrentHasher()
		for _ in 0..<1000 { hasher.update(Data(repeating: 97, count: 1000)) }
		let digest = hasher.finalise()
		#expect(digest.sha1.hex == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
		#expect(digest.sha256.hex == "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
	}
	@Test func identifierValidation() throws {
		#expect(throws: MetadataError.self) { try InfoHashes() }
		#expect(throws: MetadataError.self) { try InfoHashes(v1: Data(repeating: 0, count: 19)) }
		#expect(throws: MetadataError.self) { try InfoHashes(v2: Data(repeating: 0, count: 20)) }
		#expect(throws: MetadataError.self) { try InfoHashes(hex: [String(repeating: "z", count: 40)]) }
		#expect(throws: MetadataError.self) { try InfoHashes(hex: [String(repeating: "a", count: 40), String(repeating: "a", count: 40)]) }
	}
}

@Suite struct MagnetTests {
	@Test func hybridRoundTripAndQueryEscaping() throws {
		let hashes = try InfoHashes(v1: Data(repeating: 42, count: 20), v2: Data(repeating: 255, count: 32))
		let value = Magnet(hashes: hashes, name: "Å + &?#/", trackers: ["https://tracker.invalid/announce?x=1&y=2", "udp://[::1]:80"], webSeeds: ["https://seed.invalid/a+b/"], peers: ["[::1]:6881"])
		#expect(try Magnet(value.uri) == value)
		#expect(value.uri.contains("xt=urn:btmh:1220"))
		#expect(value.uri.contains("%2b") && value.uri.contains("%26"))
	}
	@Test func base32AndRepeatedTopics() throws {
		let magnet = try Magnet("magnet:?xt=urn:btih:AERUKZ4JVPG66AJDIVTYTK6N54ASGRLH&dn=a+b%2Bc&tr=one&tr=two&xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
		#expect(magnet.hashes.hex == ["0123456789abcdef0123456789abcdef01234567"])
		#expect(magnet.name == "a b+c" && magnet.trackers == ["one", "two"])
	}
	@Test(arguments: [
		"", "https://example.com", "magnet:?dn=no-hash", "magnet:?xt=urn:btih:xyz",
		"magnet:?xt=urn:btmh:1220abcd", "magnet:?xt=urn:btih:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA!",
		"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=%xx",
		"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=%00",
		"magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&xt=urn:btih:1123456789abcdef0123456789abcdef01234567"
	])
	func malformedMagnets(_ uri: String) {
		#expect(throws: MetadataError.self) { try Magnet(uri) }
	}
}
