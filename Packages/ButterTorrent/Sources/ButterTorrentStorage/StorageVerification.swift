import Foundation

/// StorageVerificationPolicy controls checking historical checkpoint claims on open.
public enum StorageVerificationPolicy: Sendable, Equatable { case eager, deferred }

struct StorageFileObservation: Equatable {
	let index: Int
	let stamp: FileStamp?
	var generation: UInt64 = 0
}

extension StorageState {
	func observe(piece: Int) throws -> [StorageFileObservation] {
		let scan = StorageStampScan()
		let observations = try layout.files(touchingPiece: piece).compactMap { index -> StorageFileObservation? in
			guard !layout.files[index].pad, layout.files[index].size > 0 else { return nil }
			let (directory, path) = location(index)
			return StorageFileObservation(index: index, stamp: try scan.inspect(path, in: directory))
		}
		for observation in observations { try reconcileFile(observation.index, stamp: observation.stamp) }
		return observations.map { StorageFileObservation(index: $0.index, stamp: $0.stamp, generation: fileGenerations[$0.index]) }
	}
	func reconcileFile(_ index: Int, stamp: FileStamp?, external: Bool = true) throws {
		guard stamp != record.stamps[index] else { return }
		fileGenerations[index] &+= 1
		if external { integrityGeneration &+= 1 }
		for piece in try layout.pieces(touchingFile: index) {
			if record.contains(piece) { StorageDiagnostics.count(.verificationInvalidations) }
			record.set(piece, false)
			let mask = UInt8(128 >> (piece % 8))
			recoveryChecked[piece / 8] &= ~mask
			if external { verificationPending[piece / 8] |= mask }
			try forgetPendingVerification(piece)
		}
		record.stamps[index] = stamp
	}
	func finishVerificationAttempt(_ piece: Int, pending: Bool = false) {
		let mask = UInt8(128 >> (piece % 8))
		recoveryChecked[piece / 8] |= mask
		if pending { verificationPending[piece / 8] |= mask } else { verificationPending[piece / 8] &= ~mask }
	}
	var uncheckedPieces: Data {
		var result = verificationPending
		for index in result.indices { result[index] &= ~recoveryChecked[index] }
		return result
	}
}
