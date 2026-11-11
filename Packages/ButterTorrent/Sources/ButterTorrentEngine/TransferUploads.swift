import Foundation

extension TCPTransfer {
	func requestUpload(_ id: UUID, block: PeerBlock) throws -> Bool {
		guard let peer = peers[id] else { return false }
		// Hybrid peers may retain v1 block lengths after upgrading the handshake to v2.
		// The validated hybrid layout fills the remainder of each file's last piece with zero padding.
		if peer.features.v2, metadata.hashes.v1 == nil, let actual = storage.merkleIndex.pieces[block.piece]?.length, block.offset + block.length > actual { throw PeerFailure.invalid("v2 request crosses a file boundary") }
		if (peer.choking && !peer.allowedIncoming.contains(block.piece)) || !picker.completed.contains(block.piece) {
			if peer.features.fast || peer.features.v2 { try send(id, .reject(block)) }; return false
		}
		if peer.uploads[block] != nil { throw PeerFailure.invalid("duplicate upload request") }
		// A replacement request can arrive before the writer's completion callback.
		// Reject excess work without dropping the connection or enlarging either queue.
		guard peer.uploads.count < 32, uploadJobs.count < 64 else {
			if peer.features.fast || peer.features.v2 { try send(id, .reject(block)) }; return false
		}
		let token = UUID()
		guard peer.session.register(token, bytes: block.length + 13) else {
			if peer.features.fast || peer.features.v2 { try send(id, .reject(block)) }; return false
		}
		peer.uploads[block] = token
		let task = Task { [weak self] in
			guard let self else { return }
			do { try await self.buildUpload(id, block: block, token: token) }
			catch { await self.uploadFailed(id, error: error) }
			await self.uploadJobFinished(token)
		}
		uploadJobs[token] = (id, task)
		return true
	}
	func buildUpload(_ id: UUID, block: PeerBlock, token: UUID) async throws {
		try await disk.acquire()
		do {
			try Task.checkCancellation()
			let piece = try await cache.piece(block.piece)
			try Task.checkCancellation()
			guard !stopping, let peer = peers[id], !peer.closing, !peer.choking || peer.allowedIncoming.contains(block.piece), peer.uploads[block] == token else { throw PeerFailure.closed }
			let data = piece[block.offset..<(block.offset + block.length)]
			try peer.session.send(.piece(block.piece, block.offset, data), token: token, block: block); peer.lastSent = clock.now()
		} catch { await disk.release(); throw error }
		await disk.release()
	}
	func uploadJobFinished(_ token: UUID) { uploadJobs[token] = nil }
	func uploaded(_ id: UUID, block: PeerBlock, token: UUID, count: Int) {
		uploaded = min(Int64.max - Int64(count), uploaded) + Int64(count)
		if let peer = peers[id] {
			peer.uploaded += Int64(count)
			if peer.uploads[block] == token { peer.uploads[block] = nil }
		}
	}
	func uploadFailed(_ id: UUID, error: Error) {
		if error is CancellationError || (error as? PeerFailure) == .closed { return }
		if error is PeerFailure { drop(id, error: error) } else { diskFailed(error) }
	}
}
