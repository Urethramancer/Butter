import Foundation
import CryptoKit
import Testing
import ButterTorrentMetadata
@testable import ButterTorrentNetworking

private final class RequestLog: @unchecked Sendable {
	private let lock = NSLock()
	private var values: [String] = []
	func append(_ target: String) { lock.withLock { values.append(target) } }
	var targets: [String] { lock.withLock { values } }
}

// Headless package harness: services operate on native metadata and verify bytes
// before announcing completion. Production still uses the libtorrent backend.
@Suite struct HTTPIntegrationTests {
	@Test func metadataThroughTrackersAndBothWebSeedProtocols() async throws {
		let root = FileManager.default.temporaryDirectory.appendingPathComponent("ButterHTTP-\(UUID().uuidString)")
		let source = root.appendingPathComponent("Bundle")
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
		defer { try? FileManager.default.removeItem(at: root) }
		let files = ["Bundle/a": Data(repeating: 42, count: 16383), "Bundle/Å &.bin": Data((0..<32771).map { UInt8($0 % 251) }), "Bundle/empty": Data()]
		for (path, bytes) in files { try bytes.write(to: root.appendingPathComponent(path)) }
		let metadata = try TorrentMetadata(TorrentCreator.create(source: source, trackers: [], isPrivate: false, pieceLength: 16384))
		var payload = Data()
		for file in metadata.inspection.files { payload.append(file.pad ? Data(repeating: 0, count: Int(file.size)) : files[file.path]!) }
		let expected = payload, hashes = metadata.document.root["info"]!["pieces"]!.bytes!
		let log = RequestLog(), announceBody = try trackerBody()
		let server = try await HTTPFixture.start { input in
			log.append(input.target)
			if input.target.hasPrefix("/announce?") { return .init(body: announceBody, chunked: true) }
			if input.target.hasPrefix("/redirect/") { return .init(status: 302, headers: ["Location": "/files/" + input.target.dropFirst("/redirect/".count)]) }
			guard let parts = URLComponents(string: "http://fixture" + input.target) else { return .init(status: 400) }
			if parts.path == "/seed" {
				let fields = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
				guard input.target.contains("info_hash=" + HTTPURL.encode(metadata.hashes.v1!)), let index = fields["piece"].flatMap(Int.init), index >= 0, index < expected.count / 16384 else { return .init(status: 400) }
				let piece = expected.subdata(in: index * 16384..<(index + 1) * 16384)
				if let selected = fields["ranges"] {
					let range = selected.split(separator: "-").compactMap { Int($0) }
					guard range.count == 2, range[0] >= 0, range[0] <= range[1], range[1] < piece.count else { return .init(status: 400) }
					return .init(body: piece.subdata(in: range[0]..<(range[1] + 1)), chunked: true)
				}
				return .init(body: piece, chunked: true)
			}
			guard parts.path.hasPrefix("/files/"), let bytes = files[String(parts.path.dropFirst("/files/".count))], let header = input.headers["range"], header.hasPrefix("bytes=") else { return .init(status: 404) }
			let range = header.dropFirst(6).split(separator: "-").compactMap { Int($0) }
			guard range.count == 2, range[0] >= 0, range[0] <= range[1], range[1] < bytes.count else { return .init(status: 416) }
			return .init(status: 206, headers: ["Content-Range": "bytes \(range[0])-\(range[1])/\(bytes.count)"], body: bytes.subdata(in: range[0]..<(range[1] + 1)), chunked: true)
		}
		do {
			let transport = FoundationHTTPTransport()
			let announcer = try TrackerAnnouncer(tiers: [[server.url.appendingPathComponent("announce")]], request: trackerRequest(left: Int64(expected.count)), client: HTTPTrackerClient(transport: transport))
			try await announcer.start(TrackerCounters(left: Int64(expected.count)))
			let seeds = WebSeedClient(transport: transport)
			let base = URL(string: server.url.absoluteString + "/redirect/")!
			var downloaded = Data()
			for file in metadata.inspection.files {
				if file.pad { downloaded.append(Data(repeating: 0, count: Int(file.size))); continue }
				if file.size == 0 { continue }
				downloaded.append(try await seeds.fileRange(from: base, path: file.path.split(separator: "/").map(String.init), fileSize: file.size, range: 0..<file.size, multiFile: true))
			}
			guard downloaded == expected else { throw HTTPServiceError.invalid("URL seed bytes differ") }
			for index in 0..<downloaded.count / 16384 {
				let block = downloaded.subdata(in: index * 16384..<(index + 1) * 16384)
				guard Data(Insecure.SHA1.hash(data: block)) == hashes.subdata(in: index * 20..<(index + 1) * 20) else { throw HTTPServiceError.invalid("URL seed hash mismatch") }
				let fromHTTPSeed = try await seeds.pieceRange(from: server.url.appendingPathComponent("seed"), infoHash: metadata.hashes.v1!, piece: index, pieceSize: 16384)
				guard fromHTTPSeed == block else { throw HTTPServiceError.invalid("HTTP seed piece differs") }
			}
			let partial = try await seeds.pieceRange(from: server.url.appendingPathComponent("seed"), infoHash: metadata.hashes.v1!, piece: 0, pieceSize: 16384, range: 1..<17)
			#expect(partial == expected.subdata(in: 1..<17))
			try await announcer.complete(TrackerCounters(downloaded: Int64(downloaded.count), left: 0))
			try await announcer.stop(TrackerCounters(downloaded: Int64(downloaded.count), left: 0))
			#expect(log.targets.filter { $0.hasPrefix("/announce?") }.compactMap { URLComponents(string: "http://fixture" + $0)?.queryItems?.first { $0.name == "event" }?.value } == ["started", "completed", "stopped"])
		} catch { await server.stop(); throw error }
		await server.stop()
	}
}
