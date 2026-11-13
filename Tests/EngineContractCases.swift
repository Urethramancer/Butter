import Foundation
import ButterTorrentMetadata

// Shared app-facing assertions for production and the optional reference adapter.
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
	static func wait(_ engine: any EngineOperations, file: StaticString = #fileID, line: UInt = #line, until predicate: (EngineSnapshot) -> Bool) async throws -> EngineSnapshot {
		let deadline = ProcessInfo.processInfo.systemUptime + 6
		var last: EngineSnapshot?
		while ProcessInfo.processInfo.systemUptime < deadline {
			let snapshot = try await engine.snapshot(); last = snapshot; if predicate(snapshot) { return snapshot }
			try await Task.sleep(for: .milliseconds(10))
		}
		let state = try last.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? "no snapshot"
		throw Failure(description: "Engine contract deadline at \(file):\(line); last snapshot: \(state)")
	}
	static func runSystemTrash(makeEngine: (URL) -> any EngineOperations) async throws {
		let fm = FileManager.default, identifier = UUID().uuidString
		let root = fm.temporaryDirectory.appendingPathComponent("ButterTrash-\(identifier)")
		let destination = root.appendingPathComponent("payload")
		try fm.createDirectory(at: destination, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) }
		let bytes = Data([19, 23, 42]), input = destination.appendingPathComponent("ButterTrash-\(identifier).bin")
		try bytes.write(to: input)
		let trash = try fm.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: destination, create: true).standardizedFileURL.resolvingSymlinksInPath()
		let engine = makeEngine(root.appendingPathComponent("library"))
		let created = try object(await engine.perform("create", ["id": "trash", "source": input.path]))
		_ = try await engine.perform("add", ["id": "trash", "source": created["source"] as? String ?? "", "destination": destination.path])
		let removed = try object(await engine.perform("remove", ["id": "trash", "trash": true]))
		guard let paths = removed["trashed"] as? [String], paths.count == 1 else { throw Failure(description: "Expected one system Trash receipt") }
		let receipt = URL(fileURLWithPath: paths[0]).standardizedFileURL
		try require(receipt.deletingLastPathComponent().resolvingSymlinksInPath().path == trash.path && receipt.lastPathComponent.hasSuffix(input.lastPathComponent), "Receipt was outside the system Trash or named an unexpected file")
		defer { try? fm.removeItem(at: receipt) }
		try require(try Data(contentsOf: receipt) == bytes && !fm.fileExists(atPath: input.path), "System Trash did not retain exact payload bytes")
		_ = try await engine.perform("shutdown")
	}
	static func runSimultaneous(makeEngine: (URL) -> any EngineOperations) async throws {
		let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("ButterConcurrent-\(UUID().uuidString)")
		let seedData = root.appendingPathComponent("seed"), download = root.appendingPathComponent("download")
		try fm.createDirectory(at: seedData, withIntermediateDirectories: true)
		defer { try? fm.removeItem(at: root) }
		let seed = makeEngine(root.appendingPathComponent("seed-library")), down = makeEngine(root.appendingPathComponent("download-library"))
		let settings: [String: Any] = ["port": 0, "peers": 8, "torrentPeers": 4, "tcp": true, "utp": false, "dht": false, "lsd": false, "mapping": false, "pex": false]
		let bound = try object(await seed.perform("settings", settings))
		guard let port = bound["port"] as? UInt16, port > 0 else { throw Failure(description: "Seed has no owned port") }
		_ = try await down.perform("settings", settings)
		let compact = Data([127, 0, 0, 1, UInt8(port >> 8), UInt8(truncatingIfNeeded: port)])
		let tracker = try await HTTPFixture.start { request in
			let announcesSeed = request.target.split(separator: "&").contains { $0 == "port=\(port)" }
			let peers = announcesSeed ? Data() : compact
			return .init(body: Data("d8:intervali60e5:peers\(peers.count):".utf8) + peers + Data("e".utf8))
		}
		let ids = ["first", "second"]
		do {
			for (index, id) in ids.enumerated() {
				let input = seedData.appendingPathComponent(id), torrent = root.appendingPathComponent(id + ".torrent")
				try Data(repeating: UInt8(index + 9), count: 1_048_576).write(to: input)
				let metadata = try TorrentCreator.create(source: input, trackers: [tracker.url.appendingPathComponent("announce").absoluteString], isPrivate: false, pieceLength: 65536)
				try metadata.write(to: torrent)
				_ = try await seed.perform("add", ["id": id, "source": torrent.path, "destination": seedData.path])
				_ = try await down.perform("add", ["id": id, "source": torrent.path, "destination": download.path])
				_ = try await seed.perform("run", ["id": id, "running": true])
			}
			_ = try await wait(seed) { $0.transfers.count == 2 && $0.transfers.allSatisfy(\.complete) }
			for id in ids { _ = try await down.perform("run", ["id": id, "running": true, "downloadLimit": 393216]) }
			_ = try await wait(down) { $0.transfers.count == 2 && $0.transfers.allSatisfy { $0.downloaded > 0 && !$0.complete } }
			_ = try await wait(down) { $0.transfers.allSatisfy(\.complete) }
			_ = try await down.perform("shutdown"); _ = try await seed.perform("shutdown")
			for id in ids {
				let received = try Data(contentsOf: download.appendingPathComponent(id))
				try require(received == Data(contentsOf: seedData.appendingPathComponent(id)), "Simultaneous transfer changed payload")
			}
		} catch {
			_ = try? await down.perform("shutdown"); _ = try? await seed.perform("shutdown")
			await tracker.stop(); throw error
		}
		await tracker.stop()
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
		let settings = try object(await engine.perform("settings", ["port": 0, "peers": 4, "torrentPeers": 2, "tcp": true, "utp": true, "dht": false, "lsd": false, "mapping": false, "pex": false]))
		let bound = try await wait(engine) { $0.port > 0 && $0.udp }
		try require(settings["port"] as? Int == bound.port && bound.networkError.isEmpty, "Settings lost bound port ownership")
		try await reject(engine, "blocklist", ["ranges": [["first": "127.0.0.2", "last": "127.0.0.1"]]])
		_ = try await engine.perform("blocklist", ["ranges": []])
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
		let pendingSource = Magnet(hashes: try InfoHashes(hex: preview.hashes), name: "Pending fixture").uri
		let pendingDestination = root.appendingPathComponent("pending-data")
		let pendingImport = try object(await engine.perform("add", ["id": "pending", "source": pendingSource, "destination": pendingDestination.path]))
		try require(pendingImport["duplicate"] as? Bool == false && pendingImport["hashes"] as? [String] == preview.hashes, "Magnet import lost pending identity")
		let pendingDuplicate = try object(await engine.perform("add", ["id": "pending-duplicate", "source": pendingSource, "destination": pendingDestination.path]))
		try require(pendingDuplicate["duplicate"] as? Bool == true && pendingDuplicate["id"] as? String == "pending", "Pending duplicate created another row")
		let pending = try await wait(engine) { $0.transfers.first?.state == "Paused" }
		try require(pending.transfers.count == 1 && !pending.transfers[0].metadata && pending.transfers[0].files.isEmpty && pending.transfers[0].name == "Pending fixture", "Pending magnet snapshot differs")
		_ = try await engine.perform("run", ["id": "pending", "running": true])
		_ = try await wait(engine) { $0.transfers.first?.state == "Resolving metadata" }
		_ = try await engine.perform("pause", ["id": "pending"])
		_ = try await wait(engine) { $0.transfers.first?.state == "Paused" }
		try await reject(engine, "remove", ["id": "pending", "trash": true])
		_ = try await engine.perform("remove", ["id": "pending"])
		_ = try await wait(engine) { $0.transfers.isEmpty }
		for id in ["", "../escape", "/absolute", "a/b", ".", "a.b"] {
			try await reject(engine, "add", ["id": id, "source": torrent, "destination": seed.path])
		}
		try await reject(engine, "add", ["id": "bad", "source": torrent, "destination": "relative"])
		let added = try object(await engine.perform("add", ["id": "fixture", "source": torrent, "destination": seed.path, "tracker": "", "selected": []]))
		try require(added["duplicate"] as? Bool == false && added["hashes"] as? [String] == preview.hashes, "Import changed identity")
		try await reject(engine, "add", ["id": "fixture", "source": torrent, "destination": seed.path])
		let duplicate = try object(await engine.perform("add", ["id": "other", "source": torrent, "destination": seed.path]))
		try require(duplicate["duplicate"] as? Bool == true && duplicate["id"] as? String == "fixture", "Duplicate did not resolve to existing ID")
		let imported = try await engine.snapshot()
		try require(imported.transfers.count == 1, "Duplicate published another transfer")
		let row = imported.transfers[0]
		try require(["Paused", "Verification pending"].contains(row.state) && row.hashes == preview.hashes && row.metadata, "Import must start paused with metadata")
		if row.state == "Verification pending" {
			try require(row.done == 0 && !row.complete && row.pieces.allSatisfy { $0 == 0 }, "Pending verification advertised unchecked data")
		}
		try require(row.files[0].original == "fixture.bin" && row.files[0].path == "fixture.bin", "Import changed file paths")
		#if !BUTTER_REFERENCE_ENGINE
		try await reject(engine, "repairFile", ["id": "fixture", "index": 0, "source": source.path])
		try await reject(engine, "repairFile", ["id": "fixture", "index": -1, "source": source.path])
		let repairSource = root.appendingPathComponent("repair-copy.bin")
		try bytes.write(to: repairSource)
		let repaired = try object(await engine.perform("repairFile", ["id": "fixture", "index": 0, "source": repairSource.path]))
		try require(repaired["repairedFiles"] as? Int == 1 && repaired["pendingPieces"] as? Int == 0, "Repair command lost its result counts")
		try require(try Data(contentsOf: repairSource) == bytes, "Repair modified its source")
		let repairedSnapshot = try await engine.snapshot()
		try require(repairedSnapshot.transfers[0].complete && repairedSnapshot.transfers[0].state == "Paused", "Repair changed the paused state or lost verified progress")
		#endif
		_ = try await engine.perform("select", ["id": "fixture", "selected": [0]])
		_ = try await wait(engine) { $0.transfers.first?.files.first?.selected == false }
		_ = try await engine.perform("select", ["id": "fixture", "selected": [1]])
		_ = try await wait(engine) { $0.transfers.first?.files.first?.selected == true }
		let magnet = try object(await engine.perform("magnet", ["id": "fixture"]))
		guard let link = magnet["magnet"] as? String else { throw Failure(description: "Missing magnet") }
		try require(preview.hashes.allSatisfy { link.contains($0) }, "Magnet lost hybrid identity")
		let exported = try await engine.perform("export", ["id": "fixture"])
		let exportedURL = root.appendingPathComponent("export.torrent")
		try exported.write(to: exportedURL)
		let exportedPreview = try JSONDecoder().decode(MetadataPreview.self, from: await engine.perform("inspect", ["source": exportedURL.path]))
		try require(exportedPreview.hashes == preview.hashes, "Export changed info identity")
		try await reject(engine, "rename", ["id": "fixture", "changes": [["index": 0, "path": "first.bin"], ["index": 0, "path": "second.bin"]]])
		let renamed = "nested/renamed.bin", moved = root.appendingPathComponent("moved")
		_ = try await engine.perform("rename", ["id": "fixture", "changes": [["index": 0, "path": renamed]]])
		_ = try await wait(engine) { $0.transfers.first?.files.first?.path == renamed && $0.transfers.first?.state != "Renaming" }
		_ = try await engine.perform("move", ["id": "fixture", "destination": moved.path])
		var observedMove = false
		_ = try await wait(engine) { snapshot in
			observedMove = observedMove || snapshot.events.contains { $0.kind == "moved" && $0.id == "fixture" }
			guard let transfer = snapshot.transfers.first else { return false }
			return observedMove && URL(fileURLWithPath: transfer.path).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath()
		}
		_ = try await engine.perform("shutdown")
		_ = try await engine.perform("remove", ["id": "fixture", "retainState": true])
		try require(fm.fileExists(atPath: storage.appendingPathComponent("fixture.torrent").path), "Removal lost retained state")
		let restored = makeEngine(storage)
		_ = try await restored.perform("add", ["id": "fixture", "source": torrent, "destination": seed.path, "restore": true])
		let recovery = try await restored.snapshot()
		try require(recovery.transfers.count == 1 && recovery.transfers[0].hashes == preview.hashes, "Restore lost identity")
		try require(recovery.transfers[0].files[0].path == renamed, "Restore lost renamed paths")
		try require(URL(fileURLWithPath: recovery.transfers[0].path).resolvingSymlinksInPath() == moved.resolvingSymlinksInPath(), "Restore lost moved destination")
		_ = try await restored.perform("shutdown")
		_ = try await restored.perform("remove", ["id": "fixture"])
		let retainedBytes = try Data(contentsOf: moved.appendingPathComponent(renamed))
		try require(retainedBytes == bytes, "Ordinary removal changed source bytes")
		try require(!fm.fileExists(atPath: storage.appendingPathComponent("fixture.torrent").path), "Removal retained obsolete engine metadata")
		try await reject(restored, "run", ["id": "fixture", "running": true])
	}
}
