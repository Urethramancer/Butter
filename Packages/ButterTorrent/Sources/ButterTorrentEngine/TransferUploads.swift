import Foundation

extension TCPTransfer {
	func requestUpload(_ id: UUID, block: PeerBlock) throws {
		guard let peer = peers[id], !peer.choking else { return }
		guard picker.completed.contains(block.piece) else { throw PeerFailure.invalid("request for an unavailable piece") }
		if peer.uploads[block] != nil { return }
		guard peer.uploads.count < 32, uploadJobs.count < 64 else { throw PeerFailure.limit("upload requests") }
		let token = UUID(); peer.uploads[block] = token
		let task = Task { [weak self] in
			guard let self else { return }
			do { try await self.buildUpload(id, block: block, token: token) }
			catch { await self.uploadFailed(id, error: error) }
			await self.uploadJobFinished(token)
		}
		uploadJobs[token] = (id, task)
	}
	func buildUpload(_ id: UUID, block: PeerBlock, token: UUID) async throws {
		try await disk.acquire()
		do {
			try Task.checkCancellation()
			let piece = try await cache.piece(block.piece)
			try Task.checkCancellation()
			guard !stopping, let peer = peers[id], !peer.closing, !peer.choking, peer.uploads[block] == token else { throw PeerFailure.closed }
			let data = piece.subdata(in: block.offset..<(block.offset + block.length))
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
