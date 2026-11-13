import Foundation
import ButterTorrentStorage
import ButterTorrentNetworking

struct IncomingPieceBlock: Sendable {
	let piece: Int
	let offset: Int
	let bytes: Data
	var block: PeerBlock { PeerBlock(piece: piece, offset: offset, length: bytes.count) }
}

extension TCPTransfer {
	func prefillBeforeVerification(_ id: UUID) {
		guard !Task.isCancelled, configuration.downloadLimit == 0, wantedHashesReady,
			peers[id]?.session.stream.kind == .tcp else { return }
		fill(id)
	}
	func acceptPayload(_ peer: TransferPeer, block: PeerBlock, now: TimeInterval) throws {
		try validate(block)
		if peer.pending.remove(block) == nil {
			guard let deadline = peer.recent.removeValue(forKey: block), deadline >= now else { throw PeerFailure.invalid("unsolicited piece block") }
		}
		let bytes = Int64(block.length)
		downloaded = min(Int64.max - bytes, downloaded) + bytes; peer.downloaded += bytes
	}
	func abortBatch(_ blocks: [IncomingPieceBlock]) {
		for item in blocks {
			picker.abortedWrite(item.block)
			let bytes = Int64(item.bytes.count)
			if let current = activePayloadBytes[item.piece] {
				let remaining = max(0, current - bytes)
				activePayloadBytes[item.piece] = remaining == 0 ? nil : remaining
			}
			recordUnusablePayload(bytes)
		}
		discardUnretainedPayload()
	}
	func receivedBlocks(_ id: UUID, blocks: [IncomingPieceBlock]) async throws {
		guard (1...16).contains(blocks.count) else { throw PeerFailure.limit("incoming write batch blocks") }
		var size = 0
		for item in blocks {
			guard item.bytes.count <= 262144 - size else { throw PeerFailure.limit("incoming write batch bytes") }; size += item.bytes.count
		}
		if blocks.count == 1 {
			let item = blocks[0]; try await received(id, message: .piece(item.piece, item.offset, item.bytes)); return
		}
		if !(await downloadRate.consumeUnrestrictedBatch()) {
			for item in blocks { try await received(id, message: .piece(item.piece, item.offset, item.bytes)) }; return
		}
		var payload: Int64 = 0
		do {
			for item in blocks {
				let (peer, now) = try prepareMessage(id, message: .piece(item.piece, item.offset, item.bytes))
				try acceptPayload(peer, block: item.block, now: now); payload += Int64(item.bytes.count)
			}
		} catch { recordUnusablePayload(payload); throw error }
		do { try Task.checkCancellation(); try await disk.acquire() }
		catch { recordUnusablePayload(payload); throw error }
		var staged: [IncomingPieceBlock] = [], submitted: Int64 = 0
		do {
			for item in blocks {
				submitted += Int64(item.bytes.count)
				if try stageBlock(id, block: item.block, bytes: item.bytes) { staged.append(item) }
			}
		} catch {
			abortBatch(staged); recordUnusablePayload(payload - submitted); await disk.release(); throw error
		}
		do {
			if !staged.isEmpty { try await storage.writeBatch(staged.map { StorageWrite(piece: $0.piece, offset: $0.offset, data: $0.bytes) }) }
		} catch { abortBatch(staged); diskFailed(error); await disk.release(); throw error }
		let ready = staged.compactMap { picker.written($0.block) ? $0.piece : nil }
		if !ready.isEmpty { prefillBeforeVerification(id) }
		var pending = ready[...]
		do { while let piece = pending.popFirst() { try await verifyReceivedPiece(piece) } }
		catch {
			// The attempted piece owns its cleanup. Later pieces were marked ready
			// together, but have no verification task to release them after an error.
			for piece in pending { _ = picker.verified(piece, valid: false) }
			discardUnretainedPayload(); await disk.release(); throw error
		}
		await disk.release(); fillAll()
	}
}
