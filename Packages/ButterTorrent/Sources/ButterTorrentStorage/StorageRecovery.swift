import Foundation
import Darwin

extension TorrentStorage {
	/// Lazily checks one existing, unverified piece once per storage opening.
	/// Missing/short data is retained for later writes, without a startup payload scan.
	public func recoverExistingPiece(_ piece: Int) async throws -> Bool {
		let result = try await worker.run { [state] cancellation in
			let valid = try state.recoverExistingPiece(piece, check: cancellation.check)
			return (valid, state.checkpointDeadline)
		}
		armCheckpointTimer(result.1); return result.0
	}
}

extension StorageState {
	func recoverExistingPiece(_ piece: Int, check: () throws -> Void) throws -> Bool {
		try ready(); let length = try layout.length(of: piece); try check(); try invalidateChangedFiles()
		let mask = UInt8(128 >> (piece % 8))
		if recoveryChecked[piece / 8] & mask != 0 { return record.contains(piece) }
		func checked(_ valid: Bool) -> Bool { recoveryChecked[piece / 8] |= mask; return valid }
		for offset in stride(from: 0, to: length, by: 1_048_576) {
			for segment in try layout.segments(piece: piece, offset: offset, count: min(1_048_576, length - offset)) where !segment.padding {
				try check()
				let (directory, path) = location(segment.file)
				guard let stamp = try directory.inspect(path), stamp.size >= segment.offset + Int64(segment.count) else { return checked(false) }
			}
		}
		do { return checked(try verify(piece: piece, check: check)) }
		catch StorageFailure.invalid("short payload read") { return checked(false) }
		catch StorageFailure.missingHashes {
			// A legacy hybrid peer may not supply v2 layers. Check the available v1
			// hash once, but never advertise it as fully authenticated hybrid data.
			guard metadata.hashes.v1 != nil else { return false }
			let before = try stamps()
			_ = try digestPiece(piece, check: check)
			guard try stamps() == before else { throw StorageFailure.invalid("payload changed during verification") }
			return checked(false)
		}
		catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return checked(false) }
	}
}
