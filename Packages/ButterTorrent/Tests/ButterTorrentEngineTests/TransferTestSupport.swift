import Foundation
import Testing
import ButterTorrentMetadata
import ButterTorrentNetworking
import ButterTorrentStorage
@testable import ButterTorrentEngine

func plainTransferConfiguration() -> TCPTransferConfiguration {
	var configuration = TCPTransferConfiguration(); configuration.encryption.outgoing = .disabled; return configuration
}

func eventually(_ operation: @escaping @Sendable () async throws -> Bool) async throws {
	let deadline = ProcessInfo.processInfo.systemUptime + 6
	while ProcessInfo.processInfo.systemUptime < deadline { if try await operation() { return }; try await Task.sleep(for: .milliseconds(5)) }
	throw PeerFailure.invalid("test deadline")
}

func engineDeadline<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
	try await withThrowingTaskGroup(of: T.self) { group in
		group.addTask(operation: operation)
		group.addTask { try await Task.sleep(for: .seconds(6)); throw PeerFailure.invalid("test deadline") }
		defer { group.cancelAll() }; return try await group.next()!
	}
}

final class TransferFixture {
	let root: URL
	let metadata: TorrentMetadata
	let bytes: Data
	let lengths: [Int]
	let names = ["a", "skip", "c", "empty"]
	var engines: [TCPTransfer] = []
	var stores: [TorrentStorage] = []
	var listeners: [TCPListener] = []
	init(lengths: [Int] = [10003, 50019, 30000, 0], pieceLength: Int = 32768) throws {
		precondition(lengths.count == names.count && lengths.allSatisfy { $0 >= 0 } && pieceLength > 0)
		self.lengths = lengths
		root = FileManager.default.temporaryDirectory.appendingPathComponent("butter-peer-" + UUID().uuidString).resolvingSymlinksInPath()
		try FileManager.default.createDirectory(at: root.appendingPathComponent("source/bundle"), withIntermediateDirectories: true)
		let total: Int = lengths.reduce(0, +)
		var payload = Data(count: total)
		for index in 0..<total { payload[index] = UInt8((index * 17 + index / 13) % 251) }; bytes = payload
		var offset = 0, files: [BencodeValue] = [], hashes = Data()
		for (name, size) in zip(names, lengths) {
			try bytes.subdata(in: offset..<(offset + size)).write(to: root.appendingPathComponent("source/bundle/" + name)); offset += size
			files.append(.dictionary([Data("path".utf8): .list([.bytes(Data(name.utf8))]), Data("length".utf8): .integer(Int64(size))]))
		}
		for start in stride(from: 0, to: bytes.count, by: pieceLength) { hashes.append(TorrentHasher.hash(bytes.subdata(in: start..<min(start + pieceLength, bytes.count))).sha1) }
		let info: [Data: BencodeValue] = [Data("name".utf8): .bytes(Data("bundle".utf8)), Data("files".utf8): .list(files), Data("piece length".utf8): .integer(Int64(pieceLength)), Data("pieces".utf8): .bytes(hashes)]
		metadata = try TorrentMetadata(BencodeValue.dictionary([Data("info".utf8): .dictionary(info)]).encoded())
	}
	func transfer(_ name: String, seed: Bool = false, selected: [Bool]? = nil, configuration: TCPTransferConfiguration = plainTransferConfiguration(), clock: any TransportClock = ContinuousTransportClock(), peerID: Data? = nil, resources: TransferResources = .shared, readPolicy: StorageReadPolicy = .strict, event: @escaping @Sendable (StorageEvent) -> Void = { _ in }) async throws -> TCPTransfer {
		let storage = try await TorrentStorage.open(metadata: metadata, destination: root.appendingPathComponent(name), stateDirectory: root.appendingPathComponent(name + "-state"), selected: selected, readPolicy: readPolicy, event: event)
		stores.append(storage)
		if seed { try await storage.importFiles(from: root.appendingPathComponent("source")); for piece in 0..<storage.layout.pieceCount { #expect(try await storage.verify(piece: piece)) } }
		let engine = try await TCPTransfer.open(metadata: metadata, storage: storage, configuration: configuration, peerID: peerID, resources: resources, clock: clock)
		engines.append(engine); return engine
	}
	func listen() async throws -> TCPListener {
		let listener = try await TCPListener.listen(address: IPAddress("127.0.0.1")); listeners.append(listener); return listener
	}
	func join(_ download: TCPTransfer, _ seed: TCPTransfer) async throws {
		let listener = try await listen()
		let incoming = Task { try await seed.attach(listener.accept(timeout: 3)) }
		do { _ = try await download.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)); _ = try await incoming.value }
		catch { incoming.cancel(); _ = try? await incoming.value; throw error }
	}
	func scripted(_ engine: TCPTransfer, identity: UInt8 = 42, hash: Data? = nil, reserved: Data = Data(repeating: 0, count: 8), encryption: PeerEncryptionConfiguration? = nil) async throws -> WirePeer {
		let listener = try await listen(), connecting = Task { try await engine.connect(to: NetworkEndpoint("127.0.0.1", port: listener.port)) }
		let stream = try await listener.accept(timeout: 3)
		let peer: WirePeer
		if let encryption { peer = WirePeer(channel: try await PeerStream.accept(stream, hashes: [hash ?? metadata.hashes.v1!], configuration: encryption)) }
		else { peer = WirePeer(stream: stream) }
		_ = try await connecting.value
		try await peer.hello(hash: hash ?? metadata.hashes.v1!, identity: identity, reserved: reserved)
		return peer
	}
	func clean() async {
		for engine in engines { try? await engine.shutdown() }
		for listener in listeners { try? await listener.shutdown() }
		for storage in stores { try? await storage.shutdown() }
		try? FileManager.default.removeItem(at: root)
	}
}

