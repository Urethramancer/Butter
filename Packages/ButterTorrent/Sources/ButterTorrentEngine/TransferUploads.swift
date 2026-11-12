import Foundation

struct UploadGroupKey: Hashable, Sendable {
	let peer: UUID
	let piece: Int
}

struct UploadPayloadGroup {
	let key: UploadGroupKey
	let task: Task<Void, Never>
	var requests: [(token: UUID, block: PeerBlock)]
}

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
		guard peer.uploads.count < PeerSession.uploadRequestLimit, uploadJobs.count < 64 else {
			if peer.features.fast || peer.features.v2 { try send(id, .reject(block)) }; return false
		}
		let token = UUID()
		guard peer.session.register(token, bytes: block.length + 13) else {
			if peer.features.fast || peer.features.v2 { try send(id, .reject(block)) }; return false
		}
		peer.uploads[block] = token
		let key = UploadGroupKey(peer: id, piece: block.piece)
		if let groupID = uploadGroupKeys[key] {
			uploadGroups[groupID]!.requests.append((token, block))
			uploadJobs[token] = groupID
			return true
		}
		let groupID = UUID()
		let task = Task { [weak self] in
			guard let self else { return }
			do {
				let piece = try await self.cache.piece(block.piece)
				try Task.checkCancellation()
				await self.finishUploadGroup(groupID, result: .success(piece))
			} catch { await self.finishUploadGroup(groupID, result: .failure(error)) }
		}
		uploadGroups[groupID] = UploadPayloadGroup(key: key, task: task, requests: [(token, block)])
		uploadGroupKeys[key] = groupID
		uploadJobs[token] = groupID
		return true
	}
	func cancelUpload(_ token: UUID) {
		guard let groupID = uploadJobs[token], let group = uploadGroups[groupID] else { return }
		let peer = peers[group.key.peer]
		// One cancelled block must not cancel another block's shared piece read.
		guard !group.requests.contains(where: { $0.token != token && peer?.uploads[$0.block] == $0.token }) else { return }
		group.task.cancel()
		// Replacements must start fresh even while the cancelled worker drains.
		if uploadGroupKeys[group.key] == groupID { uploadGroupKeys[group.key] = nil }
	}
	func finishUploadGroup(_ groupID: UUID, result: Result<Data, Error>) {
		guard let group = uploadGroups.removeValue(forKey: groupID) else { return }
		if uploadGroupKeys[group.key] == groupID { uploadGroupKeys[group.key] = nil }
		for request in group.requests { uploadJobs[request.token] = nil }
		do {
			let piece = try result.get()
			guard !stopping, let peer = peers[group.key.peer], !peer.closing else { return }
			// Flush available requests immediately; do not wait for a full group.
			for (token, block) in group.requests {
				guard (!peer.choking || peer.allowedIncoming.contains(block.piece)), peer.uploads[block] == token else { continue }
				let data = piece[block.offset..<(block.offset + block.length)]
				try peer.session.send(.piece(block.piece, block.offset, data), token: token, block: block); peer.lastSent = clock.now()
			}
		} catch { uploadFailed(group.key.peer, error: error) }
	}
	func uploadedBatch(_ id: UUID, items: [PeerSession.Outbound]) {
		for item in items { if let block = item.block, let token = item.token { uploaded(id, block: block, token: token, count: item.payload) } }
	}
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
