import Foundation
import ButterTorrentNetworking
import ButterTorrentStorage

extension TCPTransfer {
	func negotiated(_ id: UUID, mode: PeerEncryptionMode) { peers[id]?.encryption = mode }
	func handshaken(_ id: UUID, handshake: PeerHandshake) throws -> PeerFeatures {
		let v2 = metadata.hashes.v2.map { Data($0.prefix(20)) }
		guard !stopping, let peer = peers[id], !peer.closing, handshake.infoHash == metadata.hashes.v1 || handshake.infoHash == v2,
			handshake.peerID != hello.peerID, !bannedIDs.contains(handshake.peerID) else { throw PeerFailure.invalid("handshake identity or duplicate peer") }
		// Follow libtorrent's direction rule: the greater peer ID initiates.
		// Both clients must choose the same connection during simultaneous open.
		for (otherID, other) in peers where otherID != id && other.peerID == handshake.peerID && !other.closing {
			guard peer.outgoing == handshake.peerID.lexicographicallyPrecedes(hello.peerID) else { throw PeerFailure.invalid("duplicate peer") }
			drop(otherID, error: PeerFailure.invalid("duplicate peer"))
		}
		peer.peerID = handshake.peerID
		peer.features.fast = hello.reserved[7] & handshake.reserved[7] & 4 != 0
		peer.features.extended = hello.reserved[5] & handshake.reserved[5] & 16 != 0
		peer.features.dht = hello.reserved[7] & handshake.reserved[7] & 1 != 0
		peer.features.v2 = handshake.infoHash == v2 || (!peer.outgoing && configuration.preferV2 && v2 != nil && handshake.reserved[7] & 16 != 0)
		if !peer.outgoing {
			let hash = peer.features.v2 ? v2! : handshake.infoHash
			try peer.session.handshake(PeerHandshake(infoHash: hash, peerID: hello.peerID, reserved: hello.reserved))
		}
		picker.update(id, bits: try PieceBitfield(count: picker.layout.pieceCount))
		if peer.features.fast && picker.completed.isEmpty { try send(id, .haveNone) }
		else if peer.features.fast && picker.completed.count == picker.layout.pieceCount { try send(id, .haveAll) }
		else { try send(id, .bitfield(PieceBitfield(count: picker.layout.pieceCount, pieces: picker.completed).bytes)) }
		if peer.features.fast {
			peer.allowedIncoming = allowedFast(address: peer.session.stream.remoteEndpoint?.address, infoHash: handshake.infoHash, pieces: picker.layout.pieceCount)
			for piece in peer.allowedIncoming.sorted() { try send(id, .allowedFast(piece)) }
		}
		if peer.features.extended { try sendExtensionHandshake(id) }
		if peer.features.dht { try send(id, .port(Int(configuration.dhtPort))) }
		return peer.features
	}
	func send(_ id: UUID, _ message: PeerMessage) throws {
		guard let peer = peers[id], !peer.closing else { throw PeerFailure.closed }
		try peer.session.send(message); peer.lastSent = clock.now()
	}
	func received(_ id: UUID, message: PeerMessage) async throws {
		guard !stopping, storageError == nil, let peer = peers[id], !peer.closing, peer.peerID != nil else { throw PeerFailure.closed }
		let now = clock.now()
		if now - peer.window >= 1 { peer.window = now; peer.controls = 0 }
		if case .piece = message { } else { peer.controls += 1; guard peer.controls <= 8192 else { throw PeerFailure.limit("control messages per second") } }
		if case .keepAlive = message { return }
		switch message {
		case .extended, .hashRequest, .hashes, .hashReject: break
		case .bitfield, .haveAll, .haveNone:
			guard peer.firstMessage, !peer.availabilitySeen else { throw PeerFailure.invalid("late/repeated availability") }; peer.availabilitySeen = true; peer.firstMessage = false
		default:
			if peer.features.fast && !peer.availabilitySeen { throw PeerFailure.invalid("missing initial Fast availability") }; peer.firstMessage = false
		}
		switch message {
		case .keepAlive: break
		case .bitfield(let bytes): picker.update(id, bits: try PieceBitfield(count: picker.layout.pieceCount, bytes: bytes)); fill(id)
		case .have(let piece): try picker.have(id, piece: piece); fill(id)
		case .haveAll: picker.update(id, bits: try PieceBitfield(count: picker.layout.pieceCount, pieces: Set(0..<picker.layout.pieceCount))); fill(id)
		case .haveNone: picker.update(id, bits: try PieceBitfield(count: picker.layout.pieceCount)); fill(id)
		case .allowedFast(let piece), .suggest(let piece):
			guard (0..<picker.layout.pieceCount).contains(piece) else { throw PeerFailure.invalid("Fast piece index") }
			if case .allowedFast = message { guard peer.allowedOutgoing.count < 256 else { throw PeerFailure.limit("allowed Fast pieces") }; peer.allowedOutgoing.insert(piece); fill(id) }
			else { guard peer.suggestions.count < 64 else { throw PeerFailure.limit("suggested pieces") }; peer.suggestions.insert(piece) }
		case .reject(let block):
			try validate(block)
			guard peer.pending.remove(block) != nil || peer.recent.removeValue(forKey: block) != nil else { throw PeerFailure.invalid("unsolicited rejection") }
			picker.rejected(id, block: block); peer.allowedOutgoing.remove(block.piece); peer.retryAfter = now + min(5, configuration.requestTimeout); fillAll()
		case .choke:
			peer.remoteChoking = true
			if !peer.features.fast && !peer.features.v2 { for block in peer.pending { remember(peer, block: block) }; peer.pending.removeAll(); picker.release(id) }; fillAll()
		case .unchoke: peer.remoteChoking = false; fill(id)
		case .interested: peer.remoteInterested = true; rechoke()
		case .notInterested: peer.remoteInterested = false; rechoke()
		case .request(let block): try validate(block); try requestUpload(id, block: block)
		case .cancel(let block):
			try validate(block)
			if let token = peer.uploads.removeValue(forKey: block) {
				uploadJobs[token]?.1.cancel()
				if peer.session.cancel(token), peer.features.fast || peer.features.v2 { try send(id, .reject(block)) }
			}
		case .extended(let number, let bytes): try await receivedExtension(id, number: number, bytes: bytes)
		case .hashRequest(let request): try await serveHashes(id, request: request)
		case .hashes(let request, let bytes): try await receiveHashes(id, request: request, bytes: bytes)
		case .hashReject(let request):
			guard peer.hashRequests.removeValue(forKey: request) != nil else { throw PeerFailure.invalid("unsolicited hash rejection") }
			if hashOwners[request] == id { hashOwners[request] = nil }; peer.retryAfter = now + configuration.requestTimeout
			peer.hashRequestSize = 2
		case .port(let port):
			guard peer.features.dht, !metadata.inspection.private, port > 0, let remote = peer.session.stream.remoteEndpoint else { throw PeerFailure.invalid("DHT port policy") }
			nodeDiscovery.yield(NetworkEndpoint(address: remote.address, port: UInt16(port)))
		case .piece(let piece, let offset, let bytes):
			let block = PeerBlock(piece: piece, offset: offset, length: bytes.count); try validate(block)
			if peer.pending.remove(block) == nil {
				guard let deadline = peer.recent.removeValue(forKey: block), deadline >= now else { throw PeerFailure.invalid("unsolicited piece block") }
			}
			downloaded = min(Int64.max - Int64(bytes.count), downloaded) + Int64(bytes.count)
			peer.downloaded += Int64(bytes.count)
			try await downloadRate.consume(bytes.count); try Task.checkCancellation()
			try await disk.acquire()
			do { try Task.checkCancellation(); try await receiveBlock(id, block: block, bytes: bytes) }
			catch { await disk.release(); throw error }
			await disk.release(); fillAll()
		}
	}
	func validate(_ block: PeerBlock) throws {
		let length = try picker.layout.length(of: block.piece)
		guard block.offset >= 0, block.offset <= length, (1...16384).contains(block.length), block.length <= length - block.offset else { throw PeerFailure.invalid("piece block range") }
	}
	func remember(_ peer: TransferPeer, block: PeerBlock) {
		if peer.recent.count >= 256, let oldest = peer.recent.min(by: { $0.value < $1.value }) { peer.recent[oldest.key] = nil }
		peer.recent[block] = clock.now() + configuration.requestTimeout * 2
	}
	func receiveBlock(_ id: UUID, block: PeerBlock, bytes: Data) async throws {
		guard !stopping, peers[id]?.closing == false || webSeeds.contains(where: { $0.id == id && !$0.banned }) else { throw PeerFailure.closed }
		var cursor = 0
		for segment in try picker.layout.segments(piece: block.piece, offset: block.offset, count: block.length) {
			if segment.padding, bytes[cursor..<(cursor + segment.count)].contains(where: { $0 != 0 }) { throw PeerFailure.corruptPiece(block.piece) }; cursor += segment.count
		}
		guard let cancellations = picker.begin(id, block: block) else { return }
		for other in cancellations {
			if let peer = peers[other] { peer.pending.remove(block); remember(peer, block: block); try? send(other, .cancel(block)) }
		}
		do { try await storage.write(piece: block.piece, offset: block.offset, data: bytes) }
		catch { picker.abortedWrite(block); diskFailed(error); throw error }
		guard picker.written(block) else { return }
		let valid: Bool
		do { valid = try await storage.verify(piece: block.piece) } catch { _ = picker.verified(block.piece, valid: false); diskFailed(error); throw error }
		let contributors = picker.verified(block.piece, valid: valid)
		if valid {
			for contributor in contributors { peers[contributor]?.score += try picker.layout.length(of: block.piece) / max(1, contributors.count) }
			for (peerID, peer) in peers where peer.peerID != nil && !peer.closing { do { try send(peerID, .have(block.piece)) } catch { drop(peerID, error: error) } }
		} else {
			corruptPieces += 1
			for contributor in contributors {
				if let seed = webSeeds.first(where: { $0.id == contributor }) { await banWebSeed(seed) }
				if let identity = peers[contributor]?.peerID, bannedIDs.count < 1024 { bannedIDs.insert(identity) }
				drop(contributor, error: PeerFailure.corruptPiece(block.piece))
			}
		}
	}
	func fill(_ id: UUID) {
		guard !stopping, storageError == nil, let peer = peers[id], peer.peerID != nil, !peer.closing else { return }
		do {
			let interested = picker.interested(id)
			if interested != peer.interested { peer.interested = interested; try send(id, interested ? .interested : .notInterested) }
			guard interested, clock.now() >= peer.retryAfter else { return }
			try requestHashes(id)
			guard !peer.remoteChoking || !peer.allowedOutgoing.isEmpty else { return }
			for block in picker.allocate(id, limit: min(configuration.pipeline, peer.extensions.queueLimit) - peer.pending.count, now: clock.now(), eligible: hashReady, allowed: peer.remoteChoking ? peer.allowedOutgoing : nil, suggestions: peer.suggestions) { peer.pending.insert(block); try send(id, .request(block)) }
		} catch { drop(id, error: error) }
	}
	func fillAll() { for id in peers.keys { fill(id) } }
	func rechoke() {
		let interested = peers.filter { $0.value.remoteInterested && $0.value.peerID != nil && !$0.value.closing }.sorted {
			$0.value.score == $1.value.score ? $0.key.uuidString < $1.key.uuidString : $0.value.score > $1.value.score
		}
		let regular = max(0, configuration.uploadSlots - 1)
		var selected = Set(interested.prefix(regular).map(\.key))
		let rest = Array(interested.dropFirst(regular))
		if !rest.isEmpty { selected.insert(rest[rotation % rest.count].key) }
		for (id, peer) in peers where peer.peerID != nil && !peer.closing {
			let choke = !selected.contains(id)
			if choke == peer.choking { continue }; peer.choking = choke
			if choke {
				for (block, token) in peer.uploads where !peer.allowedIncoming.contains(block.piece) {
					uploadJobs[token]?.1.cancel()
					if peer.session.cancel(token), peer.features.fast || peer.features.v2 { try? send(id, .reject(block)) }; peer.uploads[block] = nil
				}
			}
			do { try send(id, choke ? .choke : .unchoke) } catch { drop(id, error: error) }
		}
	}
	func tick() {
		guard !stopping, storageError == nil else { return }
		let now = clock.now()
		var timedOut: Set<UUID> = []
		for (id, block) in picker.expired(now: now, timeout: configuration.requestTimeout) {
			if let peer = peers[id] { peer.pending.remove(block); remember(peer, block: block); try? send(id, .cancel(block)); timedOut.insert(id) }
		}
		for id in timedOut {
			if let peer = peers[id] { peer.timeouts += 1; peer.retryAfter = now + configuration.requestTimeout; if peer.timeouts >= 2 { drop(id, error: PeerFailure.invalid("repeated request timeout")) } }
		}
		for (id, peer) in peers {
			if peer.peerID == nil, now - peer.connectedAt >= 10 { drop(id, error: NetworkFailure.timedOut); continue }
			peer.recent = peer.recent.filter { $0.value >= now }
			for (request, time) in peer.hashRequests where now - time >= configuration.requestTimeout {
				peer.hashRequests[request] = nil; if hashOwners[request] == id { hashOwners[request] = nil }; peer.retryAfter = now + configuration.requestTimeout
			}
			if peer.features.extended { do { try sendPEX(id) } catch { drop(id, error: error) } }
			if peer.peerID != nil, !peer.closing, now - peer.lastSent >= 60 { do { try send(id, .keepAlive) } catch { drop(id, error: error) } }
		}
		if now - lastChoke >= 10 { lastChoke = now; rotation &+= 1; rechoke(); for peer in peers.values { peer.score = 0 } }
		fillAll()
	}
}
