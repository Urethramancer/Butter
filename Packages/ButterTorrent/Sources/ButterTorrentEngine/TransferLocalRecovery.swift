import Foundation

extension TCPTransfer {
	// Demand checks enter before another background check is scheduled.
	func deferForLocalRecovery(_ peer: UUID, block: PeerBlock) -> Bool {
		guard hasExistingPayload, !locallyChecked.contains(block.piece) else { return false }
		picker.rejected(peer, block: block)
		let piece = block.piece
		guard localRecoveries[piece] == nil else { return true }
		startLocalRecovery(piece)
		return true
	}
	func scheduleBackgroundRecovery() {
		guard !stopping, storageError == nil, localRecoveries.isEmpty else { return }
		while backgroundRecoveryCursor < storage.layout.pieceCount {
			let piece = backgroundRecoveryCursor; backgroundRecoveryCursor += 1
			guard pendingLocalChecks.contains(piece), !locallyChecked.contains(piece), !picker.completed.contains(piece), picker.active[piece] == nil else { continue }
			startLocalRecovery(piece); return
		}
	}
	private func startLocalRecovery(_ piece: Int) {
		localRecoveries[piece] = Task {
			do {
				try await disk.acquire()
				let valid: Bool
				do { try Task.checkCancellation(); valid = try await storage.recoverExistingPiece(piece) }
				catch { await disk.release(); throw error }
				await disk.release(); try Task.checkCancellation()
				guard !stopping else { throw CancellationError() }
				locallyChecked.insert(piece)
				if valid {
					_ = picker.verified(piece, valid: true); advertise(piece)
				}
			} catch { diskFailed(error) }
			localRecoveries[piece] = nil
			if !stopping { fillAll(); scheduleBackgroundRecovery() }
		}
	}
}
