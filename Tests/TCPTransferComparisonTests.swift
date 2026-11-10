import Foundation
import Darwin
import ButterTorrentMetadata
@testable import ButterTorrentNetworking
import ButterTorrentStorage
import ButterTorrentEngine

private func require(_ value: Bool, _ message: String) throws {
	if !value { throw NSError(domain: "Butter.TCPComparison", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
extension UTPTransport {
	func comparisonDiagnostics() -> String {
		records.values.map { record in
			let state = record.state
			let flights = state.flights.map { "\($0.sequence)/\($0.payload.count)/\($0.transmissions)/\(clock.now() - $0.sent)" }.joined(separator: ",")
			return "µTP \(record.endpoint) id=\(state.receiveID)/\(state.sendID) phase=\(state.phase) send=\(state.next) ack=\(state.acknowledged) receive=\(state.received) peerWindow=\(state.remoteWindow) cwnd=\(state.congestion.window) RTO=\(state.congestion.retransmitAfter) ready=\(state.ready.count) reordered=\(state.reordered.keys.sorted()) write=\(record.writer?.offset ?? 0)/\(record.writer?.bytes.count ?? 0) flights=\(flights)"
		}.joined(separator: "\n")
	}
}
struct ReferenceStatus: Decodable {
	let port: UInt16
	let complete: Bool, seeding: Bool
	let downloaded: Int64, uploaded: Int64, failedBytes: Int64, redundantBytes: Int64
	let rc4: Int, negotiated: Int, utp: Int, tcp: Int, dhtPeers: Int, pexPeers: Int, dhtAnnounces: Int, readyPeers: Int
}

@main struct TCPTransferComparisonTests {
	static func main() async {
		do { try await run() } catch { try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(error)\n".utf8)); exit(1) }
	}
	static func wait(_ body: () async throws -> Bool) async throws {
		let deadline = ProcessInfo.processInfo.systemUptime + 20
		while ProcessInfo.processInfo.systemUptime < deadline { if try await body() { return }; try await Task.sleep(for: .milliseconds(10)) }
		throw PeerFailure.invalid("reference comparison deadline")
	}
	static func status(_ url: URL, process: Process) throws -> ReferenceStatus? {
		try require(process.isRunning, "Reference process exited before completion")
		guard FileManager.default.fileExists(atPath: url.path) else { return nil }
		return try JSONDecoder().decode(ReferenceStatus.self, from: Data(contentsOf: url))
	}
	static func stop(_ process: Process) async throws {
		if process.isRunning { process.terminate() }
		try await wait { !process.isRunning }
		try require(process.terminationStatus == 0, "Reference shutdown or flush failed")
	}
	static func run() async throws {
		let root = URL(fileURLWithPath: CommandLine.arguments[1]), binary = URL(fileURLWithPath: CommandLine.arguments[2])
		var cases = 0
		for transport in ["tcp", "utp"] { for encryption in ["disabled", "rc4", "negotiated", "prefer-rc4", "fallback"] { for version in [1, 2, 3] { for multi in [false, true] { for size in [16384, 65536] { for nativeSeed in [false, true] { for selective in (multi ? [false, true] : [false]) { for fragmented in (size == 65536 && !selective ? [false, true] : [false]) {
			if ["prefer-rc4", "fallback"].contains(encryption) && (multi || size != 16384 || fragmented) { continue }
			let host = fragmented && !multi ? "::1" : "127.0.0.1"
			let suffix = version == 1 ? "" : version == 2 ? "-v2" : "-hybrid"
			let label = "\(multi ? "multi" : "single")-\(size)\(suffix)-\(nativeSeed ? "up" : "down")-\(selective ? "selective" : "all")\(fragmented ? (host == "::1" ? "-fragmented-ipv6" : "-fragmented-ipv4") : "")-\(encryption)-\(transport)"
			if let filter = ProcessInfo.processInfo.environment["BUTTER_REFERENCE_FILTER"], !label.contains(filter) { continue }
			let work = root.appendingPathComponent(label)
			try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
			let metadataURL = root.appendingPathComponent("\(multi ? "multi" : "single")-\(size)\(suffix).torrent"), metadata = try TorrentMetadata(contentsOf: metadataURL)
			let selected = metadata.inspection.files.map { !$0.pad && (!selective || $0.path.hasSuffix("a.bin")) }
			let destination = work.appendingPathComponent("swift-data"), state = work.appendingPathComponent("swift-state")
			let transferMetadata = nativeSeed || version == 1 ? metadata : try TorrentMetadata(infoBytes: metadata.originalInfo, expected: metadata.hashes)
			let storage = try await TorrentStorage.open(metadata: transferMetadata, destination: destination, stateDirectory: state, selected: nativeSeed ? nil : selected)
			if nativeSeed {
				try await storage.importFiles(from: root.appendingPathComponent("reference-seed"))
				for piece in 0..<storage.layout.pieceCount { let valid = try await storage.verify(piece: piece); try require(valid, "Native source did not verify") }
			}
			var configuration = TCPTransferConfiguration()
			switch encryption {
			case "disabled": configuration.encryption = .disabled
			case "rc4": configuration.encryption = .init(incoming: .required, outgoing: .required, levels: .rc4)
			case "negotiated": configuration.encryption = .init(incoming: .required, outgoing: .required)
			case "prefer-rc4": configuration.encryption = .init(preferRC4: true)
			default: configuration.encryption = .init(incoming: .disabled)
			}
			let engine = try await TCPTransfer.open(metadata: transferMetadata, storage: storage, configuration: configuration)
			let listener = transport == "tcp" ? try await TCPListener.listen(address: IPAddress(host)) : nil
			let udp = transport == "utp" ? UDPDispatcher(transport: try DatagramSocket(bind: NetworkEndpoint(host, port: 0))) : nil
			let utp: UTPTransport?
			if let udp { utp = try await UTPTransport.open(dispatcher: udp) } else { utp = nil }
			let listeningPort = listener?.port ?? utp!.localEndpoint.port
			var relay: TCPFragmentingRelay?
			var impaired: UTPImpairingRelay?
			if nativeSeed && fragmented {
				if transport == "utp" { impaired = try await UTPImpairingRelay.open(host: host, target: NetworkEndpoint(host, port: listeningPort), loseSYN: false, loseSYNACK: true) }
				else { relay = try await TCPFragmentingRelay.open(host: host, target: NetworkEndpoint(host, port: listeningPort), handshakeBytes: encryption == "disabled" ? 68 : 2048) }
			}
			let record = work.appendingPathComponent("status.json"), jobURL = work.appendingPathComponent("job.json")
			var job: [String: Any] = ["torrent": metadataURL.path, "destination": nativeSeed ? work.appendingPathComponent("reference-download").path : root.appendingPathComponent("reference-seed").path,
				"listen": host == "::1" ? "[::1]:0" : "127.0.0.1:0", "status": record.path, "remoteHost": host, "remotePort": nativeSeed ? Int(relay?.port ?? impaired?.port ?? listeningPort) : 0, "transport": transport]
			if nativeSeed && selective { job["selected"] = selected }
			job["encryption"] = encryption == "fallback" && !nativeSeed ? "disabled" : encryption
			if nativeSeed && version > 1 && !multi { job["magnet"] = Magnet(hashes: metadata.hashes).uri }
			try JSONSerialization.data(withJSONObject: job).write(to: jobURL)
			let process = Process(); process.executableURL = binary; process.arguments = ["--run", jobURL.path]
			var accept: Task<UUID, Error>?
			do {
				if nativeSeed {
					accept = Task {
						var id = UUID()
						if let utp { while !Task.isCancelled { id = try await engine.attach(utp.accept(timeout: 30)) }; throw CancellationError() }
						for _ in 0..<(encryption == "fallback" ? 2 : 1) { id = try await engine.attach(listener!.accept(timeout: 10)) }; return id
					}
				}
				try process.run()
				if !nativeSeed {
					try await wait { let s = try status(record, process: process); return s?.seeding == true && s!.port > 0 }
					let s = try status(record, process: process)!
					if version > 1 && !multi {
						let fetched = try await MetadataExchange(encryption: configuration.encryption, utp: utp).fetch(Magnet(hashes: metadata.hashes), peers: [NetworkEndpoint(host, port: s.port)], timeout: 10)
						try require(fetched.originalInfo == metadata.originalInfo && fetched.pieceLayers.isEmpty, "Reference metadata exchange changed info bytes")
					}
					if fragmented {
						if transport == "utp" { impaired = try await UTPImpairingRelay.open(host: host, target: NetworkEndpoint(host, port: s.port)) }
						else { relay = try await TCPFragmentingRelay.open(host: host, target: NetworkEndpoint(host, port: s.port), handshakeBytes: encryption == "disabled" ? 68 : 2048) }
					}
					_ = try await engine.connect(to: NetworkEndpoint(host, port: relay?.port ?? impaired?.port ?? s.port), utp: utp)
				}
				if let accept, utp == nil { _ = try await accept.value }
				try await wait {
					let reference = try status(record, process: process)
					if nativeSeed { return reference?.complete == true && reference!.downloaded > 0 }
					let s = await engine.snapshot(); try require(s.storageError == nil, s.storageError ?? ""); return s.complete && (reference?.uploaded ?? 0) > 0
				}
				let swift = await engine.snapshot(), reference = try status(record, process: process)!
				let expectedMode: PeerEncryptionMode = encryption == "rc4" || encryption == "prefer-rc4" ? .rc4 : encryption == "negotiated" ? .negotiatedPlaintext : .plaintext
				try require(swift.peers.contains { $0.peerID != nil && $0.encryption == expectedMode }, "Native negotiated mode differs")
				try require(swift.peers.contains { $0.peerID != nil && $0.transport == (transport == "utp" ? .utp : .tcp) }, "Native transport differs")
				if transport == "utp" { try require(reference.utp > 0 && reference.tcp == 0, "Reference used TCP in a TCP-disabled fixture") }
				if let impaired {
					let drops = await impaired.dropped, duplicates = await impaired.duplicated, reorders = await impaired.reordered
					try require(drops > 0 && duplicates > 0 && reorders > 0, "UDP fixture did not exercise every impairment")
				}
				if expectedMode == .rc4 { try require(reference.rc4 > 0, "Reference did not record RC4") }
				if expectedMode == .negotiatedPlaintext { try require(reference.negotiated > 0, "Reference did not record negotiated plaintext") }
				try require(nativeSeed ? swift.uploaded > 0 && reference.downloaded > 0 : swift.downloaded > 0 && reference.uploaded > 0, "No cross-engine payload traffic was recorded")
				if utp != nil { accept?.cancel(); _ = try? await accept?.value }
				try await engine.shutdown(); try await listener?.shutdown(); await relay?.close(); await impaired?.close(); await utp?.shutdown(); try await udp?.shutdown(); try await stop(process); try await storage.shutdown()
				let output = nativeSeed ? work.appendingPathComponent("reference-download") : destination
				for file in metadata.inspection.files where !file.pad && (!selective || file.path.hasSuffix("a.bin")) {
					let expected = try Data(contentsOf: root.appendingPathComponent("reference-seed").appendingPathComponent(file.path))
					try require(try Data(contentsOf: output.appendingPathComponent(file.path)) == expected, "Cross-engine bytes differ")
				}
				if selective, !nativeSeed { try require(!FileManager.default.fileExists(atPath: output.appendingPathComponent("Bundle/nested/b.bin").path), "Skipped file was materialised") }
				cases += 1; print("PASS: \(label), verified bytes after both shutdown barriers")
			} catch {
				if let impaired { try? FileHandle.standardError.write(contentsOf: Data((await impaired.diagnostics() + "\n").utf8)) }
				if let utp { try? FileHandle.standardError.write(contentsOf: Data((await utp.comparisonDiagnostics() + "\n").utf8)) }
				let snapshot = await engine.snapshot()
				let detail = "FAIL: \(label): \(error); native peer=\(snapshot.lastPeerError ?? "none") disk=\(snapshot.storageError ?? "none") up=\(snapshot.uploaded) down=\(snapshot.downloaded) peers=\(snapshot.peers.count)\n"
				try? FileHandle.standardError.write(contentsOf: Data(detail.utf8))
				if let data = try? Data(contentsOf: record) { try? FileHandle.standardError.write(contentsOf: data) }
				accept?.cancel(); try? await engine.shutdown(); try? await listener?.shutdown(); await relay?.close(); await impaired?.close(); await utp?.shutdown(); try? await udp?.shutdown(); try? await storage.shutdown()
				if process.isRunning { process.terminate(); try? await stop(process); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }; throw error
			}
		} } } } } } } }
		print("PASS: \(cases) independent libtorrent-to-Swift and Swift-to-libtorrent peer fixtures")
		let filter = ProcessInfo.processInfo.environment["BUTTER_REFERENCE_FILTER"]
		if filter == nil || filter == "DHT" || filter == "session-dht" { try await runDHTComparisons(root: root, binary: binary) }
		if filter == nil || filter == "session" { try await runSessionComparisons(root: root, binary: binary) }
		if filter == nil || filter == "session-trackers" { try await runTrackerComparisons(root: root, binary: binary) }
		if filter == nil || filter == "session-dht" { try await runSessionDHTComparisons(root: root, binary: binary) }
		if filter == nil || filter == "hints" { try await runHintComparisons(root: root, binary: binary) }
		if filter == nil || filter == "webseed" { try await runWebSeedComparisons(root: root, binary: binary) }
	}
}
