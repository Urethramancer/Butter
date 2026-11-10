import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage
@testable import ButterTorrentEngine

final class V2Fixture {
	let root: URL
	let metadata: TorrentMetadata
	var engines: [TCPTransfer] = []
	var stores: [TorrentStorage] = []
	var listeners: [TCPListener] = []
	init(version: Int, isPrivate: Bool = false) throws {
		root = FileManager.default.temporaryDirectory.appendingPathComponent("butter-v2-" + UUID().uuidString).resolvingSymlinksInPath()
		let source = root.appendingPathComponent("source/Bundle")
		try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
		try Data(repeating: 7, count: 10003).write(to: source.appendingPathComponent("a"))
		try Data(repeating: 17, count: 200003).write(to: source.appendingPathComponent("b"))
		try Data().write(to: source.appendingPathComponent("empty"))
		let base = try TorrentMetadata(TorrentCreator.create(source: source, trackers: isPrivate ? ["http://127.0.0.1/announce"] : [], isPrivate: isPrivate, pieceLength: 65536))
		var fields = base.document.root.dictionary!, info = base.document.root["info"]!.dictionary!
		if version == 1 { for key in ["meta version", "file tree"] { info[Data(key.utf8)] = nil }; fields[Data("piece layers".utf8)] = nil }
		if version == 2 { for key in ["pieces", "files", "length"] { info[Data(key.utf8)] = nil } }
		fields[Data("info".utf8)] = .dictionary(info); metadata = try TorrentMetadata(BencodeValue.dictionary(fields).encoded())
	}
	func engine(_ name: String, seed: Bool, sparse: Bool = false, preferV2: Bool = true, encryption: PeerEncryptionConfiguration = .init(outgoing: .disabled)) async throws -> TCPTransfer {
		let metadata = sparse ? try TorrentMetadata(infoBytes: metadata.originalInfo, expected: metadata.hashes) : metadata
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent(name), stateDirectory: root.appendingPathComponent(name + "-state")); stores.append(storage)
		if seed { try await storage.importFiles(from: root.appendingPathComponent("source")); for piece in 0..<storage.layout.pieceCount { #expect(try await storage.verify(piece: piece)) } }
		var configuration = TCPTransferConfiguration(); configuration.preferV2 = preferV2; configuration.encryption = encryption
		let engine = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: configuration); engines.append(engine); return engine
	}
	func provider(_ engine: TCPTransfer, count: Int = 1) async throws -> (NetworkEndpoint, Task<Void, Error>) {
		let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1")); listeners.append(listener)
		// MetadataExchange permits fifteen seconds before opening the payload stream.
		let task = Task { for _ in 0..<count { _ = try await engine.attach(listener.accept(timeout: 20)) } }
		return (try NetworkEndpoint("127.0.0.1", port: listener.port), task)
	}
	func close() async {
		for engine in engines { try? await engine.shutdown() }; for listener in listeners { try? await listener.shutdown() }; for storage in stores { try? await storage.shutdown() }
		try? FileManager.default.removeItem(at: root)
	}
}

