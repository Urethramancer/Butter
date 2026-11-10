import Foundation
import Darwin
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage
import ButterTorrentEngine

extension TCPTransferComparisonTests {
	static func runIdentityComparisons(root: URL, binary: URL) async throws {
		var cases = 0
		for size in [16384, 65536] { for nativeSeed in [false, true] {
			let label = "legacy-hybrid-\(size)-\(nativeSeed ? "up" : "down")"
			let work = root.appendingPathComponent(label); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
			let source = root.appendingPathComponent("multi-\(size)-hybrid.torrent"), metadata = try TorrentMetadata(contentsOf: source)
			let destination = work.appendingPathComponent("native-data")
			let storage = try await TorrentStorage.open(metadata: metadata, destination: destination, stateDirectory: work.appendingPathComponent("state"))
			if nativeSeed {
				try await storage.importFiles(from: root.appendingPathComponent("reference-seed"))
				for piece in 0..<storage.layout.pieceCount {
					guard try await storage.verify(piece: piece) else { throw PeerFailure.invalid("legacy fixture source did not verify") }
				}
			}
			var configuration = TCPTransferConfiguration(); configuration.encryption = .disabled
			let engine = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: configuration)
			let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1"))
			let record = work.appendingPathComponent("status.json"), jobURL = work.appendingPathComponent("job.json")
			let process = Process(); process.executableURL = binary; process.arguments = ["--run", jobURL.path]
			var relay: TCPFragmentingRelay?, accepting: Task<UUID, Error>?
			do {
				if nativeSeed {
					relay = try await TCPFragmentingRelay.open(host: "127.0.0.1", target: NetworkEndpoint("127.0.0.1", port: listener.port), legacyHash: metadata.hashes.v1!)
					accepting = Task { try await engine.attach(listener.accept(timeout: 10)) }
				}
				let job: [String: Any] = ["torrent": source.path, "destination": nativeSeed ? work.appendingPathComponent("reference-data").path : root.appendingPathComponent("reference-seed").path,
					"listen": "127.0.0.1:0", "status": record.path, "remoteHost": "127.0.0.1", "remotePort": relay.map { Int($0.port) } ?? 0, "transport": "tcp", "encryption": "disabled", "pex": false]
				try JSONSerialization.data(withJSONObject: job).write(to: jobURL); try process.run()
				if !nativeSeed {
					try await wait { try status(record, process: process)?.seeding == true }
					let reference = try status(record, process: process)!
					relay = try await TCPFragmentingRelay.open(host: "127.0.0.1", target: NetworkEndpoint("127.0.0.1", port: reference.port), legacyHash: metadata.hashes.v1!, rejectHash: Data(metadata.hashes.v2!.prefix(20)))
					_ = try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: relay!.port))
				}
				_ = try await accepting?.value
				try await wait { nativeSeed ? try status(record, process: process)?.complete == true : await engine.snapshot().complete }
				let snapshot = await engine.snapshot(), rejected = await relay!.rejectedIdentity
				guard snapshot.peers.contains(where: { $0.peerID != nil && !$0.v2 }), nativeSeed || rejected else { throw PeerFailure.invalid("legacy wire identity or initial rejection missing") }
				try await engine.shutdown(); try await storage.shutdown(); try await stop(process)
				let output = nativeSeed ? work.appendingPathComponent("reference-data") : destination
				for file in metadata.inspection.files where !file.pad {
					guard try Data(contentsOf: output.appendingPathComponent(file.path)) == Data(contentsOf: root.appendingPathComponent("reference-seed/" + file.path)) else { throw PeerFailure.invalid("legacy hybrid payload differs") }
				}
				await relay?.close(); try await listener.shutdown(); cases += 1; print("PASS: \(label), v1 wire and exact files verified against libtorrent")
			} catch {
				accepting?.cancel(); try? await engine.shutdown(); try? await storage.shutdown(); await relay?.close(); try? await listener.shutdown()
				if process.isRunning { process.terminate(); try? await stop(process); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
				throw PeerFailure.invalid("\(label): \(error)")
			}
		} }
		print("PASS: \(cases) independent legacy hybrid comparisons")
	}
}
