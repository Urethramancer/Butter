import Foundation
import Darwin
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentEngine

extension TCPTransferComparisonTests {
	static func runHintComparisons(root: URL, binary: URL) async throws {
		var cases = 0
		for kind in ["pex", "port"] { for version in [1, 2, 3] { for utp in [false, true] { for nativeSeed in [false, true] {
			let suffix = version == 1 ? "" : version == 2 ? "-v2" : "-hybrid", label = "hint-\(kind)-v\(version)-\(utp ? "utp" : "tcp")-\(nativeSeed ? "up" : "down")"
			if let filter = ProcessInfo.processInfo.environment["BUTTER_HINT_FILTER"], !label.contains(filter) { continue }
			let work = root.appendingPathComponent(label); try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
			let source = root.appendingPathComponent("single-16384\(suffix).torrent"), metadata = try TorrentMetadata(contentsOf: source), isPORT = kind == "port"
			var configuration = TCPTransferConfiguration(); configuration.encryption = .disabled
			var sessions: [TorrentSession] = [], references: [HintReferencePeer] = []
			do {
				var settings = SessionPeerSettings(); settings.tcp = !utp; settings.utp = utp; settings.pex = !isPORT; settings.dht = isPORT; settings.allowSameIP = true
				let consumer: HintReferencePeer?
				let native: TorrentSession
				if nativeSeed {
					let introducer = TorrentSession(storage: work.appendingPathComponent("intro-library"), configuration: configuration, loopbackOnly: true, dhtBootstrap: []); sessions.append(introducer)
					let introPort = try await introducer.configurePeers(settings)
					_ = try await introducer.add(id: "transfer", source: source, destination: work.appendingPathComponent("intro-empty"), selected: metadata.inspection.files.map { _ in false }); try await introducer.run(id: "transfer", running: true)
					native = TorrentSession(storage: work.appendingPathComponent("seed-library"), configuration: configuration, loopbackOnly: true, dhtBootstrap: isPORT ? [try NetworkEndpoint("127.0.0.1", port: introPort)] : []); sessions.append(native)
					let seedPort = try await native.configurePeers(settings)
					_ = try await native.add(id: "transfer", source: source, destination: root.appendingPathComponent("reference-seed")); try await native.run(id: "transfer", running: true)
					if isPORT { try await wait { let state = try await native.snapshot().network.discovery; return state.contacts > 0 && state.searches == 0 } }
					else {
						_ = try await introducer.connect(id: "transfer", to: NetworkEndpoint("127.0.0.1", port: seedPort))
						try await wait { try await introducer.snapshot().transfers[0].state.transfer?.peers.contains { $0.peerID != nil } == true }
					}
					consumer = try await HintReferencePeer.open(root: work, name: "consumer", binary: binary, source: source, destination: work.appendingPathComponent("reference-download"), seeded: false, utp: utp, remotePort: introPort, dht: isPORT, pex: !isPORT); references.append(consumer!)
					try await wait { try consumer!.status().complete }
					let status = try consumer!.status()
					guard isPORT ? status.dhtPeers > 0 : status.pexPeers > 0 else { throw PeerFailure.invalid("reference did not discover its data peer through the selected hint protocol") }
					guard try await introducer.snapshot().transfers[0].state.transfer?.uploaded == 0 else { throw PeerFailure.invalid("empty introducer supplied payload") }
				} else {
					let intro: HintReferencePeer
					if isPORT {
						intro = try await HintReferencePeer.open(root: work, name: "introducer", binary: binary, source: source, destination: root.appendingPathComponent("reference-seed"), seeded: true, utp: utp, dht: true, pex: false, noPayload: true); references.append(intro)
						let seed = try await HintReferencePeer.open(root: work, name: "seed", binary: binary, source: source, destination: root.appendingPathComponent("reference-seed"), seeded: true, utp: utp, dhtPort: intro.status().port, pex: false); references.append(seed)
						try await wait { try intro.status().dhtAnnounces > 0 }
					} else {
						let seed = try await HintReferencePeer.open(root: work, name: "seed", binary: binary, source: source, destination: root.appendingPathComponent("reference-seed"), seeded: true, utp: utp); references.append(seed)
						intro = try await HintReferencePeer.open(root: work, name: "introducer", binary: binary, source: source, destination: root.appendingPathComponent("reference-seed"), seeded: true, utp: utp, remotePort: seed.status().port, noPayload: true); references.append(intro)
						try await wait { try intro.status().readyPeers > 0 }
					}
					native = TorrentSession(storage: work.appendingPathComponent("down-library"), configuration: configuration, loopbackOnly: true, dhtBootstrap: []); sessions.append(native)
					_ = try await native.configurePeers(settings)
					_ = try await native.add(id: "transfer", source: source, destination: work.appendingPathComponent("native-download")); try await native.run(id: "transfer", running: true)
					_ = try await native.connect(id: "transfer", to: NetworkEndpoint("127.0.0.1", port: intro.status().port))
					try await wait { try await native.snapshot().transfers[0].state.transfer?.complete == true }
					guard try intro.status().uploaded == 0 else { throw PeerFailure.invalid("payload-suppressed introducer supplied torrent bytes") }
					consumer = nil
				}
				for session in sessions { try await session.close() }; for reference in references { try await reference.close() }
				let destination = work.appendingPathComponent(nativeSeed ? "reference-download" : "native-download")
				for file in metadata.inspection.files where !file.pad {
					guard try Data(contentsOf: destination.appendingPathComponent(file.path)) == Data(contentsOf: root.appendingPathComponent("reference-seed/" + file.path)) else { throw PeerFailure.invalid("hint-discovered payload differs") }
				}
				cases += 1; print("PASS: \(label), introducer supplied no payload; independent data peer discovered")
			} catch {
				for session in sessions {
					if let snapshot = try? await session.snapshot() {
						let rows: [[String: Any]] = snapshot.transfers.map { row in ["id": row.id, "error": row.error, "peerError": row.state.transfer?.lastPeerError ?? "", "diskError": row.state.transfer?.storageError ?? "", "downloaded": row.state.transfer?.downloaded ?? 0, "pieces": row.state.storage.verifiedPieces.sorted(), "peers": (row.state.transfer?.peers ?? []).map { ["endpoint": $0.endpoint?.description ?? "", "client": $0.client, "v2": $0.v2, "downloaded": $0.downloaded] as [String: Any] }] }
						if let bytes = try? JSONSerialization.data(withJSONObject: rows) { try? FileHandle.standardError.write(contentsOf: bytes) }
					}
				}
				for reference in references { if let data = try? Data(contentsOf: reference.record) { try? FileHandle.standardError.write(contentsOf: data) } }
				for session in sessions { try? await session.close() }; for reference in references { try? await reference.close() }
				try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(label): \(error)\n".utf8)); throw error
			}
		} } } }
		print("PASS: \(cases) independent PEX/PORT discovery comparisons in both directions")
	}
}

