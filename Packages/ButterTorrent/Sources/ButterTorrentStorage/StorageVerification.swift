import Foundation

struct StorageFileObservation: Equatable {
	let index: Int
	let stamp: FileStamp?
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
		return observations
	}
	func reconcileFile(_ index: Int, stamp: FileStamp?) throws {
		guard stamp != record.stamps[index] else { return }
		for piece in try layout.pieces(touchingFile: index) {
			if record.contains(piece) { StorageDiagnostics.count(.verificationInvalidations) }
			record.set(piece, false)
		}
		record.stamps[index] = stamp
	}
}
