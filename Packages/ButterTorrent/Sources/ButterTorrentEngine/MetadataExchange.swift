import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking

/// MetadataExchange resolves magnets through explicit peers without authorising discovery.
public actor MetadataExchange {
	private let clock: any TransportClock
	private let budget: TCPPeerBudget
	private let encryption: PeerEncryptionConfiguration
	private var busy = false
	public init(clock: any TransportClock = ContinuousTransportClock(), budget: TCPPeerBudget = TCPPeerBudget(limit: 4), encryption: PeerEncryptionConfiguration = .init()) { self.clock = clock; self.budget = budget; self.encryption = encryption }
	public func fetch(_ magnet: Magnet, peers: [NetworkEndpoint], timeout: TimeInterval = 60) async throws -> TorrentMetadata {
		guard !busy else { throw PeerFailure.limit("simultaneous metadata resolutions") }
		guard (1...32).contains(peers.count), timeout.isFinite, (0.1...120).contains(timeout) else { throw PeerFailure.invalid("metadata resolution limits") }
		busy = true; defer { busy = false }
		var seen: Set<NetworkEndpoint> = []
		let peers = peers.filter { seen.insert($0).inserted }, clock = clock, budget = budget, encryption = encryption, deadline = clock.now() + timeout
		return try await withThrowingTaskGroup(of: Result<TorrentMetadata, Error>.self) { group in
			func add(_ endpoint: NetworkEndpoint) {
				group.addTask { do { return .success(try await Self.fetchPeer(magnet, endpoint: endpoint, deadline: deadline, clock: clock, budget: budget, encryption: encryption)) } catch { return .failure(error) } }
			}
			var next = 0, failure: Error = PeerFailure.invalid("no metadata provider")
			while next < min(4, peers.count) { add(peers[next]); next += 1 }
			while let result = try await group.next() {
				try Task.checkCancellation()
				switch result {
				case .success(let metadata): group.cancelAll(); return metadata
				case .failure(let error): failure = error; if next < peers.count { add(peers[next]); next += 1 }
				}
			}
			throw failure
		}
	}
	private static func fetchPeer(_ magnet: Magnet, endpoint: NetworkEndpoint, deadline: TimeInterval, clock: any TransportClock, budget: TCPPeerBudget, encryption: PeerEncryptionConfiguration) async throws -> TorrentMetadata {
		func remaining() throws -> TimeInterval { let seconds = deadline - clock.now(); guard seconds > 0 else { throw NetworkFailure.timedOut }; return min(10, seconds) }
		var reserved = Data(repeating: 0, count: 8); reserved[5] = 16
		let wireHash = magnet.hashes.v2.map { Data($0.prefix(20)) } ?? magnet.hashes.v1!
		let stream = try await PeerStream.connect(to: endpoint, hash: wireHash, configuration: encryption, timeout: remaining(), clock: clock, budget: budget)
		defer { stream.close() }
		let hello = try PeerHandshake(infoHash: wireHash, peerID: Data("-BTMETA-".utf8) + Data((0..<12).map { _ in UInt8.random(in: 0...255) }), reserved: reserved)
		try await stream.write(hello.encoded, timeout: remaining())
		var decoder = PeerWireDecoder(), handshaken = false, extensions = ExtensionHandshake(), size: Int?, chunks: [Int: Data] = [:], pending: Set<Int> = [], requested = 0
		var messages = 0
		while true {
			try Task.checkCancellation(); _ = try remaining()
			let bytes = try await stream.read(timeout: remaining())
			guard !bytes.isEmpty else { throw PeerFailure.invalid("metadata peer disconnected") }; try decoder.feed(bytes)
			if !handshaken {
				guard let remote = try decoder.handshake() else { continue }
				guard remote.infoHash == wireHash, remote.reserved[5] & 16 != 0 else { throw PeerFailure.invalid("metadata handshake identity/capability") }
				var features = PeerFeatures(); features.extended = true; features.v2 = magnet.hashes.v2.map { Data($0.prefix(20)) } == wireHash; decoder.negotiate(features)
				let handshake = extensionDictionary(["m": extensionDictionary(["ut_metadata": .integer(1)]), "v": .bytes(Data("Butter metadata".utf8)), "reqq": .integer(1)])
				try await stream.write(PeerMessage.extended(0, handshake.encoded()).encoded(), timeout: remaining()); handshaken = true
			}
			while let message = try decoder.next() {
				messages += 1; guard messages <= 16_384 else { throw PeerFailure.limit("metadata peer messages") }
				switch message {
				case .extended(0, let data):
					try extensions.apply(data)
					if let old = size, let new = extensions.metadataSize, old != new { throw PeerFailure.invalid("metadata size changed") }
					size = extensions.metadataSize ?? size
				case .extended(1, let data):
					let parsed = try BencodeDocument.prefix(data, limits: .init(bytes: 32_768, depth: 8, values: 64))
					guard let type = parsed.value["msg_type"]?.integer else { throw PeerFailure.invalid("metadata message type") }
					if ![0, 1, 2].contains(type) { continue }
					guard let number = parsed.value["piece"]?.integer, (0..<2048).contains(number) else { throw PeerFailure.invalid("metadata piece") }
					let piece = Int(number)
					if type == 0 {
						if let id = extensions.ids["ut_metadata"] { try await stream.write(PeerMessage.extended(id, extensionDictionary(["msg_type": .integer(2), "piece": .integer(number)]).encoded()).encoded(), timeout: remaining()) }
						continue
					}
					guard pending.remove(piece) != nil else { throw PeerFailure.invalid("unsolicited metadata piece") }
					if type == 2 { throw PeerFailure.invalid("metadata request rejected") }
					guard let size, parsed.value["total_size"]?.integer == Int64(size), piece * 16384 < size,
						data.count - parsed.length == min(16384, size - piece * 16384) else { throw PeerFailure.invalid("metadata piece size") }
					chunks[piece] = Data(data.dropFirst(parsed.length))
				case .hashRequest(let request): try await stream.write(PeerMessage.hashReject(request).encoded(), timeout: remaining())
				case .extended: throw PeerFailure.invalid("unadvertised metadata extension")
				default: break
				}
				if let size, let id = extensions.ids["ut_metadata"] {
					let total = (size + 16383) / 16384
					while pending.count < 4 && requested < total {
						pending.insert(requested)
						let request = extensionDictionary(["msg_type": .integer(0), "piece": .integer(Int64(requested))])
						try await stream.write(PeerMessage.extended(id, request.encoded()).encoded(), timeout: remaining()); requested += 1
					}
					if chunks.count == total {
						var info = Data(); for piece in 0..<total { info.append(chunks[piece]!) }
						return try TorrentMetadata(infoBytes: info, expected: magnet.hashes, trackers: magnet.trackers)
					}
				}
			}
		}
	}
}
