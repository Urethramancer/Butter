import Foundation

@main struct MetadataComparisonTests {
	struct Record: Decodable {
		let file: String
		let inspection: TorrentMetadata.Inspection
		let magnet: String
	}
	static func main() async {
		do {
			guard CommandLine.arguments.count == 2 else { throw MetadataError.invalid("expected reference fixtures") }
			let root = URL(fileURLWithPath: CommandLine.arguments[1])
			let records = try JSONDecoder().decode([Record].self, from: Data(contentsOf: root.appendingPathComponent("reference.json")))
			let engine = EngineClient(storage: root.appendingPathComponent("swift-magnets"))
			for (index, record) in records.enumerated() {
				let metadata = try TorrentMetadata(contentsOf: root.appendingPathComponent(record.file))
				guard metadata.inspection == record.inspection else {
					throw MetadataError.invalid("\(record.file): Swift \(metadata.inspection) differs from reference \(record.inspection)")
				}
				let reference = try Magnet(record.magnet)
				let native = Magnet(hashes: metadata.hashes, name: metadata.inspection.name, trackers: reference.trackers)
				guard try Magnet(native.uri) == reference else { throw MetadataError.invalid("magnet fields differ") }
				let result = try await engine.perform("add", ["id": "magnet-\(index)", "source": native.uri, "destination": root.appendingPathComponent("download-\(index)").path])
				guard let response = try JSONSerialization.jsonObject(with: result) as? [String: Any], response["hashes"] as? [String] == metadata.hashes.hex else {
					throw MetadataError.invalid("reference rejected native magnet identity")
				}
				_ = try await engine.perform("remove", ["id": "magnet-\(index)"])
			}
			_ = try await engine.perform("shutdown")
			print("PASS: \(records.count) reference metadata layouts, sanitised paths and Swift magnet imports match libtorrent")
		} catch {
			fputs("FAIL: \(error)\n", stderr); exit(1)
		}
	}
}