func transferFixture(_ body: (TransferFixture) async throws -> Void) async throws {
	try await transferFixture(TransferFixture(), body)
}

func transferFixture(_ fixture: TransferFixture, _ body: (TransferFixture) async throws -> Void) async throws {
	do { try await body(fixture) } catch { await fixture.clean(); throw error }; await fixture.clean()
}

final class WirePeer {
	let stream: any PeerByteStream
	private let channel: PeerStream?
	var decoder = PeerWireDecoder()
	init(stream: any PeerByteStream) { self.stream = stream; channel = nil }
	init(channel: PeerStream) { self.channel = channel; stream = channel.raw }
	private func write(_ data: Data) async throws { if let channel { try await channel.write(data) } else { try await stream.write(data) } }
	private func read() async throws -> Data { if let channel { return try await channel.read(timeout: 3) }; return try await stream.read(timeout: 3) }
	func hello(hash: Data, identity: UInt8, fragmented: Bool = true, reserved: Data = Data(repeating: 0, count: 8), v2: Bool = false) async throws {
		let hello = try PeerHandshake(infoHash: hash, peerID: Data(repeating: identity, count: 20), reserved: reserved)
		if fragmented { for byte in hello.encoded { try await write(Data([byte])) } } else { try await write(hello.encoded) }
		while true {
			if let remote = try decoder.handshake() {
				var features = PeerFeatures(); features.fast = remote.reserved[7] & reserved[7] & 4 != 0; features.extended = remote.reserved[5] & reserved[5] & 16 != 0; features.v2 = v2
				features.dht = remote.reserved[7] & reserved[7] & 1 != 0
				decoder.negotiate(features); return
			}
			let bytes = try await read()
			guard !bytes.isEmpty else { throw PeerFailure.closed }; try decoder.feed(bytes)
		}
	}
	func send(_ message: PeerMessage) async throws { try await write(message.encoded()) }
	func next() async throws -> PeerMessage {
		while true {
			if let message = try decoder.next() { return message }
			let bytes = try await read()
			guard !bytes.isEmpty else { throw PeerFailure.closed }; try decoder.feed(bytes)
		}
	}
	func requests(_ count: Int) async throws -> [PeerBlock] {
		var requests: [PeerBlock] = []
		while requests.count < count { if case .request(let block) = try await next() { requests.append(block) } }; return requests
	}
	func seed(pieceCount: Int) async throws {
		try await send(.bitfield(PieceBitfield(count: pieceCount, pieces: Set(0..<pieceCount)).bytes)); try await send(.unchoke)
	}
	func reply(_ block: PeerBlock, bytes: Data, corrupt: Bool = false, pieceLength: Int = 32768) async throws {
		let start = block.piece * pieceLength + block.offset
		var data = bytes.subdata(in: start..<(start + block.length)); if corrupt { data[0] ^= 255 }
		try await send(.piece(block.piece, block.offset, data))
	}
	deinit { stream.close() }
}
