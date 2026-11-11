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
	struct Job: Codable { let role: String; let items: [Item] }
	struct Command: Decodable { let command: String; let ports: [UInt16]? }
	static func emit(_ phase: String, ports: [UInt16] = []) throws {
		var usage = rusage(); guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw CocoaError(.fileReadUnknown) }
		let record: [String: Any] = ["phase": phase, "pid": getpid(), "time": ProcessInfo.processInfo.systemUptime,
			"user": Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6,
			"system": Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6,
			"peak_rss": usage.ru_maxrss, "ports": ports, "request_window": TCPTransferConfiguration().pipeline]
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
			try fixture(URL(fileURLWithPath: args[2]), small: args.count == 4 && args[3] == "--small"); return
		}
		guard args.count == 3, ["--benchmark", "--verify"].contains(args[1]) else { throw PeerFailure.invalid("expected fixture ROOT [--small] or --benchmark/--verify JOB") }
		let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
		guard ["seed", "download"].contains(job.role), (1...4).contains(job.items.count) else { throw PeerFailure.invalid("benchmark job") }
		if args[1] == "--verify" {
			for item in job.items {
				let metadata = try TorrentMetadata(contentsOf: URL(fileURLWithPath: item.torrent))
				let storage = try await TorrentStorage.open(metadata: metadata, destination: URL(fileURLWithPath: item.destination), stateDirectory: URL(fileURLWithPath: item.state))
				let snapshot = try await storage.snapshot()
				guard snapshot.verifiedPieces.count == storage.layout.pieceCount else { try await storage.shutdown(); throw PeerFailure.invalid("incomplete restored checkpoint") }
				try await storage.shutdown()
			}
			return
		}
		try emit("prepare")
		var stores: [TorrentStorage] = [], engines: [TCPTransfer] = [], listeners: [TCPListener] = [], accepts: [Task<Void, Error>] = []
		do {
			for item in job.items {
				let metadata = try TorrentMetadata(contentsOf: URL(fileURLWithPath: item.torrent))
				let storage = try await TorrentStorage.open(metadata: metadata, destination: URL(fileURLWithPath: item.destination), stateDirectory: URL(fileURLWithPath: item.state)); stores.append(storage)
				if job.role == "seed" { for piece in 0..<storage.layout.pieceCount { guard try await storage.verify(piece: piece) else { throw PeerFailure.corruptPiece(piece) } } }
				var configuration = TCPTransferConfiguration(); configuration.encryption = .disabled; configuration.enablePEX = false
				let engine = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: configuration); engines.append(engine)
				if job.role == "seed" { listeners.append(try await TCPListener.listen(address: IPAddress("127.0.0.1"))) }
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
			try emit("ready", ports: listeners.map(\.port))
			let start = try await command("start"); try emit("start")
			if job.role == "seed" {
				for (engine, listener) in zip(engines, listeners) {
					accepts.append(Task { while !Task.isCancelled { _ = try await engine.attach(listener.accept(timeout: 600)) } })
				}
				_ = try await command("verified") // The receiving engine, never upload byte counters, decides completion.
			} else {
				guard let ports = start.ports, ports.count == engines.count else { throw PeerFailure.invalid("benchmark ports") }
				try await withThrowingTaskGroup(of: Void.self) { group in
					for (engine, port) in zip(engines, ports) { group.addTask { _ = try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: port)); try await engine.waitUntilComplete() } }
					try await group.waitForAll()
				}
			}
			try emit("verified")
			_ = try await command("persist")
			try emit("persistence")
			for (engine, storage) in zip(engines, stores) {
				let counters = await engine.snapshot()
				if let error = counters.storageError { throw PeerFailure.invalid(error) }
				try await storage.checkpoint(downloaded: counters.downloaded, uploaded: counters.uploaded, corruptBytes: counters.corruptBytes, redundantBytes: counters.redundantBytes)
			}
			try emit("durable")
			_ = try await command("stop"); try emit("shutdown")
			for listener in listeners { try await listener.shutdown() }
			for task in accepts { task.cancel(); _ = try? await task.value }
			for engine in engines { try await engine.shutdown() }
			for storage in stores { try await storage.shutdown() }
			try emit("stopped")
		} catch {
			for listener in listeners { try? await listener.shutdown() }
			for task in accepts { task.cancel(); _ = try? await task.value }
			for engine in engines { try? await engine.shutdown() }
			for storage in stores { try? await storage.shutdown() }; throw error
		}
	}

	static func fixture(_ root: URL, small: Bool) throws {
		let fm = FileManager.default
		var manifest: [[String: Any]] = []
		for name in ["single", "many", "concurrent"] {
			let folder = root.appendingPathComponent(name), seed = folder.appendingPathComponent("seed")
			try fm.createDirectory(at: seed, withIntermediateDirectories: true)
			let count = name == "many" ? 128 : name == "concurrent" ? 4 : 1
			let total = small ? 32 * 1_048_576 : 1_073_741_824
			var files: [[String: Any]] = []
			for index in 0..<count {
				let path = name == "many" ? String(format: "bundle/file-%03d.bin", index) : "payload-\(index).bin"
				let url = seed.appendingPathComponent(path)
				try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
				guard fm.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
				let file = try FileHandle(forWritingTo: url); var hash = SHA256()
				var block = Data((0..<262144).map { UInt8(($0 * 17 + $0 / 97 + index) % 251) })
				for part in 0..<(total / count / block.count) {
					block[0] = UInt8(truncatingIfNeeded: part); block[1] = UInt8(truncatingIfNeeded: part >> 8)
					try file.write(contentsOf: block); hash.update(data: block)
				}
				try file.synchronize(); try file.close()
				files.append(["path": path, "size": total / count, "sha256": hash.finalize().map { String(format: "%02x", $0) }.joined()])
			}
			var torrents: [String: [String]] = [:], torrentHashes: [String: String] = [:]
			for index in 0..<(name == "concurrent" ? 4 : 1) {
				let source = seed.appendingPathComponent(name == "many" ? "bundle" : "payload-\(index).bin")
				let hybrid = try TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 262144)
				let document = try BencodeDocument(hybrid)
				for format in ["v1", "v2", "hybrid"] {
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
			manifest.append(["case": name, "bytes": total, "files": files, "torrents": torrents, "torrent_sha256": torrentHashes])
		}
		try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted]).write(to: root.appendingPathComponent("manifest.json"))
	}
}
