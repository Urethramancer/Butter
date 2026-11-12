import Foundation

extension TorrentStorage {
	/// Returns a result for each index after shared full-layout guards and stored-byte hashing.
	/// Each piece consumes its own admission unit; eight pieces and 16 MiB are the limits.
	public func readVerifiedPieces(_ pieces: [Int]) async throws -> [Int: Result<Data, Error>] {
		guard (1...8).contains(pieces.count) else { throw StorageFailure.limit("verified read batch pieces") }
		guard Set(pieces).count == pieces.count else { throw StorageFailure.invalid("duplicate verified read pieces") }
		var total = 0
		for piece in pieces {
			let length = try layout.length(of: piece)
			guard length <= 16_777_216 - total else { throw StorageFailure.limit("verified read batch bytes") }
			total += length
		}
		return try await worker.run(units: pieces.count) { [state] cancellation in state.verifiedPieces(pieces, check: cancellation.check) }
	}
}

extension StorageState {
	func verifiedPieces(_ pieces: [Int], check: () throws -> Void) -> [Int: Result<Data, Error>] {
		if pieces.count == 1 { return [pieces[0]: Result { try check(); return try verifiedPiece(pieces[0], check: check) }] }
		let before: [FileStamp?]
		do { try check(); try ready(); before = try invalidateChangedFiles() }
		catch { return Dictionary(uniqueKeysWithValues: pieces.map { ($0, .failure(error)) }) }
		var results: [Int: Result<Data, Error>] = [:], checked: [(piece: Int, valid: Bool, bytes: Data)] = []
		for piece in pieces {
			// Cancelled, unstarted reads do not lose their existing verified progress.
			do { try check() } catch { results[piece] = .failure(error); continue }
			guard record.contains(piece) else { results[piece] = .failure(StorageFailure.invalid("piece has not been verified")); continue }
			do {
				let length = try layout.length(of: piece), digest = try checkedDigest(piece, range: 0..<length, check: check)
				checked.append((piece, digest.valid, digest.bytes))
			} catch { record.set(piece, false); results[piece] = .failure(error) }
		}
		do {
			// No bytes leave until every file still matches the pre-hash baseline.
			if !checked.isEmpty, try stamps() != before { throw StorageFailure.invalid("payload changed during verification") }
			for item in checked {
				do {
					try check()
					guard item.valid else { throw StorageFailure.invalid("verified payload failed its hash") }
					results[item.piece] = .success(item.bytes)
				} catch { record.set(item.piece, false); results[item.piece] = .failure(error) }
			}
		} catch {
			for item in checked { record.set(item.piece, false); results[item.piece] = .failure(error) }
		}
		return results
	}
}
