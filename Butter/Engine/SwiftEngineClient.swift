#if canImport(ButterTorrentEngine)
import Foundation
import ButterTorrentEngine
import ButterTorrentNetworking
import ButterTorrentStorage

// Compiled by the headless comparison harness until the production cut-over.
final class SwiftEngineClient: EngineOperations, @unchecked Sendable {
	private let session: TorrentSession
	private let metadata = MetadataInspectionWorker()
	private let creation: TorrentCreationWorker
	private let snapshots = NativeSnapshotMapper()
	init(storage: URL) {
		var configuration = TCPTransferConfiguration(); configuration.allowSameIP = false
		session = TorrentSession(storage: storage, configuration: configuration)
		creation = TorrentCreationWorker(storage: storage) { try TransferRepository.publishCreatedTorrent($0, id: $1, root: storage) }
	}
	var creationProgress: Double { creation.progress }
	func cancelCreation() { creation.cancel() }
	func perform(_ command: String, _ payload: [String: Any]) async throws -> Data {
		do {
			let input = NativeCommandPayload(fields: payload)
			if command == "create" { return try await creation.create(payload) }
			if command == "inspect" { return try await metadata.inspect(URL(fileURLWithPath: input.text("source"))) }
			if command == "shutdown" { await creation.waitForCompletion(); try await session.shutdown(); return Data("{}".utf8) }
			if command == "settings" {
				// These services are added to the session separately; never silently enable them.
				let dht = try input.flag("dht"), lsd = try input.flag("lsd"), mapping = try input.optionalInteger("mapping") ?? 1
				guard !dht && !lsd && mapping == 0 else { throw NetworkFailure.invalid("discovery or router mapping is unavailable") }
				let port = try input.integer("port"); guard (0...65535).contains(port) else { throw NetworkFailure.invalid("listening port") }
				var settings = await session.currentPeerSettings; settings.port = UInt16(port)
				settings.maximumPeers = min(5000, max(1, try input.optionalInteger("peers") ?? 0))
				settings.torrentPeers = min(1000, min(settings.maximumPeers, max(1, try input.optionalInteger("torrentPeers") ?? 0)))
				settings.tcp = try input.optionalInteger("tcp").map { $0 != 0 } ?? settings.tcp
				settings.utp = try input.flag("utp"); settings.pex = try input.flag("pex")
				settings.allowSameIP = try input.optionalInteger("allowSameIP").map { $0 != 0 } ?? settings.allowSameIP
				return try JSONEncoder().encode(["port": await session.configurePeers(settings)])
			}
			if command == "blocklist" { try await session.setBlocklist(input.addressRanges()); return Data("{}".utf8) }
			let id = try input.text("id")
			switch command {
			case "add":
				let destination = try input.absolutePath("destination"), source = try input.text("source")
				let result = try await session.add(id: id, source: URL(fileURLWithPath: source), destination: destination,
					restore: input.flag("restore"), selected: input.selection(required: false), tracker: input.optionalText("tracker"))
				var response: [String: Any] = ["id": result.id, "duplicate": result.duplicate]
				if !result.duplicate { response["hashes"] = result.hashes }; return try JSONSerialization.data(withJSONObject: response)
			case "run": try await session.run(id: id, running: input.flag("running"), downloadLimit: input.optionalInteger("downloadLimit"), uploadLimit: input.optionalInteger("uploadLimit"))
			case "pause": try await session.pause(id: id)
			case "save": try await session.save(id: id)
			case "retry": try await session.retry(id: id)
			case "recheck": try await session.recheck(id: id)
			case "select": try await session.changeStorage(id: id, change: .select(input.selection(required: true)!))
			case "rename": try await session.changeStorage(id: id, change: .rename(input.renames()))
			case "move": try await session.changeStorage(id: id, change: .move(input.absolutePath("destination")))
			case "tracker": try await session.appendTracker(id: id, tracker: input.text("tracker"))
			case "magnet": return try JSONEncoder().encode(["magnet": await session.magnet(id: id)])
			case "export": return try await session.export(id: id)
			case "forget": try await session.forget(id: id)
			case "remove":
				let receipts = try await session.remove(id: id, trash: input.flag("trash"), retainState: input.flag("retainState"))
				return try JSONEncoder().encode(["trashed": receipts.map(\.path)])
			case "connect":
				let port = try input.integer("port"); guard (1...65535).contains(port) else { throw MetadataError.invalid("peer port") }
				_ = try await session.connect(id: id, to: NetworkEndpoint(input.text("address"), port: UInt16(port)))
			default: throw MetadataError.invalid("unknown engine command")
			}
			return Data("{}".utf8)
		} catch {
			let message = error is CancellationError ? (command == "create" ? "Creation cancelled." : "Operation cancelled.") : error.localizedDescription
			throw NSError(domain: "Butter.Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
		}
	}
	func snapshot() async throws -> EngineSnapshot {
		do { return try await snapshots.map(session.snapshot(), progress: creation.progress, now: ProcessInfo.processInfo.systemUptime) }
		catch { throw NSError(domain: "Butter.Engine", code: 1, userInfo: [NSLocalizedDescriptionKey: error.localizedDescription]) }
	}
	deinit { let session = session; Task { try? await session.close() } }
}

private struct NativeCommandPayload {
	let fields: [String: Any]
	func text(_ key: String) throws -> String {
		guard let value = fields[key] as? String, !value.isEmpty, !value.utf8.contains(0) else { throw MetadataError.invalid("a valid \(key) is required") }; return value
	}
	func optionalText(_ key: String) throws -> String? {
		guard let value = fields[key] else { return nil }
		guard let value = value as? String, !value.utf8.contains(0) else { throw MetadataError.invalid("invalid \(key)") }; return value.isEmpty ? nil : value
	}
	func integer(_ key: String) throws -> Int {
		guard let number = fields[key] as? NSNumber, number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
			number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) else { throw MetadataError.invalid("invalid \(key)") }; return number.intValue
	}
	func optionalInteger(_ key: String) throws -> Int? { fields[key] == nil ? nil : try integer(key) }
	func flag(_ key: String) throws -> Bool { fields[key] == nil ? false : try integer(key) != 0 }
	func absolutePath(_ key: String) throws -> URL {
		let value = try text(key); guard value.hasPrefix("/") else { throw MetadataError.invalid("absolute \(key) required") }; return URL(fileURLWithPath: value)
	}
	func selection(required: Bool) throws -> [Bool]? {
		guard let value = fields["selected"] else { if required { throw MetadataError.invalid("selection required") }; return nil }
		guard let list = value as? [NSNumber], list.allSatisfy({ $0.doubleValue == 0 || $0.doubleValue == 1 }) else { throw MetadataError.invalid("selection") }; return list.map(\.boolValue)
	}
	func renames() throws -> [Int: String] {
		guard let list = fields["changes"] as? [[String: Any]], list.count <= 50_000 else { throw MetadataError.invalid("rename changes") }
		var changes: [Int: String] = [:]
		for row in list {
			let row = NativeCommandPayload(fields: row), index = try row.integer("index")
			guard changes[index] == nil else { throw MetadataError.invalid("duplicate rename index") }; changes[index] = try row.text("path")
		}; return changes
	}
	func addressRanges() throws -> [PeerAddressRange] {
		guard let list = fields["ranges"] as? [[String: Any]], list.count <= 1_000_000 else { throw MetadataError.invalid("blocklist ranges") }
		return try list.map { row in
			let row = NativeCommandPayload(fields: row)
			return try PeerAddressRange(first: ButterTorrentNetworking.IPAddress(row.text("first")), last: ButterTorrentNetworking.IPAddress(row.text("last")))
		}
	}
}

