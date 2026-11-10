import Foundation
import Darwin
import ButterTorrentMetadata
import ButterTorrentNetworking

func runDHTComparisons(root: URL, binary: URL) async throws {
	let metadata = try TorrentMetadata(contentsOf: root.appendingPathComponent("single-16384.torrent"))
	for referenceClient in [false, true] {
		let label = referenceClient ? "libtorrent-to-Swift-DHT" : "Swift-to-libtorrent-DHT"
		let work = root.appendingPathComponent(label); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
		let routerSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), routerUDP = UDPDispatcher(transport: routerSocket)
		let router = try DHTNode(dispatcher: routerUDP, bootstrap: [])
		let sourceSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), sourceUDP = UDPDispatcher(transport: sourceSocket)
		let observerSocket = try DatagramSocket(bind: NetworkEndpoint("127.0.0.1", port: 0)), observerUDP = UDPDispatcher(transport: observerSocket)
		let statusURL = work.appendingPathComponent("status.json"), jobURL = work.appendingPathComponent("job.json")
		let job: [String: Any] = ["status": statusURL.path, "hash": metadata.hashes.v1!.base64EncodedString(), "remotePort": referenceClient ? Int(routerSocket.localEndpoint.port) : 0, "announcePort": 6999]
		try JSONSerialization.data(withJSONObject: job).write(to: jobURL)
		let process = Process(); process.executableURL = binary; process.arguments = ["--dht", jobURL.path]
		var nodes = [router]
		func record() throws -> [String: Any] {
			guard process.isRunning else { throw NetworkFailure.invalid("DHT reference process exited") }
			guard let data = try? Data(contentsOf: statusURL) else { return [:] }
			return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
		}
		do {
			try await router.setTorrents([metadata])
			if referenceClient {
				let source = try DHTNode(dispatcher: sourceUDP, bootstrap: [routerSocket.localEndpoint]); nodes.append(source)
				try await source.setTorrents([metadata]); _ = try await source.getPeers(for: metadata, announcePort: 6881)
			}
			try process.run()
			try await TCPTransferComparisonTests.wait { let state = try record(); return state["ready"] as? Bool == true && (state["port"] as? Int ?? 0) > 0 }
			let port = UInt16(try record()["port"] as! Int)
			let target = referenceClient ? routerSocket.localEndpoint : try NetworkEndpoint("127.0.0.1", port: port)
			if !referenceClient {
				let source = try DHTNode(dispatcher: sourceUDP, bootstrap: [target]); nodes.append(source)
				try await source.setTorrents([metadata]); _ = try await source.getPeers(for: metadata, announcePort: 6881)
				try await TCPTransferComparisonTests.wait { (try record()["announces"] as? Int ?? 0) > 0 }
			} else {
				try await TCPTransferComparisonTests.wait { (try record()["peers"] as? [Int] ?? []).contains(6881) }
				try await TCPTransferComparisonTests.wait { await router.contactCount >= 2 }
			}
			let observer = try DHTNode(dispatcher: observerUDP, bootstrap: [target]); nodes.append(observer)
			let magnet = Magnet(hashes: metadata.hashes)
			try await observer.setTorrents([], unresolved: [magnet.hashes]); let found = try await observer.getPeers(for: magnet)
			guard found.contains(where: { $0.port == (referenceClient ? 6999 : 6881) }) else { throw NetworkFailure.invalid("cross-engine DHT peer was not returned") }
			try await TCPTransferComparisonTests.stop(process)
			print("PASS: \(label), independent token, announce and unresolved-magnet lookup")
		} catch {
			if let data = try? Data(contentsOf: statusURL) { try? FileHandle.standardError.write(contentsOf: data) }
			if process.isRunning { process.terminate(); try? await TCPTransferComparisonTests.stop(process) }
			for node in nodes { await node.shutdown() }; for udp in [routerUDP, sourceUDP, observerUDP] { try? await udp.shutdown() }; throw error
		}
		for node in nodes { await node.shutdown() }; for udp in [routerUDP, sourceUDP, observerUDP] { try await udp.shutdown() }
	}
}
