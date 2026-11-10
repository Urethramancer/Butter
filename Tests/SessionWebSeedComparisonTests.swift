import Foundation
import Darwin
import ButterTorrentMetadata
@testable import ButterTorrentNetworking
import ButterTorrentEngine

extension TCPTransferComparisonTests {
	static func runWebSeedComparisons(root: URL, binary: URL) async throws {
		var cases = 0
		for version in [1, 2, 3] { for multi in [false, true] { for pieceProtocol in (version == 2 ? [false] : [false, true]) {
			let suffix = version == 1 ? "" : version == 2 ? "-v2" : "-hybrid"
			let label = "webseed-v\(version)-\(multi ? "multi" : "single")-\(pieceProtocol ? "piece" : "file")", work = root.appendingPathComponent(label)
			try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
			let original = root.appendingPathComponent("\(multi ? "multi" : "single")-65536\(suffix).torrent"), metadata = try TorrentMetadata(contentsOf: original)
			var files: [String: Data] = [:], payload = Data()
			for file in metadata.inspection.files {
				let bytes = file.pad ? Data(repeating: 0, count: Int(file.size)) : try Data(contentsOf: root.appendingPathComponent("reference-seed/" + file.path))
				if !file.pad { files[file.path] = bytes }; payload.append(bytes)
			}
			let expectedFiles = files, expectedPayload = payload
			let server = try await HTTPFixture.start { input in
				guard let parts = URLComponents(string: "http://fixture" + input.target) else { return .init(status: 400) }
				if parts.path == "/piece" {
					let fields = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
					guard input.target.contains("info_hash=" + HTTPURL.encode(metadata.hashes.v1!)), let piece = fields["piece"].flatMap(Int.init), let range = fields["ranges"] else { return .init(status: 400) }
					let bounds = range.split(separator: "-").compactMap { Int($0) }, start = piece * Int(metadata.pieceLength)
					guard bounds.count == 2, bounds[0] >= 0, bounds[1] >= bounds[0], start + bounds[1] < expectedPayload.count else { return .init(status: 416) }
					return .init(body: expectedPayload.subdata(in: (start + bounds[0])..<(start + bounds[1] + 1)), chunked: true)
				}
				if parts.path.hasPrefix("/redirect/") { return .init(status: 302, headers: ["Location": "/files/" + parts.percentEncodedPath.dropFirst("/redirect/".count)]) }
				guard parts.path.hasPrefix("/files/"), let bytes = expectedFiles[String(parts.path.dropFirst("/files/".count))], let range = input.headers["range"], range.hasPrefix("bytes=") else { return .init(status: 404) }
				let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
				guard bounds.count == 2, bounds[0] >= 0, bounds[1] >= bounds[0], bounds[1] < bytes.count else { return .init(status: 416) }
				return .init(status: 206, headers: ["Content-Range": "bytes \(bounds[0])-\(bounds[1])/\(bytes.count)"], body: bytes.subdata(in: bounds[0]..<(bounds[1] + 1)), chunked: true)
			}
			let session = TorrentSession(storage: work.appendingPathComponent("library"), configuration: .init(), loopbackOnly: true)
			let record = work.appendingPathComponent("status.json"), jobURL = work.appendingPathComponent("job.json")
			let process = Process(); process.executableURL = binary; process.arguments = ["--run", jobURL.path]
			do {
				var fields = metadata.document.root.dictionary!
				let url = server.url.absoluteString + (pieceProtocol ? "/piece" : "/redirect/")
				fields[Data((pieceProtocol ? "httpseeds" : "url-list").utf8)] = .list([.bytes(Data(url.utf8))])
				let source = work.appendingPathComponent("web.torrent"); try BencodeValue.dictionary(fields).encoded().write(to: source)
				_ = try await session.add(id: "transfer", source: source, destination: work.appendingPathComponent("native-download"))
				try await session.run(id: "transfer", running: true)
				try await wait { try await session.snapshot().transfers[0].state.transfer?.complete == true }
				let downloaded = try await session.snapshot().transfers[0].state
				guard downloaded.transfer?.peers.isEmpty == true, downloaded.transfer?.corruptPieces == 0, downloaded.storage.verifiedPieces.count > 0 else { throw PeerFailure.invalid("web seed verification or isolation") }
				try await session.pause(id: "transfer")
				var settings = SessionPeerSettings(); settings.utp = false; settings.pex = false
				let port = try await session.configurePeers(settings); try await session.run(id: "transfer", running: true)
				// The reference receives the original torrent, without HTTP URLs: all its bytes must come from the native peer.
				let job: [String: Any] = ["torrent": original.path, "destination": work.appendingPathComponent("reference-download").path,
					"listen": "127.0.0.1:0", "status": record.path, "remoteHost": "127.0.0.1", "remotePort": Int(port), "transport": "tcp", "encryption": "disabled"]
				try JSONSerialization.data(withJSONObject: job).write(to: jobURL); try process.run()
				try await wait { try status(record, process: process)?.complete == true }
				try await session.close(); try await stop(process); await server.stop()
				for (path, expected) in expectedFiles {
					guard try Data(contentsOf: work.appendingPathComponent("native-download/" + path)) == expected,
						try Data(contentsOf: work.appendingPathComponent("reference-download/" + path)) == expected else { throw PeerFailure.invalid("web seed/reference payload differs") }
				}
				cases += 1; print("PASS: \(label), HTTP bytes verified and independently transferred to libtorrent")
			} catch {
				try? await session.close(); await server.stop()
				if process.isRunning { process.terminate(); try? await stop(process); if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
				try? FileHandle.standardError.write(contentsOf: Data("FAIL: \(label): \(error)\n".utf8)); throw error
			}
		} } }
		print("PASS: \(cases) HTTP-to-native-to-libtorrent web-seed comparisons")
	}
}
