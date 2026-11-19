import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentStorage
@testable import ButterTorrentNetworking
@testable import ButterTorrentEngine

// Independent multi-session fixtures share the production disk and HTTP budgets.
extension NativeSessionTests { @Suite struct SessionWebSeedTests {
	@Test(arguments: [262144, 1048576], [false, true]) func adjacentBlocksUseBoundedHTTPRanges(_ pieceLength: Int, _ pieceProtocol: Bool) async throws {
		let fixture = try TransferFixture(lengths: [pieceLength * 2 + 37, 0, 0, 0], pieceLength: pieceLength)
		let transport = try SeedFileTransport(metadata: fixture.metadata, root: fixture.root.appendingPathComponent("source"))
		let metadata = try webMetadata(fixture.metadata, urls: pieceProtocol ? [] : ["http://seed.invalid/files/"], pieces: pieceProtocol ? ["http://seed.invalid/piece"] : [])
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), webSeedTransport: transport)
		do {
			try await addWebTransfer(session, metadata: metadata, root: fixture.root)
			try await session.run(id: "transfer", running: true)
			try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
			let snapshot = try await session.snapshot().transfers[0].state.transfer
			#expect(snapshot?.downloaded == Int64(fixture.bytes.count))
			#expect(snapshot?.redundantBytes == 0 && snapshot?.corruptBytes == 0)
			try await session.close()
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/bundle/a")) == fixture.bytes)
			let requests = await transport.requests
			#expect(requests.count == (fixture.bytes.count + 262143) / 262144)
			#expect(requests.allSatisfy { $0.maximumResponseBytes <= 262144 })
		} catch { try? await session.close(); await fixture.clean(); throw error }
		await fixture.clean()
	}
	@Test(arguments: [1, 2, 3]) func remoteNamesSurviveLocalSanitisation(_ version: Int) async throws {
		try await transferFixture { fixture in
			let remoteName = "remote\\name\u{200B}.bin", bytes = Data("abc".utf8)
			let original = fixture.root.appendingPathComponent(remoteName)
			try bytes.write(to: original)
			let hybrid = try TorrentMetadata(TorrentCreator.create(source: original, trackers: [], isPrivate: false))
			var fields = hybrid.document.root.dictionary!, info = hybrid.document.root["info"]!.dictionary!
			if version == 1 { info[Data("meta version".utf8)] = nil; info[Data("file tree".utf8)] = nil; fields[Data("piece layers".utf8)] = nil }
			if version == 2 { info[Data("length".utf8)] = nil; info[Data("pieces".utf8)] = nil }
			fields[Data("info".utf8)] = .dictionary(info)
			let metadata = try webMetadata(TorrentMetadata(BencodeValue.dictionary(fields).encoded()), urls: ["http://seed.invalid/files/"])
			let local = metadata.inspection.files.first { !$0.pad }!
			#expect(local.path != remoteName && metadata.remotePaths[local.index] == [Data(remoteName.utf8)])
			let source = fixture.root.appendingPathComponent("web-source")
			try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
			try bytes.write(to: source.appendingPathComponent(local.path))
			let transport = try SeedFileTransport(metadata: metadata, root: source)
			let session = TorrentSession(storage: fixture.root.appendingPathComponent("web-library"), webSeedTransport: transport)
			do {
				try await addWebTransfer(session, metadata: metadata, root: fixture.root)
				try await session.run(id: "transfer", running: true)
				try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
				#expect(await transport.requests.first?.url.absoluteString.contains("remote%5Cname%E2%80%8B.bin") == true)
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/" + local.path)) == bytes)
				try await session.close()
			} catch { try? await session.close(); throw error }
		}
	}
	@Test func partialRangeFailureRetainsReceivedCountersAndHonoursBackoff() async throws {
		try await transferFixture { fixture in
			let transport = try SeedFileTransport(metadata: fixture.metadata, root: fixture.root.appendingPathComponent("source")), clock = EngineClock()
			await transport.failSkip(true)
			let metadata = try webMetadata(fixture.metadata, urls: ["http://seed.invalid/files/"])
			let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), clock: clock, webSeedTransport: transport)
			do {
				try await addWebTransfer(session, metadata: metadata, root: fixture.root); try await session.run(id: "transfer", running: true)
				try await eventually { await transport.requests.count == 2 && clock.sleepingCount == 2 }
				let failed = try await session.snapshot().transfers[0].state
				#expect(failed.transfer?.downloaded == 10003 && failed.storage.verifiedPieces.isEmpty)
				#expect(failed.transfer?.redundantBytes == 10003)
				clock.advance(29)
				try await eventually { clock.sleepingCount == 2 }
				#expect(await transport.requests.count == 2)
				await transport.failSkip(false); clock.advance(1)
				try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
				#expect(try await session.snapshot().transfers[0].state.transfer?.downloaded == Int64(fixture.bytes.count + 10003))
				try await session.close()
			} catch { try? await session.close(); throw error }
		}
	}
	@Test func rateLimitedHTTPBytesRemainUnverifiedAndPauseCancelsAdmission() async throws {
		try await transferFixture { fixture in
			let transport = try SeedFileTransport(metadata: fixture.metadata, root: fixture.root.appendingPathComponent("source")), clock = EngineClock()
			let metadata = try webMetadata(fixture.metadata, urls: ["http://seed.invalid/files/"]), resources = try TransferResources()
			var configuration = plainTransferConfiguration(); configuration.downloadLimit = 1
			let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), configuration: configuration, resources: resources, clock: clock, webSeedTransport: transport)
			do {
				try await addWebTransfer(session, metadata: metadata, root: fixture.root)
				try await session.run(id: "transfer", running: true)
				try await eventually { try await session.snapshot().transfers[0].state.transfer?.downloaded == 10003 }
				#expect(try await session.snapshot().transfers[0].state.storage.verifiedPieces.isEmpty)
				#expect(await resources.web.activeCount == 0)
				try await engineDeadline { try await session.pause(id: "transfer") }
				#expect(try await session.snapshot().transfers[0].state.storage.downloaded == 10003)
				try await session.run(id: "transfer", running: true, downloadLimit: 0)
				try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
				try await session.close()
			} catch { try? await session.close(); throw error }
		}
	}
	@Test(arguments: [1, 2, 3]) func URLSeedsVerifyAllFormatsAndSynthesizePadding(_ version: Int) async throws {
		let fixture = try V2Fixture(version: version), transport = try SeedFileTransport(metadata: fixture.metadata, root: fixture.root.appendingPathComponent("source"))
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), webSeedTransport: transport)
		do {
			let metadata = try webMetadata(fixture.metadata, urls: ["http://seed.invalid/files/"])
			try await addWebTransfer(session, metadata: metadata, root: fixture.root)
			try await session.run(id: "transfer", running: true)
			try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
			let snapshot = try await session.snapshot().transfers[0]
			#expect(snapshot.state.transfer?.peers.isEmpty == true && snapshot.state.transfer?.corruptPieces == 0)
			#expect(snapshot.state.transfer?.downloaded == metadata.inspection.files.filter { !$0.pad }.reduce(Int64(0)) { $0 + $1.size })
			#expect(snapshot.state.storage.verifiedPieces == snapshot.state.transfer?.wantedPieces)
			try await session.close()
			for file in metadata.inspection.files where !file.pad {
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/" + file.path)) == Data(contentsOf: fixture.root.appendingPathComponent("source/" + file.path)))
			}
			let requests = await transport.requests
			#expect(!requests.isEmpty && requests.allSatisfy { $0.maximumResponseBytes <= 262144 && !$0.url.path.contains(".pad") })
		} catch { try? await session.close(); await fixture.close(); throw error }; await fixture.close()
	}
	@Test func crossFileRangesRespectSelectionAndOriginalPaths() async throws {
		try await transferFixture { fixture in
			let transport = try SeedFileTransport(metadata: fixture.metadata, root: fixture.root.appendingPathComponent("source"))
			let metadata = try webMetadata(fixture.metadata, urls: ["http://seed.invalid/files/"])
			let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), webSeedTransport: transport)
			do {
				try await addWebTransfer(session, metadata: metadata, root: fixture.root, selected: [true, false, false, false])
				try await session.changeStorage(id: "transfer", change: .rename([0: "renamed"]))
				try await session.run(id: "transfer", running: true)
				try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
				#expect(try await session.snapshot().transfers[0].state.storage.verifiedPieces == [0])
				try await session.close()
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/renamed")) == fixture.bytes.prefix(10003))
				#expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("download/bundle/skip").path))
				let paths = await transport.requests.map { $0.url.path }
				#expect(paths.contains("/files/bundle/a") && paths.contains("/files/bundle/skip") && !paths.contains { $0.contains("renamed") || $0.hasSuffix("/c") })
			} catch { try? await session.close(); throw error }
		}
	}
	@Test(arguments: [1, 3]) func corruptSeedIsBannedAndPieceSeedRecovers(_ version: Int) async throws {
		let fixture = try V2Fixture(version: version), transport = try SeedFileTransport(metadata: fixture.metadata, root: fixture.root.appendingPathComponent("source"))
		let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), webSeedTransport: transport)
		do {
			let metadata = try webMetadata(fixture.metadata, urls: ["http://seed.invalid/bad/"], pieces: ["http://seed.invalid/piece"])
			try await addWebTransfer(session, metadata: metadata, root: fixture.root)
			try await session.run(id: "transfer", running: true)
			try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
			let snapshot = try await session.snapshot().transfers[0].state.transfer
			#expect(snapshot?.corruptPieces == 1 && snapshot?.webSeeds.first?.banned == true)
			#expect(snapshot?.corruptBytes == 10003)
			let before = await transport.requests.filter { $0.url.path.hasPrefix("/bad/") }.count
			try await session.pause(id: "transfer")
			let file = metadata.inspection.files.first { !$0.pad && $0.size > 0 }!
			let path = fixture.root.appendingPathComponent("download/" + file.path)
			var changed = try Data(contentsOf: path); changed[0] ^= 1; try changed.write(to: path)
			try await session.recheck(id: "transfer"); try await session.run(id: "transfer", running: true)
			try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
			#expect(await transport.requests.filter { $0.url.path.hasPrefix("/bad/") }.count == before)
			try await session.close()
			#expect(await transport.requests.contains { $0.url.path == "/piece" && $0.url.absoluteString.contains("info_hash=" + HTTPURL.encode(metadata.hashes.v1!)) })
		} catch { try? await session.close(); await fixture.close(); throw error }; await fixture.close()
	}
	@Test func pauseAndStorageChangesDrainHTTPBeforeResuming() async throws {
		try await transferFixture { fixture in
			let transport = try SeedFileTransport(metadata: fixture.metadata, root: fixture.root.appendingPathComponent("source")); await transport.block()
			let metadata = try webMetadata(fixture.metadata, urls: ["http://seed.invalid/files/"])
			let session = TorrentSession(storage: fixture.root.appendingPathComponent("library"), webSeedTransport: transport)
			do {
				try await addWebTransfer(session, metadata: metadata, root: fixture.root)
				try await session.run(id: "transfer", running: true)
				try await eventually { await transport.active == 1 }
				#expect(try await session.snapshot().transfers[0].state.storage.verifiedPieces.isEmpty)
				try await engineDeadline { try await session.pause(id: "transfer") }
				#expect(await transport.active == 0); #expect(await transport.cancelled == 1)
				try await session.changeStorage(id: "transfer", change: .rename([0: "renamed"]))
				try await session.run(id: "transfer", running: true)
				try await eventually { await transport.active == 1 }
				let moved = fixture.root.appendingPathComponent("moved")
				try await engineDeadline { try await session.changeStorage(id: "transfer", change: .move(moved)) }
				#expect(await transport.cancelled == 2)
				await transport.unblock()
				// Retire the blocked request and start a fresh controller with the same original URLs.
				try await session.pause(id: "transfer"); try await session.run(id: "transfer", running: true)
				try await eventually { try await session.snapshot().transfers[0].state.transfer?.complete == true }
				try await session.close()
				#expect(try Data(contentsOf: fixture.root.appendingPathComponent("moved/renamed")) == fixture.bytes.prefix(10003))
			} catch { try? await session.close(); throw error }
		}
	}
	@Test func sharedHTTPAdmissionIsBoundedAndRemovingAWaiterLeavesOtherOwnersAlive() async throws {
		try await transferFixture { fixture in
			let transport = try SeedFileTransport(metadata: fixture.metadata, root: fixture.root.appendingPathComponent("source")); await transport.block()
			let metadata = try webMetadata(fixture.metadata, urls: ["http://seed.invalid/files/"]), resources = try TransferResources()
			var sessions: [TorrentSession] = []
			do {
				for index in 0..<4 {
					let root = fixture.root.appendingPathComponent("owner\(index)")
					let session = TorrentSession(storage: root.appendingPathComponent("library"), resources: resources, webSeedTransport: transport); sessions.append(session)
					try await addWebTransfer(session, metadata: metadata, root: root); try await session.run(id: "transfer", running: true)
				}
				try await eventually { let active = await transport.active, waiting = await resources.web.waitingCount; return active == 3 && waiting == 1 }
				_ = try await sessions[3].remove(id: "transfer")
				#expect(await transport.active == 3); #expect(await resources.web.waitingCount == 0)
				try await sessions[0].pause(id: "transfer")
				#expect(await transport.active == 2); #expect(await transport.maximumActive == 3)
				for session in sessions { try await session.close() }
				#expect(await transport.active == 0)
			} catch { for session in sessions { try? await session.close() }; throw error }
		}
	}
}

}

