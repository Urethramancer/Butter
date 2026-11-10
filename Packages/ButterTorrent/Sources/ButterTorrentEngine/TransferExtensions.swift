import Foundation
import ButterTorrentMetadata
import ButterTorrentNetworking

extension TCPTransfer {
	func sendExtensionHandshake(_ id: UUID) throws {
		var mapping: [String: BencodeValue] = [:]
		if !metadata.inspection.private { mapping["ut_metadata"] = .integer(1) }
		if configuration.enablePEX && !metadata.inspection.private { mapping["ut_pex"] = .integer(2) }
		var fields: [String: BencodeValue] = ["m": extensionDictionary(mapping),
			"v": .bytes(Data("Butter Swift".utf8)), "reqq": .integer(32), "p": .integer(Int64(configuration.listenPort))]
		if !metadata.inspection.private { fields["metadata_size"] = .integer(Int64(metadata.originalInfo.count)) }
		try send(id, .extended(0, extensionDictionary(fields).encoded()))
	}
	func receivedExtension(_ id: UUID, number: Int, bytes: Data) async throws {
		guard let peer = peers[id], peer.features.extended else { throw PeerFailure.invalid("extension negotiation") }
		switch number {
		case 0:
			try peer.extensions.apply(bytes); peer.advertisedPort = peer.extensions.port
		case 1:
			guard !metadata.inspection.private else { throw PeerFailure.invalid("private metadata exchange") }
			let parsed = try BencodeDocument.prefix(bytes, limits: .init(bytes: 32_768, depth: 8, values: 64))
			guard let type = parsed.value["msg_type"]?.integer else { throw PeerFailure.invalid("metadata request type") }
			if type != 0 { return }
			guard let piece = parsed.value["piece"]?.integer, piece >= 0, piece < 2048 else { throw PeerFailure.invalid("metadata request piece") }
			guard bytes.count == parsed.length, let remoteID = peer.extensions.ids["ut_metadata"] else { throw PeerFailure.invalid("metadata request suffix or mapping") }
			let now = clock.now()
			if now - peer.metadataWindow >= 60 { peer.metadataWindow = now; peer.metadataRequests = 0 }
			peer.metadataRequests += 1
			let chunks = (metadata.originalInfo.count + 16383) / 16384
			var fields: [String: BencodeValue] = ["msg_type": .integer(2), "piece": .integer(piece)]
			var payload = Data()
			if piece < chunks && peer.metadataRequests <= max(4, chunks * 3) {
				fields["msg_type"] = .integer(1); fields["total_size"] = .integer(Int64(metadata.originalInfo.count))
				let start = Int(piece) * 16384; payload = metadata.originalInfo.subdata(in: start..<min(start + 16384, metadata.originalInfo.count))
			}
			try send(id, .extended(remoteID, try extensionDictionary(fields).encoded() + payload))
		case 2:
			guard !metadata.inspection.private, configuration.enablePEX else { throw PeerFailure.invalid("private/disabled peer exchange") }
			guard clock.now() >= peer.nextIncomingPEX else { throw PeerFailure.limit("PEX update rate") }; peer.nextIncomingPEX = clock.now() + 60
			let message = try PeerExchange(bytes)
			for endpoint in message.dropped { peer.pexReceived.remove(endpoint) }
			for added in message.added where !peer.pexReceived.contains(added.endpoint) {
				guard peer.pexReceived.count < 256 else { throw PeerFailure.limit("remembered PEX contacts") }
				peer.pexReceived.insert(added.endpoint); discovery.yield(added)
			}
		default: throw PeerFailure.invalid("unknown local extension ID")
		}
	}
	func sendPEX(_ id: UUID) throws {
		guard !metadata.inspection.private, configuration.enablePEX, let peer = peers[id], !peer.closing,
			let number = peer.extensions.ids["ut_pex"], clock.now() >= peer.nextPEX else { return }
		var current: Set<NetworkEndpoint> = []
		var flags: [NetworkEndpoint: UInt8] = [:]
		for (otherID, other) in peers where otherID != id && !other.closing && other.peerID != nil {
			guard let endpoint = other.session.stream.remoteEndpoint else { continue }
			let advertised: NetworkEndpoint
			if other.outgoing { advertised = endpoint }
			else if let port = other.advertisedPort { advertised = NetworkEndpoint(address: endpoint.address, port: port) }
			else { continue }
			current.insert(advertised)
			flags[advertised] = (other.outgoing ? 16 : 0) | (other.session.stream.kind == .utp ? 4 : 0) | (other.encryption == .plaintext ? 0 : 1)
		}
		let added = Array(current.subtracting(peer.pexSent).sorted { $0.description < $1.description }.prefix(50))
		let dropped = Array(peer.pexSent.subtracting(current).sorted { $0.description < $1.description }.prefix(50))
		guard !added.isEmpty || !dropped.isEmpty else { return }
		try send(id, .extended(number, PeerExchange.encode(added: added.map { ExchangedPeer(endpoint: $0, flags: flags[$0] ?? 0) }, dropped: dropped)))
		peer.pexSent.formUnion(added); peer.pexSent.subtract(dropped); peer.nextPEX = clock.now() + 60
	}
	func requestHashes(_ id: UUID) throws {
		guard let peer = peers[id], peer.features.v2, peer.hashRequests.count < 4, hashOwners.count < 16 else { return }
		for piece in picker.wanted.subtracting(hashReady).sorted() where picker.has(id, piece: piece) {
			guard let request = storage.merkleIndex.request(for: piece, maximum: peer.hashRequestSize), hashOwners[request] == nil else { continue }
			peer.hashRequests[request] = clock.now(); hashOwners[request] = id; try send(id, .hashRequest(request))
			if peer.hashRequests.count >= 4 || hashOwners.count >= 16 { break }
		}
	}
	func serveHashes(_ id: UUID, request: MerkleHashRequest) async throws {
		guard let peer = peers[id], peer.features.v2 else { throw PeerFailure.invalid("v2 hash request") }
		guard let file = storage.merkleIndex.files[request.root], (try? file.validate(request)) != nil else { try send(id, .hashReject(request)); return }
		try await disk.acquire()
		do {
			let bytes = try await storage.hashResponse(request); try Task.checkCancellation()
			if !peer.closing { try send(id, bytes.map { .hashes(request, $0) } ?? .hashReject(request)) }
		} catch { await disk.release(); if !(error is MetadataError) { diskFailed(error) }; throw error }
		await disk.release()
	}
	func receiveHashes(_ id: UUID, request: MerkleHashRequest, bytes: Data) async throws {
		guard let peer = peers[id], peer.hashRequests[request] != nil else { throw PeerFailure.invalid("unsolicited hash response") }
		peer.hashRequests[request] = .infinity
		try await disk.acquire()
		do {
			try await storage.installHashes(request, hashes: bytes)
			try await refreshAuthenticatedPieces()
		} catch {
			await disk.release()
			if !(error is MetadataError) { diskFailed(error) }; throw error
		}
		await disk.release(); peer.hashRequests[request] = nil; if hashOwners[request] == id { hashOwners[request] = nil }; fillAll()
	}
}
