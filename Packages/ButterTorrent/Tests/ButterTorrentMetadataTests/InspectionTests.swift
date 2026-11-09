import Foundation
import Testing
@testable import ButterTorrentMetadata

@Suite struct InspectionTests {
	private func fields(_ fields: [String: BencodeValue]) -> BencodeValue {
		.dictionary(Dictionary(uniqueKeysWithValues: fields.map { (Data($0.key.utf8), $0.value) }))
	}
	private func text(_ value: String) -> BencodeValue { .bytes(Data(value.utf8)) }
	private func v1() -> [String: BencodeValue] {
		["name": text("fixture.bin"), "length": .integer(3), "piece length": .integer(16384), "pieces": .bytes(Data(repeating: 42, count: 20))]
	}
	private func torrent(_ info: [String: BencodeValue]) throws -> Data { try fields(["info": fields(info)]).encoded() }

	@Test func v1IdentityAndExactInfoBytes() throws {
		let data = try torrent(v1()), metadata = try TorrentMetadata(data)
		#expect(metadata.inspection.name == "fixture.bin")
		#expect(metadata.inspection.files.count == 1 && metadata.inspection.files[0].size == 3)
		#expect(metadata.hashes.v1 == TorrentHasher.hash(metadata.originalInfo).sha1)
		#expect(metadata.hashes.v2 == nil)
		#expect(metadata.originalInfo == (try fields(v1()).encoded()))
		#expect(try JSONDecoder().decode(TorrentMetadata.Inspection.self, from: JSONEncoder().encode(metadata.inspection)) == metadata.inspection)
	}
	@Test func v2AndHybridIdentity() throws {
		var info = v1()
		info["meta version"] = .integer(2)
		info["file tree"] = fields(["fixture.bin": fields(["": fields(["length": .integer(3), "pieces root": .bytes(Data(repeating: 42, count: 32))])])])
		let hybrid = try TorrentMetadata(torrent(info))
		#expect(hybrid.hashes.hex.map(\.count) == [40, 64])
		#expect(hybrid.inspection.files.count == 1)
		info["pieces"] = nil; info["length"] = nil
		let v2 = try TorrentMetadata(torrent(info))
		#expect(v2.hashes.v1 == nil && v2.hashes.v2 == TorrentHasher.hash(v2.originalInfo).sha256)
		#expect(v2.inspection.files.count == 2 && v2.inspection.files[1].pad)
		#expect(v2.inspection.files[1].size == 16381)
	}
	@Test func trackerTiersAndWebSeedForms() throws {
		let data = try fields([
			"info": fields(v1()), "announce": text("https://fallback.invalid/"),
			"announce-list": .list([.list([text("https://one.invalid/"), text("udp://two.invalid:80")]), .list([text("https://three.invalid/")])]),
			"url-list": text("https://seed.invalid/"), "httpseeds": .list([text("https://httpseed.invalid/")]),
			"piece layers": .dictionary([Data(repeating: 42, count: 32): .bytes(Data(repeating: 43, count: 64))])
		]).encoded()
		let metadata = try TorrentMetadata(data)
		#expect(metadata.trackerTiers.map(\.count) == [2, 1])
		#expect(metadata.webSeeds == ["https://seed.invalid/"])
		#expect(metadata.httpSeeds == ["https://httpseed.invalid/"])
		#expect(metadata.pieceLayers.count == 1)
	}
	@Test func malformedMetadataAndLayouts() throws {
		var cases: [[String: BencodeValue]] = []
		for (key, value): (String, BencodeValue) in [
			("length", .integer(-1)), ("piece length", .integer(0)), ("meta version", .integer(3)),
			("name", text("..")), ("name", .integer(1)), ("pieces", .bytes(Data(repeating: 0, count: 19))),
			("pieces", .bytes(Data())), ("piece length", .integer(.max))
		] {
			var info = v1(); info[key] = value; cases.append(info)
		}
		var hybrid = v1(); hybrid["meta version"] = .integer(2)
		hybrid["file tree"] = fields(["different.bin": fields(["": fields(["length": .integer(3), "pieces root": .bytes(Data(repeating: 42, count: 32))])])])
		cases.append(hybrid)
		for info in cases {
			let bytes = try torrent(info)
			#expect(throws: MetadataError.self) { try TorrentMetadata(bytes) }
		}
		#expect(throws: MetadataError.self) { try TorrentMetadata(Data("de".utf8)) }
	}
	@Test func boundedDiskRead() throws {
		let file = FileManager.default.temporaryDirectory.appendingPathComponent("ButterMetadata-\(UUID().uuidString)")
		defer { try? FileManager.default.removeItem(at: file) }
		let data = try torrent(v1()); try data.write(to: file)
		#expect(try TorrentMetadata(contentsOf: file, limits: .init(bytes: data.count)).inspection.name == "fixture.bin")
		#expect(throws: MetadataError.self) { try TorrentMetadata(contentsOf: file, limits: .init(bytes: data.count - 1)) }
	}
	@Test func pathsAreSanitisedWithoutChangingIdentity() throws {
		var info = v1(); info["name"] = text("../a\u{202e}b\\c\u{0000}.bin")
		let metadata = try TorrentMetadata(torrent(info))
		#expect(metadata.inspection.name == "..abc.bin")
		#expect(metadata.hashes.v1 == TorrentHasher.hash(try fields(info).encoded()).sha1)
		info["name"] = .bytes(Data([0xff, 0xe2, 0x82]))
		#expect(try TorrentMetadata(torrent(info)).inspection.name == "__")
		#expect(TorrentPath.component(Data((String(repeating: "a", count: 300) + ".txt").utf8), force: true) == String(repeating: "a", count: 240) + ".txt")
	}
}
