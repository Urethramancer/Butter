import Foundation
import Darwin
import ButterTorrentMetadata
@testable import ButterTorrentNetworking
import ButterTorrentEngine

extension TCPTransferComparisonTests {
	static func runSessionDHTComparisons(root: URL, binary: URL) async throws {
		var cases = 0
		for version in [1, 2, 3] { for utp in [false, true] { for nativeSeed in [false, true] {
			let suffix = version == 1 ? "" : version == 2 ? "-v2" : "-hybrid"
			let label = "session-dht-v\(version)-\(utp ? "utp" : "tcp")-\(nativeSeed ? "up" : "down")", work = root.appendingPathComponent(label)
			try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
			let source = root.appendingPathComponent("single-16384\(suffix).torrent"), metadata = try TorrentMetadata(contentsOf: source)
			let hash = metadata.hashes.v1 ?? Data(metadata.hashes.v2!.prefix(20))
			let socket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), udp = UDPDispatcher(transport: socket), router = try DHTNode(dispatcher: udp, bootstrap: [])
			try await router.setTorrents([metadata])
			var configuration = TCPTransferConfiguration(); configuration.encryption = .disabled
			let session = TorrentSession(storage: work.appendingPathComponent("library"), configuration: configuration, loopbackOnly: true, dhtBootstrap: [socket.localEndpoint])
			let record = work.appendingPathComponent("status.json"), jobURL = work.appendingPathComponent("job.json")
			let process = Process(); process.executableURL = binary; process.arguments = ["--run", jobURL.path]
			do {
				var settings = SessionPeerSettings(); settings.dht = true; settings.pex = false; settings.utp = utp; settings.tcp = !utp
				let port = try await session.configurePeers(settings)
				_ = try await session.add(id: "transfer", source: source, destination: nativeSeed ? root.appendingPathComponent("reference-seed") : work.appendingPathComponent("native-download"))
				if nativeSeed {
					try await session.run(id: "transfer", running: true)
					try await wait { await router.peerCache[hash]?.keys.contains { $0.port == port } == true }
				}
				let job: [String: Any] = ["torrent": source.path, "destination": nativeSeed ? work.appendingPathComponent("reference-download").path : root.appendingPathComponent("reference-seed").path,
					"listen": "127.0.0.1:0", "status": record.path, "remotePort": 0, "dhtPort": Int(socket.localEndpoint.port), "transport": utp ? "utp" : "tcp", "encryption": "disabled"]
				try JSONSerialization.data(withJSONObject: job).write(to: jobURL); try process.run()
				if !nativeSeed {
					try await wait { try status(record, process: process)?.seeding == true }
					let referencePort = try status(record, process: process)!.port
					try await wait { await router.peerCache[hash]?.keys.contains { $0.port == referencePort } == true }
					try await session.run(id: "transfer", running: true)
				}
				try await wait { let native = try await session.snapshot().transfers[0]; let reference = try status(record, process: process); return nativeSeed ? reference?.complete == true : native.state.transfer?.complete == true }
				let reference = try status(record, process: process)!, native = try await session.snapshot()
				guard native.network.discovery.contacts > 0, nativeSeed ? reference.dhtPeers > 0 : (native.transfers[0].state.transfer?.downloaded ?? 0) > 0 else { throw PeerFailure.invalid("DHT discovery provenance or payload counters") }
				if utp { guard reference.utp > 0 && reference.tcp == 0 else { throw PeerFailure.invalid("DHT comparison used TCP with TCP disabled") } }
				try await session.close(); try await stop(process); await router.shutdown(); try await udp.shutdown()
				let destination = work.appendingPathComponent(nativeSeed ? "reference-download" : "native-download")
				for file in metadata.inspection.files where !file.pad {
					guard try Data(contentsOf: destination.appendingPathComponent(file.path)) == Data(contentsOf: root.appendingPathComponent("reference-seed/" + file.path)) else { throw PeerFailure.invalid("DHT-discovered payload differs") }
				}
				cases += 1; print("PASS: \(label), discovered and transferred without explicit peer connections")
			} catch {
				try? await session.close(); await router.shutdown(); try? await udp.shutdown()
				if let data = try? Data(contentsOf: record) { try? FileHandle.standardError.write(contentsOf: data) }
				if process.isRunning { process.terminate(); try? await stop(process); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
				try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(label): \(error)\n".utf8)); throw error
			}
		} } }
		print("PASS: \(cases) independent session DHT transfers in both directions")
	}
}
