import Foundation
import ButterTorrentMetadata
import ButterTorrentStorage

/// TransferProgress maps verified pieces to selected file bytes for snapshots and announces.
public struct TransferProgress: Sendable {
	public struct File: Sendable {
		public let metadata: TorrentMetadata.File
		public let path: String
		public let done: Int64
		public let selected: Bool
	}
	public let total: Int64
	public let wanted: Int64
	public let done: Int64
	public let verifiedBytes: Int64
	public let pieceCount: Int
	public let files: [File]
	public init(metadata: TorrentMetadata, storage: StorageSnapshot) {
		let length = metadata.pieceLength, total = metadata.inspection.files.reduce(Int64(0)) { $0 + $1.size }
		let count = Int(total / length + (total % length == 0 ? 0 : 1)), verified = storage.verifiedPieces
		var prefix = [Int64](repeating: 0, count: count + 1)
		for piece in 0..<count { prefix[piece + 1] = prefix[piece] + (verified.contains(piece) ? min(length, total - Int64(piece) * length) : 0) }
		func completed(_ offset: Int64) -> Int64 {
			let piece = Int(offset / length); return prefix[min(piece, count)] + (piece < count && verified.contains(piece) ? offset % length : 0)
		}
		var offset: Int64 = 0, wanted: Int64 = 0, done: Int64 = 0, files: [File] = []
		for file in metadata.inspection.files {
			let bytes = completed(offset + file.size) - completed(offset), selected = storage.selected[file.index] && !file.pad
			files.append(File(metadata: file, path: storage.paths[file.index], done: bytes, selected: selected))
			if selected { wanted += file.size; done += bytes }; offset += file.size
		}
		self.total = total; self.wanted = wanted; self.done = done; verifiedBytes = prefix[count]; pieceCount = count; self.files = files
	}
}
