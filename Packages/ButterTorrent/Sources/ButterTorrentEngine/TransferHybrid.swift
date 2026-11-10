import ButterTorrentStorage

extension TCPTransfer {
	var legacyHybrid: Bool { metadata.hashes.v1 != nil && metadata.hashes.v2 != nil }

	func advertise(_ piece: Int) {
		for (id, peer) in peers where peer.peerID != nil && !peer.closing {
			do { try send(id, .have(piece)) } catch { drop(id, error: error) }
		}
	}

	func recoverLegacyLayer(after piece: Int, staged: Bool) async throws {
		guard let mapping = storage.merkleIndex.pieces[piece], let file = storage.merkleIndex.files[mapping.root] else { return }
		let start = piece - mapping.local, range = start..<(start + file.pieces)
		if let remaining = legacyRemaining[start] {
			legacyRemaining[start] = remaining - 1
		} else if staged {
			legacyRemaining[start] = range.reduce(0) { $0 + (picker.completed.contains($1) || picker.staged.contains($1) ? 0 : 1) }
		}
		guard legacyRemaining[start] == 0, reconstructingLegacyFiles.insert(start).inserted else { return }
		defer { reconstructingLegacyFiles.remove(start) }
		if !range.contains(where: picker.staged.contains) { legacyRemaining[start] = nil; return }
		let result = try await storage.reconstructHybridLayer(containing: piece)
		switch result {
		case .incomplete(let legacyPieces):
			for index in range where !legacyPieces.contains(index) {
				guard !picker.completed.contains(index) else { throw StorageFailure.invalid("payload changed during verification") }
				_ = picker.settleStaged(index, valid: false)
			}
			legacyRemaining[start] = range.reduce(0) { $0 + (picker.completed.contains($1) || picker.staged.contains($1) ? 0 : 1) }
		case .verified(let pieces):
			guard pieces.count == file.pieces else { throw StorageFailure.invalid("payload changed during verification") }
			for index in range where picker.settleStaged(index, valid: true) { advertise(index) }
			legacyRemaining[start] = nil
			try await refreshAuthenticatedPieces()
		}
	}

	func refreshAuthenticatedPieces() async throws {
		let available = try await storage.availableHashes()
		hashReady.formUnion(available)
		for piece in picker.staged.intersection(available).sorted() where picker.staged.contains(piece) {
			guard let mapping = storage.merkleIndex.pieces[piece] else { continue }
			let start = piece - mapping.local
			guard !reconstructingLegacyFiles.contains(start) else { continue }
			let valid = try await storage.verify(piece: piece)
			if picker.settleStaged(piece, valid: valid) {
				if valid { advertise(piece) }
				else { legacyRemaining[start, default: 0] += 1 }
			}
		}
	}
}