private final class HintReferencePeer {
	let process: Process
	let record: URL
	init(process: Process, record: URL) { self.process = process; self.record = record }
	static func open(root: URL, name: String, binary: URL, source: URL, destination: URL, seeded: Bool, utp: Bool,
		remotePort: UInt16 = 0, dht: Bool = false, dhtPort: UInt16 = 0, pex: Bool = true, noPayload: Bool = false) async throws -> HintReferencePeer {
		let record = root.appendingPathComponent(name + "-status.json"), jobURL = root.appendingPathComponent(name + "-job.json")
		let job: [String: Any] = ["torrent": source.path, "destination": destination.path, "listen": "127.0.0.1:0", "status": record.path,
			"remoteHost": "127.0.0.1", "remotePort": Int(remotePort), "transport": utp ? "utp" : "tcp", "encryption": "disabled",
			"dht": dht, "dhtPort": Int(dhtPort), "pex": pex, "noPayload": noPayload, "diagnostics": true]
		try JSONSerialization.data(withJSONObject: job).write(to: jobURL)
		let process = Process(); process.executableURL = binary; process.arguments = ["--run", jobURL.path]; try process.run()
		let peer = HintReferencePeer(process: process, record: record)
		do { try await TCPTransferComparisonTests.wait { guard let status = try TCPTransferComparisonTests.status(record, process: process) else { return false }; return status.port > 0 && (!seeded || status.seeding) }; return peer }
		catch { try? await peer.close(); throw error }
	}
	func status() throws -> ReferenceStatus {
		guard let status = try TCPTransferComparisonTests.status(record, process: process) else { throw PeerFailure.invalid("reference status unavailable") }; return status
	}
	func close() async throws {
		do { try await TCPTransferComparisonTests.stop(process) }
		catch { if process.isRunning { kill(process.processIdentifier, SIGKILL) }; throw error }
	}
}
