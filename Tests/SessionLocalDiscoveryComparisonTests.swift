import Foundation
import Darwin
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentEngine

extension TCPTransferComparisonTests {
	static func runLocalDiscoveryComparisons(root: URL, binary: URL) async throws {
		var cases = 0
		for version in [1, 2, 3] { for utp in [false, true] { for nativeSeed in [false, true] {
			let label = "lsd-v\(version)-\(utp ? "utp" : "tcp")-\(nativeSeed ? "up" : "down")"
			if let filter = ProcessInfo.processInfo.environment["BUTTER_LSD_FILTER"], !label.contains(filter) { continue }
			let work = root.appendingPathComponent(label); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
			let suffix = version == 1 ? "" : version == 2 ? "-v2" : "-hybrid"
			let source = root.appendingPathComponent("single-16384\(suffix).torrent"), metadata = try TorrentMetadata(contentsOf: source)
			guard metadata.trackerTiers.isEmpty, !metadata.inspection.private else { throw PeerFailure.invalid("local discovery fixture has another peer source") }
			var configuration = TCPTransferConfiguration(); configuration.encryption = .disabled
			let session = TorrentSession(storage: work.appendingPathComponent("library"), configuration: configuration, loopbackOnly: true)
			let record = work.appendingPathComponent("status.json"), jobURL = work.appendingPathComponent("job.json")
			let process = Process(); process.executableURL = binary; process.arguments = ["--run", jobURL.path]
			do {
				var settings = SessionPeerSettings(); settings.lsd = true; settings.pex = false; settings.tcp = !utp; settings.utp = utp
				_ = try await session.configurePeers(settings)
				let destination = nativeSeed ? root.appendingPathComponent("reference-seed") : work.appendingPathComponent("native-data")
				_ = try await session.add(id: "transfer", source: source, destination: destination); try await session.run(id: "transfer", running: true)
				let job: [String: Any] = ["torrent": source.path, "destination": nativeSeed ? work.appendingPathComponent("reference-data").path : root.appendingPathComponent("reference-seed").path,
					"listen": "127.0.0.1:0", "status": record.path, "remotePort": 0, "transport": utp ? "utp" : "tcp", "encryption": "disabled", "pex": false, "lsd": true, "diagnostics": true]
				try JSONSerialization.data(withJSONObject: job).write(to: jobURL); try process.run()
				try await wait {
					guard let reference = try status(record, process: process), let wire = try await session.snapshot().transfers[0].state.transfer else { return false }
					return nativeSeed ? reference.complete && reference.downloaded > 0 && wire.uploaded > 0 : wire.complete && wire.downloaded > 0 && reference.uploaded > 0
				}
				let snapshot = try await session.snapshot(), reference = try status(record, process: process)!
				guard snapshot.network.localDiscovery, snapshot.network.error.isEmpty,
					snapshot.transfers[0].state.transfer?.peers.contains(where: { $0.transport == (utp ? .utp : .tcp) }) == true,
					utp ? reference.tcp == 0 && reference.utp > 0 : reference.tcp > 0 else { throw PeerFailure.invalid("local discovery transport or service differs") }
				try await session.shutdown(); try await session.close(); try await stop(process)
				let output = nativeSeed ? work.appendingPathComponent("reference-data") : destination
				for file in metadata.inspection.files where !file.pad {
					guard try Data(contentsOf: output.appendingPathComponent(file.path)) == Data(contentsOf: root.appendingPathComponent("reference-seed/" + file.path)) else { throw PeerFailure.invalid("local discovery payload differs") }
				}
				cases += 1; print("PASS: \(label), real loopback multicast was the only peer source; flushed bytes verified")
			} catch {
				let snapshot = try? await session.snapshot()
				try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(label): \(error); network=\(snapshot?.network.error ?? "")\n".utf8))
				if let bytes = try? Data(contentsOf: record) { try? FileHandle.standardError.write(contentsOf: bytes) }
				try? await session.close()
				if process.isRunning { process.terminate(); try? await stop(process); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
				throw error
			}
		} } }
		guard cases > 0 else { throw PeerFailure.invalid("no local discovery comparison matched") }
		print("PASS: \(cases) independent local discovery comparisons")
	}
}