actor NativeSnapshotMapper {
	private struct Sample { let time: TimeInterval; let down: Int64; let up: Int64 }
	private var transfers: [String: Sample] = [:]
	private var peers: [UUID: Sample] = [:]
	func map(_ snapshot: TorrentSessionSnapshot, progress: Double, now: TimeInterval) -> EngineSnapshot {
		var rows: [TransferSnapshot] = [], nextTransfers: [String: Sample] = [:], nextPeers: [UUID: Sample] = [:]
		for row in snapshot.transfers {
			let disk = row.state.storage, wire = row.state.transfer, metadata = row.metadata
			let files = metadata.inspection.files, length = metadata.pieceLength, total = files.reduce(Int64(0)) { $0 + $1.size }
			let count = Int(total / length + (total % length == 0 ? 0 : 1)), verified = disk.verifiedPieces
			var prefix = [Int64](repeating: 0, count: count + 1)
			for piece in 0..<count { prefix[piece + 1] = prefix[piece] + (verified.contains(piece) ? min(length, total - Int64(piece) * length) : 0) }
			func completeBytes(_ offset: Int64) -> Int64 {
				let piece = Int(offset / length), tail = offset % length
				return prefix[min(piece, count)] + (piece < count && verified.contains(piece) ? tail : 0)
			}
			var offset: Int64 = 0, mappedFiles: [TransferFile] = [], wanted: Int64 = 0, done: Int64 = 0
			for file in files {
				let completed = completeBytes(offset + file.size) - completeBytes(offset), selected = disk.selected[file.index] && !file.pad
				mappedFiles.append(TransferFile(index: file.index, path: disk.paths[file.index], original: file.path, size: file.size, done: completed, selected: selected, pad: file.pad))
				if selected { wanted += file.size; done += completed }; offset += file.size
			}
			let sample = Sample(time: now, down: wire?.downloaded ?? disk.downloaded, up: wire?.uploaded ?? disk.uploaded)
			let rates = speed(sample, after: transfers[row.id]); nextTransfers[row.id] = sample
			let mappedPeers = (wire?.peers ?? []).map { peer in
				let sample = Sample(time: now, down: peer.downloaded, up: peer.uploaded), rates = speed(sample, after: peers[peer.id]); nextPeers[peer.id] = sample
				return PeerSnapshot(address: peer.endpoint?.address.description ?? "", client: peer.client, down: rates.0, up: rates.1, utp: peer.transport == .utp)
			}
			let complete = done == wanted
			rows.append(TransferSnapshot(id: row.id, name: metadata.inspection.name, path: disk.destination.path,
				state: row.state.running ? (complete ? "Seeding" : "Downloading") : "Paused", error: wire?.storageError ?? row.error, metadata: true,
				private: metadata.inspection.private, complete: complete, progress: wanted == 0 ? 1 : Double(done) / Double(wanted), wanted: wanted, done: done, total: total,
				down: row.state.running ? rates.0 : 0, up: row.state.running ? rates.1 : 0, downloaded: sample.down, uploaded: sample.up,
				demand: wire?.peers.contains(where: \.remoteInterested) ?? false, hashes: metadata.hashes.hex,
				pieces: (0..<count).map { verified.contains($0) ? 1 : wire?.pieceStates[$0] == 1 ? 0 : wire?.pieceStates[$0] ?? 0 }, files: mappedFiles,
				trackers: metadata.trackerTiers.flatMap({ $0 }).map { TrackerSnapshot(url: $0, message: "") }, peers: mappedPeers))
		}
		transfers = nextTransfers; peers = nextPeers
		return EngineSnapshot(transfers: rows, events: snapshot.events.map { EngineEvent(kind: $0.kind, id: $0.id, path: $0.path) }, port: Int(snapshot.network.port), udp: snapshot.network.udp, networkError: snapshot.network.error, creationProgress: progress)
	}
	private func speed(_ sample: Sample, after previous: Sample?) -> (Int, Int) {
		guard let previous, sample.time > previous.time else { return (0, 0) }
		let elapsed = sample.time - previous.time
		func rate(_ bytes: Int64) -> Int { Int(min(Double(Int32.max), max(0, Double(bytes) / elapsed))) }
		return (rate(sample.down - previous.down), rate(sample.up - previous.up))
	}
}
#endif
