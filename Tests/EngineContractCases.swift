import Foundation

// Shared app-facing assertions. A future Swift adapter supplies the same factory.
enum EngineContractCases {
	struct Failure: Error, CustomStringConvertible { let description: String }
	static func require(_ value: Bool, _ message: String) throws {
		if !value { throw Failure(description: message) }
	}
	static func object(_ data: Data) throws -> [String: Any] {
		guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
			throw Failure(description: "Expected an engine response object")
		}
		return value
	}
	static func reject(_ engine: any EngineOperations, _ command: String, _ payload: [String: Any]) async throws {
		do { _ = try await engine.perform(command, payload) }
		catch { return }
		throw Failure(description: "Accepted invalid \(command) payload")
	}
	static func run(makeEngine: (URL) -> any EngineOperations) async throws {
		let fm = FileManager.default
		let root = fm.temporaryDirectory.appendingPathComponent("ButterContract-\(UUID().uuidString)")
		try fm.createDirectory(at: root, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) }
		let storage = root.appendingPathComponent("engine"), seed = root.appendingPathComponent("seed")
		try fm.createDirectory(at: seed, withIntermediateDirectories: true)
		let source = seed.appendingPathComponent("fixture.bin")
		let bytes = Data((0..<65_537).map { UInt8(($0 * 71 + $0 / 97) % 251) })
		try bytes.write(to: source)
		let engine = makeEngine(storage)
		// Inspection and creation need no listening sockets or public services.
		let empty = try await engine.snapshot()
		try require(empty.transfers.isEmpty && empty.port == 0 && !empty.udp, "Session opened sockets before settings")
		for value: Any in [1, NSNull(), [], [:]] {
			try await reject(engine, "inspect", ["source": value])
		}
		let created = try object(await engine.perform("create", ["id": "fixture", "source": source.path, "private": false, "trackers": []]))
		guard let torrent = created["source"] as? String else { throw Failure(description: "Missing created source") }
		try require(created["destination"] as? String == seed.path, "Creation lost source-seeding location")
		let preview = try JSONDecoder().decode(MetadataPreview.self, from: await engine.perform("inspect", ["source": torrent]))
		try require(preview.name == "fixture.bin" && !preview.private, "Incorrect metadata preview")
		try require(preview.hashes.map(\.count) == [40, 64], "Creation must retain hybrid identity")
		try require(preview.files.count == 1 && preview.files[0].size == Int64(bytes.count) && !preview.files[0].pad, "Incorrect file layout")
		for id in ["", "../escape", "/absolute", "a/b", ".", "a.b"] {
			try await reject(engine, "add", ["id": id, "source": torrent, "destination": seed.path])
		}
		try await reject(engine, "add", ["id": "bad", "source": torrent, "destination": "relative"])
		let added = try object(await engine.perform("add", ["id": "fixture", "source": torrent, "destination": seed.path]))
		try require(added["duplicate"] as? Bool == false && added["hashes"] as? [String] == preview.hashes, "Import changed identity")
		try await reject(engine, "add", ["id": "fixture", "source": torrent, "destination": seed.path])
		let duplicate = try object(await engine.perform("add", ["id": "other", "source": torrent, "destination": seed.path]))
		try require(duplicate["duplicate"] as? Bool == true && duplicate["id"] as? String == "fixture", "Duplicate did not resolve to existing ID")
		let imported = try await engine.snapshot()
		try require(imported.transfers.count == 1, "Duplicate published another transfer")
		let row = imported.transfers[0]
		try require(row.state == "Paused" && row.hashes == preview.hashes && row.metadata, "Import must start paused with metadata")
		try require(row.files[0].original == "fixture.bin" && row.files[0].path == "fixture.bin", "Import changed file paths")
		_ = try await engine.perform("select", ["id": "fixture", "selected": [0]])
		let selected = try await engine.snapshot()
		try require(!selected.transfers[0].files[0].selected, "Selection did not reach snapshot")
		_ = try await engine.perform("select", ["id": "fixture", "selected": [1]])
		let magnet = try object(await engine.perform("magnet", ["id": "fixture"]))
		guard let link = magnet["magnet"] as? String else { throw Failure(description: "Missing magnet") }
		try require(preview.hashes.allSatisfy { link.contains($0) }, "Magnet lost hybrid identity")
		let exported = try await engine.perform("export", ["id": "fixture"])
		let exportedURL = root.appendingPathComponent("export.torrent")
		try exported.write(to: exportedURL)
		let exportedPreview = try JSONDecoder().decode(MetadataPreview.self, from: await engine.perform("inspect", ["source": exportedURL.path]))
		try require(exportedPreview.hashes == preview.hashes, "Export changed info identity")
		_ = try await engine.perform("shutdown")
		_ = try await engine.perform("remove", ["id": "fixture", "retainState": true])
		try require(fm.fileExists(atPath: storage.appendingPathComponent("fixture.torrent").path), "Removal lost retained state")
		let restored = makeEngine(storage)
		_ = try await restored.perform("add", ["id": "fixture", "source": torrent, "destination": seed.path, "restore": true])
		let recovery = try await restored.snapshot()
		try require(recovery.transfers.count == 1 && recovery.transfers[0].hashes == preview.hashes, "Restore lost identity")
		_ = try await restored.perform("shutdown")
		_ = try await restored.perform("remove", ["id": "fixture"])
		let retainedBytes = try Data(contentsOf: source)
		try require(retainedBytes == bytes, "Ordinary removal changed source bytes")
		try require(!fm.fileExists(atPath: storage.appendingPathComponent("fixture.torrent").path), "Removal retained obsolete engine metadata")
		try await reject(restored, "run", ["id": "fixture", "running": true])
	}
}
