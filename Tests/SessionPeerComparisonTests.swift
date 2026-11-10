import Foundation
import Darwin
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentEngine

private func sessionRequire(_ value: Bool, _ message: String) throws {
	if !value { throw PeerFailure.invalid(message) }
}

extension TCPTransferComparisonTests {
	static func runSessionComparisons(root: URL, binary: URL) async throws {
		var cases = 0
		for transport in ["tcp", "utp"] { for encryption in ["disabled", "rc4", "negotiated"] { for version in [1, 2, 3] { for nativeSeed in [false, true] {
			let suffix = version == 1 ? "" : version == 2 ? "-v2" : "-hybrid", host = version == 1 ? "127.0.0.1" : "::1"
			let label = "session-v\(version)-\(nativeSeed ? "up" : "down")-\(transport)-\(encryption)", work = root.appendingPathComponent(label)
			if let filter = ProcessInfo.processInfo.environment["BUTTER_SESSION_FILTER"], !label.contains(filter) { continue }
			try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
			let source = root.appendingPathComponent("single-16384\(suffix).torrent"), metadata = try TorrentMetadata(contentsOf: source)
			var config = TCPTransferConfiguration()
			config.encryption = encryption == "disabled" ? .disabled : .init(incoming: .required, outgoing: .required, levels: encryption == "rc4" ? .rc4 : .both)
			let session = TorrentSession(storage: work.appendingPathComponent("native-state"), configuration: config, loopbackOnly: true)
			let destination = nativeSeed ? root.appendingPathComponent("reference-seed") : work.appendingPathComponent("native-download")
			let record = work.appendingPathComponent("status.json"), jobURL = work.appendingPathComponent("job.json")
			let process = Process(); process.executableURL = binary; process.arguments = ["--run", jobURL.path]
			var relay: TCPFragmentingRelay?
			do {
				var settings = SessionPeerSettings(); settings.tcp = transport == "tcp"; settings.utp = transport == "utp"; settings.pex = false; settings.allowSameIP = true
				let port = try await session.configurePeers(settings)
				_ = try await session.add(id: "transfer", source: source, destination: destination); try await session.run(id: "transfer", running: true)
				if nativeSeed && transport == "tcp" { relay = try await TCPFragmentingRelay.open(host: host, target: NetworkEndpoint(host, port: port), handshakeBytes: encryption == "disabled" ? 68 : 2048) }
				var job: [String: Any] = ["torrent": source.path, "destination": nativeSeed ? work.appendingPathComponent("reference-download").path : root.appendingPathComponent("reference-seed").path,
					"listen": host == "::1" ? "[::1]:0" : "127.0.0.1:0", "status": record.path, "remoteHost": host, "remotePort": nativeSeed ? Int(relay?.port ?? port) : 0,
					"transport": transport, "encryption": encryption]
				if nativeSeed && version > 1 { job["magnet"] = Magnet(hashes: metadata.hashes).uri }
				try JSONSerialization.data(withJSONObject: job).write(to: jobURL); try process.run()
				if !nativeSeed {
					try await wait { let current = try status(record, process: process); return current?.seeding == true && current!.port > 0 }
					let peer = try status(record, process: process)!
					_ = try await session.connect(id: "transfer", to: NetworkEndpoint(host, port: peer.port))
				}
				try await wait {
					let reference = try status(record, process: process), native = try await session.snapshot().transfers[0]
					try sessionRequire(native.error.isEmpty && native.state.transfer?.storageError == nil, "native session storage error")
					guard let reference, let wire = native.state.transfer else { return false }
					let downloaded = nativeSeed ? reference.downloaded : wire.downloaded - wire.corruptBytes - wire.redundantBytes
					let uploaded = nativeSeed ? wire.uploaded : reference.uploaded
					let expected = metadata.inspection.files.filter { !$0.pad }.reduce(Int64(0)) { $0 + $1.size }
					return (nativeSeed ? reference.complete : wire.complete) && downloaded == expected && uploaded == expected
				}
				let native = try await session.snapshot().transfers[0], reference = try status(record, process: process)!
				try sessionRequire(native.state.transfer?.corruptBytes == 0 && native.state.transfer?.redundantBytes == 0 && reference.failedBytes == 0, "healthy fixture recorded unusable file payload")
				// libtorrent also charges late ut_metadata replies to its redundant counter,
				// although they are excluded from total_payload_download. Keep that protocol
				// accounting distinct from the exact file-payload assertions above.
				try sessionRequire(reference.redundantBytes == 0 || (nativeSeed && version > 1 && reference.redundantBytes % Int64(metadata.originalInfo.count) == 0), "reference redundancy is not a complete metadata reply")
				let mode: PeerEncryptionMode = encryption == "rc4" ? .rc4 : encryption == "negotiated" ? .negotiatedPlaintext : .plaintext
				try sessionRequire(native.state.transfer?.peers.contains { $0.peerID != nil && $0.encryption == mode && $0.transport == (transport == "utp" ? .utp : .tcp) } == true, "routed native transport or encryption differs")
				if transport == "utp" { try sessionRequire(reference.utp > 0 && reference.tcp == 0, "session comparison used TCP with TCP disabled") }
				if encryption == "rc4" { try sessionRequire(reference.rc4 > 0, "reference session did not negotiate RC4") }
				if encryption == "negotiated" { try sessionRequire(reference.negotiated > 0, "reference session did not negotiate plaintext") }
				try sessionRequire(nativeSeed ? (native.state.transfer?.uploaded ?? 0) > 0 : (native.state.transfer?.downloaded ?? 0) > 0, "session payload counters did not advance")
				try await session.shutdown(); try await session.close(); await relay?.close(); try await stop(process)
				let output = nativeSeed ? work.appendingPathComponent("reference-download") : destination
				for file in metadata.inspection.files where !file.pad {
					let expected = try Data(contentsOf: root.appendingPathComponent("reference-seed").appendingPathComponent(file.path))
					try sessionRequire(try Data(contentsOf: output.appendingPathComponent(file.path)) == expected, "routed session bytes differ")
				}
				cases += 1; print("PASS: \(label), independent payload counters matched and bytes verified after shutdown")
			} catch {
				try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(label): \(error)\n".utf8))
				if let wire = try? await session.snapshot().transfers[0].state.transfer {
					try? FileHandle.standardError.write(contentsOf: Data("Native payload: down=\(wire.downloaded) up=\(wire.uploaded) corrupt=\(wire.corruptBytes) redundant=\(wire.redundantBytes); info=\(metadata.originalInfo.count) bytes; peer=\(wire.lastPeerError ?? "")\n".utf8))
				}
				if let status = try? Data(contentsOf: record) { try? FileHandle.standardError.write(contentsOf: status) }
				try? await session.close(); await relay?.close()
				if process.isRunning { process.terminate(); try? await stop(process); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }; throw error
			}
		} } } }
		print("PASS: \(cases) independent native-session transfers in both directions")
	}
}
