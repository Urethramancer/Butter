import Foundation

extension TCPTransfer {
	// Probe only pieces selected for a real request; never scan the torrent on start.
	func deferForLocalRecovery(_ peer: UUID, block: PeerBlock) -> Bool {
		guard hasExistingPayload, !locallyChecked.contains(block.piece) else { return false }
		picker.rejected(peer, block: block)
		let piece = block.piece
		guard localRecoveries[piece] == nil else { return true }
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
			if !stopping { fillAll() }
		}
		return true
	}
}
