import Foundation
import ButterTorrentNetworking
import ButterTorrentStorage

extension TCPTransfer {
	func handshaken(_ id: UUID, handshake: PeerHandshake) throws {
		guard !stopping, let peer = peers[id], !peer.closing, handshake.infoHash == hello.infoHash,
			handshake.peerID != hello.peerID, !bannedIDs.contains(handshake.peerID),
			!peers.contains(where: { $0.key != id && $0.value.peerID == handshake.peerID && !$0.value.closing }) else { throw PeerFailure.invalid("handshake identity or duplicate peer") }
		peer.peerID = handshake.peerID
		picker.update(id, bits: try PieceBitfield(count: picker.layout.pieceCount))
		try send(id, .bitfield(PieceBitfield(count: picker.layout.pieceCount, pieces: picker.completed).bytes))
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
		if case .bitfield = message { guard peer.firstMessage else { throw PeerFailure.invalid("late/repeated bitfield") } }
		peer.firstMessage = false
		switch message {
		case .keepAlive: break
		case .bitfield(let bytes): picker.update(id, bits: try PieceBitfield(count: picker.layout.pieceCount, bytes: bytes)); fill(id)
		case .have(let piece): try picker.have(id, piece: piece); fill(id)
		case .choke:
			peer.remoteChoking = true
			for block in peer.pending { remember(peer, block: block) }; peer.pending.removeAll(); picker.release(id); fillAll()
		case .unchoke: peer.remoteChoking = false; fill(id)
		case .interested: peer.remoteInterested = true; rechoke()
		case .notInterested: peer.remoteInterested = false; rechoke()
		case .request(let block): try validate(block); try requestUpload(id, block: block)
		case .cancel(let block):
			try validate(block)
			if let token = peer.uploads.removeValue(forKey: block) { uploadJobs[token]?.1.cancel(); peer.session.cancel(token) }
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
		guard !stopping, peers[id]?.closing == false else { throw PeerFailure.closed }
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
			guard interested, !peer.remoteChoking, clock.now() >= peer.retryAfter else { return }
			for block in picker.allocate(id, limit: configuration.pipeline - peer.pending.count, now: clock.now()) { peer.pending.insert(block); try send(id, .request(block)) }
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
				for token in peer.uploads.values { uploadJobs[token]?.1.cancel(); peer.session.cancel(token) }; peer.uploads.removeAll()
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
			if peer.peerID != nil, !peer.closing, now - peer.lastSent >= 60 { do { try send(id, .keepAlive) } catch { drop(id, error: error) } }
		}
		if now - lastChoke >= 10 { lastChoke = now; rotation &+= 1; rechoke(); for peer in peers.values { peer.score = 0 } }
		fillAll()
	}
}