private func webMetadata(_ metadata: TorrentMetadata, urls: [String], pieces: [String] = []) throws -> TorrentMetadata {
	var fields = metadata.document.root.dictionary!
	fields[Data("url-list".utf8)] = .list(urls.map { .bytes(Data($0.utf8)) })
	fields[Data("httpseeds".utf8)] = .list(pieces.map { .bytes(Data($0.utf8)) })
	return try TorrentMetadata(BencodeValue.dictionary(fields).encoded())
}
private func addWebTransfer(_ session: TorrentSession, metadata: TorrentMetadata, root: URL, selected: [Bool]? = nil) async throws {
	try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
	let source = root.appendingPathComponent("input.torrent"); try metadata.document.original.write(to: source)
	_ = try await session.add(id: "transfer", source: source, destination: root.appendingPathComponent("download"), selected: selected)
}

private actor SeedFileTransport: HTTPTransport {
	let files: [String: Data]
	let payload: Data
	let pieceLength: Int
	var requests: [HTTPRequest] = []
	var active = 0
	var maximumActive = 0
	var cancelled = 0
	var blocked = false
	var skipFails = false
	init(metadata: TorrentMetadata, root: URL) throws {
		var files: [String: Data] = [:], payload = Data()
		for file in metadata.inspection.files {
			let bytes = file.pad ? Data(repeating: 0, count: Int(file.size)) : try Data(contentsOf: root.appendingPathComponent(file.path))
			if !file.pad { files[metadata.remotePaths[file.index]!.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")] = bytes }; payload.append(bytes)
		}
		self.files = files; self.payload = payload; pieceLength = Int(metadata.pieceLength)
	}
	func block() { blocked = true }
	func unblock() { blocked = false }
	func failSkip(_ value: Bool) { skipFails = value }
	func get(_ request: HTTPRequest) async throws -> HTTPResponse {
		requests.append(request); active += 1; maximumActive = max(maximumActive, active); defer { active -= 1 }
		if blocked { do { try await Task.sleep(for: .seconds(60)) } catch { cancelled += 1; throw error } }
		let parts = URLComponents(url: request.url, resolvingAgainstBaseURL: false)!
		if parts.path == "/piece" {
			let fields = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
			guard let index = fields["piece"].flatMap(Int.init), let range = fields["ranges"] else { throw PeerFailure.invalid("HTTP seed query") }
			let bounds = range.split(separator: "-").compactMap { Int($0) }, start = index * pieceLength
			guard bounds.count == 2, start + bounds[1] < payload.count else { throw PeerFailure.invalid("HTTP seed bounds") }
			return HTTPResponse(status: 200, body: payload.subdata(in: (start + bounds[0])..<(start + bounds[1] + 1)))
		}
		let path = parts.path.split(separator: "/").dropFirst().joined(separator: "/")
		if skipFails && path.hasSuffix("/skip") { return HTTPResponse(status: 503, headers: ["Retry-After": "30"]) }
		guard let bytes = files[path], let range = request.headers["Range"] else { throw PeerFailure.invalid("original web seed path") }
		let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
		guard bounds.count == 2, bounds[0] >= 0, bounds[1] < bytes.count else { throw PeerFailure.invalid("file seed bounds") }
		var body = bytes.subdata(in: bounds[0]..<(bounds[1] + 1)); if parts.path.hasPrefix("/bad/") { body[0] ^= 1 }
		return HTTPResponse(status: 206, headers: ["Content-Range": "bytes \(bounds[0])-\(bounds[1])/\(bytes.count)"], body: body)
	}
}
