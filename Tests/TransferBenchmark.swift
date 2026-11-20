import Foundation
import Darwin
import CryptoKit
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage
import ButterTorrentEngine

// Line-delimited JSON over bounded OS pipes. Only phase boundaries are emitted.
@main struct TransferBenchmark {
	struct Item: Codable { let torrent: String; let destination: String; let state: String }
	struct Job: Codable { let role: String; let items: [Item]; let partial: Bool?; let profileHoldAfterStop: Bool?; let applicationInspector: Bool?; let peerCount: Int? }
	struct Command: Decodable { let command: String; let ports: [UInt16]? }
	static func emit(_ phase: String, ports: [UInt16] = [], bytes: Int64 = 0, errors: [String] = [], received: Int64 = 0, pieces: [Int]? = nil) throws {
		var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
		var record: [String: Any] = ["phase": phase, "pid": getpid(), "time": ProcessInfo.processInfo.systemUptime,
			"user": Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
			"system": Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6,
			"peak_rss": usage.ru_maxrss, "ports": ports, "payload_bytes": bytes, "request_window": TCPTransferConfiguration().pipeline,
			"upload_admission": ["advertised_reqq": TCPTransferConfiguration.advertisedUploadRequestLimit, "requests_per_peer": 32, "jobs_per_transfer": 64, "output_bytes": 524288, "output_messages": 128], "peer_errors": errors]
		record["received_payload_bytes"] = received
		#if BUTTER_VERIFICATION_POLICY_AVAILABLE
		record["storage_policy"] = ["uploads": "trustedVerified", "restore": "strict eager", "independent_validation": "strict"]
		#else
		record["storage_policy"] = ["uploads": "strict (older-parent adapter)", "restore": "strict eager", "independent_validation": "strict"]
		#endif
		if let pieces { record["verified_pieces"] = pieces }
		#if BUTTER_STORAGE_DIAGNOSTICS_AVAILABLE
		if StorageDiagnostics.enabled { record["storage_diagnostics"] = StorageDiagnostics.snapshot() }
		#endif
		#if BUTTER_RECEIVE_PIPELINE_DIAGNOSTICS_AVAILABLE
		if ReceivePipelineDiagnostics.enabled { record["receive_pipeline_diagnostics"] = ReceivePipelineDiagnostics.snapshot() }
		#endif
		var bytes = try JSONSerialization.data(withJSONObject: record); bytes.append(10)
		try FileHandle.standardOutput.write(contentsOf: bytes)
	}
	static func command(_ expected: String) async throws -> Command {
		let bytes = try await Task.detached {
			var data = Data()
			while data.count < 4096 {
				let byte = try FileHandle.standardInput.read(upToCount: 1)
				guard let byte, !byte.isEmpty else { throw PeerFailure.closed }
				if byte[0] == 10 { return data }; data.append(byte)
			}
			throw PeerFailure.limit("benchmark command")
		}.value
		let value = try JSONDecoder().decode(Command.self, from: bytes)
		guard value.command == expected else { throw PeerFailure.invalid("expected benchmark \(expected)") }; return value
	}
	static func main() async throws {
		let args = CommandLine.arguments
		if args.count >= 3, args[1] == "fixture" {
			try fixture(URL(fileURLWithPath: args[2]), small: args.count == 4 && args[3] == "--small", sweep: args.count == 4 && args[3] == "--rate-sweep", split: args.count == 4 && args[3] == "--split-v1"); return
		}
		guard args.count == 3, ["--benchmark", "--verify"].contains(args[1]) else { throw PeerFailure.invalid("expected fixture ROOT [--small] or --benchmark/--verify JOB") }
		let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
		guard ["seed", "download"].contains(job.role), (1...4).contains(job.items.count) else { throw PeerFailure.invalid("benchmark job") }
		#if BUTTER_APPLICATION_BENCHMARK
		if job.applicationInspector != nil { try await application(job, verify: args[1] == "--verify"); return }
		#endif
		if args[1] == "--verify" {
			for item in job.items {
				let metadata = try TorrentMetadata(contentsOf: URL(fileURLWithPath: item.torrent))
				let storage = try await TorrentStorage.open(metadata: metadata, destination: URL(fileURLWithPath: item.destination), stateDirectory: URL(fileURLWithPath: item.state))
				let snapshot = try await storage.snapshot()
				if job.partial == true { try emit("reopened", pieces: snapshot.verifiedPieces.sorted()) }
				guard job.partial == true || snapshot.verifiedPieces.count == storage.layout.pieceCount else { try await storage.shutdown(); throw PeerFailure.invalid("incomplete restored checkpoint") }
				try await storage.shutdown()
			}
			return
		}
		try emit("prepare")
		var stores: [TorrentStorage] = [], engines: [TCPTransfer] = [], listeners: [TCPListener] = [], accepts: [Task<Void, Error>] = []
		do {
			for item in job.items {
				let metadata = try TorrentMetadata(contentsOf: URL(fileURLWithPath: item.torrent))
				#if BUTTER_VERIFICATION_POLICY_AVAILABLE
				let storage = try await TorrentStorage.open(metadata: metadata, destination: URL(fileURLWithPath: item.destination), stateDirectory: URL(fileURLWithPath: item.state), checkpointPolicy: .managed, readPolicy: .trustedVerified)
				#else
				let storage = try await TorrentStorage.open(metadata: metadata, destination: URL(fileURLWithPath: item.destination), stateDirectory: URL(fileURLWithPath: item.state), checkpointPolicy: .managed)
				#endif
				stores.append(storage)
				if job.role == "seed" { for piece in 0..<storage.layout.pieceCount { guard try await storage.verify(piece: piece) else { throw PeerFailure.corruptPiece(piece) } } }
				var configuration = TCPTransferConfiguration(); configuration.encryption = .disabled; configuration.enablePEX = false
				let engine = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: configuration); engines.append(engine)
				if job.role == "seed" { listeners.append(try await TCPListener.listen(address: ButterTorrentNetworking.IPAddress("127.0.0.1"))) }
			}
			// The controller requests diagnostics only after rejecting a failed trial.
			signal(SIGUSR1, SIG_IGN)
			let diagnosticSignal = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .global())
			let diagnosticEngines = engines
			diagnosticSignal.setEventHandler {
				Task {
					for engine in diagnosticEngines {
						let status = await engine.snapshot()
						let text = "Rejected trial: complete=\(status.complete), peers=\(status.peers.count), downloaded=\(status.downloaded), uploaded=\(status.uploaded), peerError=\(status.lastPeerError ?? "none"), storageError=\(status.storageError ?? "none")\n"
						try? FileHandle.standardError.write(contentsOf: Data(text.utf8))
					}
				}
			}
			diagnosticSignal.resume(); defer { diagnosticSignal.cancel() }
			let payloadBytes = stores.reduce(Int64(0)) { total, store in total + store.layout.files.filter { !$0.pad }.reduce(Int64(0)) { $0 + $1.size } }
			try emit("ready", ports: listeners.map(\.port), bytes: payloadBytes)
			let start = try await command("start"); try emit("start")
			if job.role == "seed" {
				for (engine, listener) in zip(engines, listeners) {
					accepts.append(Task { while !Task.isCancelled { _ = try await engine.attach(listener.accept(timeout: 600)) } })
				}
				_ = try await command("verified") // The receiving engine, never upload byte counters, decides completion.
			} else {
				guard let ports = start.ports else { throw PeerFailure.invalid("benchmark ports") }
				if let count = job.peerCount {
					guard engines.count == 1, job.partial != true, (2...4).contains(count), ports.count == count, Set(ports).count == count else { throw PeerFailure.invalid("benchmark peer count") }
					let engine = engines[0]
					try await withThrowingTaskGroup(of: Void.self) { group in
						for port in ports { group.addTask { _ = try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: port)) } }
						try await group.waitForAll()
					}
					try await engine.waitUntilComplete()
				} else if ports.count != engines.count { throw PeerFailure.invalid("benchmark ports") }
				else if job.partial == true {
					for (engine, port) in zip(engines, ports) { _ = try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: port)) }
					for phase in ["measurement-start", "measurement-end"] {
						_ = try await command(phase)
						let status = await engines[0].snapshot()
						guard !status.complete, status.storageError == nil else { throw PeerFailure.invalid("sweep completed or storage failed") }
						try emit(phase, received: status.downloaded)
					}
					_ = try await command("quiesce")
					for engine in engines { try await engine.shutdown() }
				} else {
					try await withThrowingTaskGroup(of: Void.self) { group in
						for (engine, port) in zip(engines, ports) { group.addTask { _ = try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: port)); try await engine.waitUntilComplete() } }
						try await group.waitForAll()
					}
				}
			}
			// Read only bounded failure diagnostics; never allocate progress/peer snapshots.
			var failures: [String] = []
			for engine in engines { if let error = await engine.lastPeerError { failures.append(error) } }
			try emit("verified", errors: failures)
			_ = try await command("persist")
			try emit("persistence")
			for engine in engines { try await engine.checkpoint() }
			#if BUTTER_STORAGE_REPLAY_CAPTURE
			if job.role == "download" {
				for (item, store) in zip(job.items, stores) {
					let jobs = try await store.capturedWriteJobs()
					try JSONEncoder().encode(jobs).write(to: URL(fileURLWithPath: item.torrent + ".jobs"))
				}
			}
			#endif
			try emit("durable", pieces: job.partial == true ? try await stores[0].snapshot().verifiedPieces.sorted() : nil)
			_ = try await command("stop"); try emit("shutdown")
			for listener in listeners { try await listener.shutdown() }
			for task in accepts { task.cancel(); _ = try? await task.value }
			for engine in engines { try await engine.shutdown() }
			for storage in stores { try await storage.shutdown() }
			try emit("stopped", errors: failures)
			if job.profileHoldAfterStop == true { _ = try await command("release") }
		} catch {
			for listener in listeners { try? await listener.shutdown() }
			for task in accepts { task.cancel(); _ = try? await task.value }
			for engine in engines { try? await engine.shutdown() }
			for storage in stores { try? await storage.shutdown() }; throw error
		}
	}

	static func fixture(_ root: URL, small: Bool, sweep: Bool = false, split: Bool = false) throws {
		let fm = FileManager.default
		let requestedPieceLength = ProcessInfo.processInfo.environment["BUTTER_BENCHMARK_PIECE_LENGTH"]
		guard let pieceLength = Int(requestedPieceLength ?? "262144"), (16384...16777216).contains(pieceLength), pieceLength.nonzeroBitCount == 1 else {
			throw PeerFailure.invalid("benchmark piece length must be a power of two from 16 KiB to 16 MiB")
		}
		var manifest: [[String: Any]] = []
		var cases = sweep ? ["many"] : ["single", "many", "concurrent"]
		if split { cases = ["split-1", "split-2", "split-4"] }
		if let selected = ProcessInfo.processInfo.environment["BUTTER_BENCHMARK_FIXTURE_CASE"] {
			guard cases.contains(selected) else { throw PeerFailure.invalid("unknown benchmark fixture case") }; cases = [selected]
		}
		let total = sweep ? 4 * 1_073_741_824 : small ? 32 * 1_048_576 : 1_073_741_824
		var volume = root
		while !fm.fileExists(atPath: volume.path) { volume.deleteLastPathComponent() }
		let free = try fm.attributesOfFileSystem(forPath: volume.path)[.systemFreeSize] as? NSNumber
		// Reserve source fixtures, one full destination, and 1 GiB of working headroom.
		let required = Int64(total) * Int64(cases.count + 1) + 1_073_741_824
		guard let free, free.int64Value >= required else { throw PeerFailure.limit("benchmark needs \(required / 1_048_576) MiB of free temporary disk space") }
		for name in cases {
			let folder = root.appendingPathComponent(name), seed = folder.appendingPathComponent("seed")
			try fm.createDirectory(at: seed, withIntermediateDirectories: true)
			let torrentCount = split ? Int(name.dropFirst(6))! : name == "concurrent" ? 4 : 1
			let count = name == "many" ? 128 : torrentCount
			var files: [[String: Any]] = []
			for index in 0..<count {
				let path = name == "many" ? String(format: "bundle/file-%03d.bin", index) : "payload-\(index).bin"
				let url = seed.appendingPathComponent(path)
				try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
				let file = try FileHandle(forWritingTo: url); var hash = SHA256()
				let pattern = split ? 0 : index
				var block = Data((0..<262144).map { UInt8(($0 * 17 + $0 / 97 + pattern) % 251) })
				for part in 0..<(total / count / block.count) {
					let sequence = part + (split ? index * (total / count / block.count) : 0)
					block[0] = UInt8(truncatingIfNeeded: sequence); block[1] = UInt8(truncatingIfNeeded: sequence >> 8)
					try file.write(contentsOf: block); hash.update(data: block)
				}
				try file.synchronize(); try file.close()
				files.append(["path": path, "size": total / count, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()])
				if split { files[index]["torrent_index"] = index }
			}
			var torrents: [String: [String]] = [:], torrentHashes: [String: String] = [:]
			for index in 0..<torrentCount {
				let source = seed.appendingPathComponent(name == "many" ? "bundle" : "payload-\(index).bin")
				let hybrid = try TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: pieceLength)
				let document = try BencodeDocument(hybrid)
				for format in (split ? ["v1"] : sweep ? ["hybrid", "v2"] : ["v1", "v2", "hybrid"]) {
					var info = document.root["info"]!.dictionary!, root = document.root.dictionary!
					for key in format == "v1" ? ["meta version", "file tree"] : format == "v2" ? ["pieces", "files", "length"] : [] { info[Data(key.utf8)] = nil }
					root[Data("info".utf8)] = .dictionary(info)
					if format == "v1" { root[Data("piece layers".utf8)] = nil }
					let path = "\(format)-\(index).torrent"
					let bytes = try BencodeValue.dictionary(root).encoded()
					try bytes.write(to: folder.appendingPathComponent(path))
					torrentHashes[path] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
					torrents[format, default: []].append(path)
				}
			}
			var fixture: [String: Any] = ["case": name, "bytes": total, "files": files, "torrents": torrents, "torrent_sha256": torrentHashes]
			if requestedPieceLength != nil { fixture["piece_length"] = pieceLength }
			manifest.append(fixture)
		}
		try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("manifest.json"))
	}
}