@Suite struct ProtocolV2Tests {
	@Test func poisonedHashProofClosesPeerAndGoodProviderRecovers() async throws {
		let fixture = try V2Fixture(version: 2)
		do {
			let down = try await fixture.engine("download", seed: false, sparse: true), (endpoint, accepting) = try await fixture.provider(down)
			let wire = WirePeer(stream: try await TCPStream.connect(to: endpoint))
			try await wire.hello(hash: Data(fixture.metadata.hashes.v2!.prefix(20)), identity: 77, v2: true); try await accepting.value
			let catalog = try MerkleCatalog(metadata: fixture.metadata)
			let count = (catalog.index.pieces.keys.max() ?? -1) + 1
			try await wire.send(.bitfield(PieceBitfield(count: count, pieces: Set(0..<count)).bytes))
			var poisoned = false
			while !poisoned {
				if case .hashRequest(let request) = try await wire.next() {
					var response = try #require(try catalog.response(request)); response[0] ^= 1
					try await wire.send(.hashes(request, response)); poisoned = true
				}
			}
			try await eventually { await down.snapshot().peers.isEmpty }
			#expect(await down.snapshot().storageError == nil)
			#expect(await down.snapshot().verifiedPieces.isEmpty)
			let seed = try await fixture.engine("seed", seed: true), (good, serving) = try await fixture.provider(seed)
			_ = try await down.connect(to: good); try await serving.value
			try await eventually { await down.snapshot().complete }
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test(arguments: [1, 2, 3]) func metadataAndSparseHashTransfers(_ version: Int) async throws {
		let fixture = try V2Fixture(version: version)
		do {
			let seed = try await fixture.engine("seed", seed: true), (endpoint, serving) = try await fixture.provider(seed, count: 2)
			let exchange = MetadataExchange(encryption: .disabled), magnet = Magnet(hashes: fixture.metadata.hashes)
			let received = try await exchange.fetch(magnet, peers: [endpoint], timeout: 5)
			#expect(received.originalInfo == fixture.metadata.originalInfo && received.pieceLayers.isEmpty)
			let down = try await fixture.engine("download", seed: false, sparse: true)
			_ = try await down.connect(to: endpoint); try await serving.value
			try await eventually { await down.snapshot().complete }
			#expect(await down.snapshot().peers.contains { $0.v2 == (version != 1) && $0.fast })
			#expect(try Data(contentsOf: fixture.root.appendingPathComponent("download/Bundle/b")) == Data(repeating: 17, count: 200003))
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test(arguments: [false, true]) func hybridUsesLegacyIdentityWhileVerifyingBothHashFormats(_ sparse: Bool) async throws {
		let fixture = try V2Fixture(version: 3)
		do {
			let seed = try await fixture.engine("seed", seed: true, preferV2: false), down = try await fixture.engine("download", seed: false, sparse: sparse, preferV2: false)
			let (endpoint, serving) = try await fixture.provider(seed)
			_ = try await down.connect(to: endpoint); try await serving.value
			try await eventually { await down.snapshot().complete }
			#expect(await down.snapshot().peers.allSatisfy { !$0.v2 })
			#expect(try TorrentMetadata(await fixture.stores[1].exportMetadata()).pieceLayers == fixture.metadata.pieceLayers)
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func stagedLegacyPieceWaitsForAuthenticationAndCanUseAV2PeerProof() async throws {
		let fixture = try V2Fixture(version: 3)
		do {
			let down = try await fixture.engine("download", seed: false, sparse: true)
			let (endpoint, accepting) = try await fixture.provider(down)
			let wire = WirePeer(stream: try await TCPStream.connect(to: endpoint)); defer { wire.stream.close() }
			try await wire.hello(hash: try #require(fixture.metadata.hashes.v1), identity: 77); try await accepting.value
			let storage = fixture.stores[0]
			try await wire.send(.bitfield(PieceBitfield(count: storage.layout.pieceCount, pieces: [1]).bytes))
			try await wire.send(.unchoke)
			for request in try await wire.requests(4) {
				try #require(request.piece == 1)
				try await wire.send(.piece(1, request.offset, Data(repeating: 17, count: request.length)))
			}
			try await eventually { await down.picker.staged.contains(1) }
			#expect(await down.snapshot().verifiedPieces.isEmpty)
			#expect(try await storage.snapshot().verifiedPieces.isEmpty)
			wire.stream.close()
			let seed = try await fixture.engine("seed", seed: true), (good, serving) = try await fixture.provider(seed)
			_ = try await down.connect(to: good); try await serving.value
			try await eventually { await down.snapshot().complete }
			#expect(try TorrentMetadata(await storage.exportMetadata()).pieceLayers == fixture.metadata.pieceLayers)
		} catch { await fixture.close(); throw error }; await fixture.close()
	}
	@Test func fastCancellationRepliesOnceWithoutWaitingForPayloadThrottle() async throws {
		try await transferFixture { fixture in
			var config = plainTransferConfiguration(); config.uploadLimit = 1024
			let seed = try await fixture.transfer("seed", seed: true, configuration: config)
			var flags = Data(repeating: 0, count: 8); flags[7] = 4
			let peer = try await fixture.scripted(seed, reserved: flags)
			try await peer.send(.haveNone); try await peer.send(.interested)
			let request = PeerBlock(piece: 0, offset: 0, length: 16384)
			try await peer.send(.request(request)); try await peer.send(.cancel(request))
			var rejected = false
			while !rejected {
				let message = try await peer.next()
				if case .reject(let block) = message { #expect(block == request); rejected = true }
				if case .piece = message { Issue.record("Cancelled throttled payload was sent") }
			}
			#expect(await seed.snapshot().uploaded == 0)
		}
	}
}
