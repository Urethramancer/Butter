import Foundation
import Darwin

/// StorageWrite describes one bounded write to a torrent piece.
public struct StorageWrite: Sendable {
	public let piece: Int
	public let offset: Int
	public let data: Data
	public init(piece: Int, offset: Int, data: Data) { self.piece = piece; self.offset = offset; self.data = data }
}

extension TorrentStorage {
	/// Writes at most sixteen blocks and 256 KiB in one admitted disk job.
	public func writeBatch(_ writes: [StorageWrite]) async throws {
		try StorageState.validateWrites(writes, maximumBytes: 262144, maximumCount: 16)
		try await worker.run { [state] cancellation in
			try state.writeOperations(writes, maximumBytes: 262144, maximumCount: 16, check: cancellation.check)
		}
	}
}

extension StorageState {
	static func validateWrites(_ writes: [StorageWrite], maximumBytes: Int, maximumCount: Int) throws {
		guard !writes.isEmpty, writes.count <= maximumCount else { throw StorageFailure.limit("write batch blocks") }
		var total = 0
		for write in writes {
			guard !write.data.isEmpty, write.data.count <= maximumBytes - total else { throw StorageFailure.limit("write batch bytes") }
			total += write.data.count
		}
	}
	func writeOperations(_ writes: [StorageWrite], maximumBytes: Int, maximumCount: Int, check: () throws -> Void) throws {
		try ready(); try check(); try Self.validateWrites(writes, maximumBytes: maximumBytes, maximumCount: maximumCount)
		// Validate every range and padding byte before any write or durable invalidation.
		let segments = try writes.map { try layout.segments(piece: $0.piece, offset: $0.offset, count: $0.data.count) }
		for (write, parts) in zip(writes, segments) {
			var cursor = write.data.startIndex
			for segment in parts {
				if segment.padding, write.data[cursor..<(cursor + segment.count)].contains(where: { $0 != 0 }) { throw StorageFailure.invalid("nonzero padding") }
				cursor += segment.count
			}
		}
		try invalidateChangedFiles()
		let pieces = Set(writes.map(\.piece))
		let invalidated = pieces.filter(committedContains)
		for piece in pieces { record.set(piece, false) }
		if !invalidated.isEmpty {
			// Leave invalidated bits false after failure: save may detect an external edit.
			try save()
		}
		for piece in pieces { try forgetPendingVerification(piece) }
		var files: [Int: Int32] = [:], order: [Int] = []
		defer { for file in files.values { close(file) } }
		for index in writes.indices {
			if index > 0 { try check() }
			let write = writes[index], parts = segments[index]
			var cursor = write.data.startIndex
			for segment in parts {
				defer { cursor += segment.count }
				if segment.padding { continue }
				let (directory, path) = location(segment.file)
				let file: Int32
				if let cached = files[segment.file] {
					file = cached
				} else {
					if files.count == 8 { let oldest = order.removeFirst(); close(files.removeValue(forKey: oldest)!) }
					file = try directory.openFile(path, write: true); files[segment.file] = file; order.append(segment.file)
				}
				// Re-check even the first open: replacement can occur after the initial scan.
				let opened = try directory.stamp(file)
				guard let current = try directory.inspect(path), current.sameFile(opened) else { throw StorageFailure.invalid("payload replaced during write batch") }
				if current != record.stamps[segment.file] { try invalidateChangedFiles() }
				pendingFlush.insert(segment.file)
				try StorageDirectory.write(write.data.subdata(in: cursor..<(cursor + segment.count)), to: file, offset: segment.offset, check: check)
				record.stamps[segment.file] = try directory.stamp(file)
			}
		}
	}
}
