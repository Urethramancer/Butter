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
	private func invalidateWriteTargets(_ segments: [[StorageLayout.Segment]]) throws {
		var targets: Set<Int> = []
		for parts in segments { for segment in parts where !segment.padding { targets.insert(segment.file) } }
		let scan = StorageStampScan()
		// Inspect every target before changing progress. Other files are checked by
		// verification, snapshots, checkpoints and filesystem-operation barriers.
		let current = try targets.sorted().map { index in
			let (directory, path) = location(index)
			return (index, try scan.inspect(path, in: directory))
		}
		for (index, stamp) in current { try reconcileFile(index, stamp: stamp) }
	}
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
		StorageDiagnostics.count(.writeBatches); StorageDiagnostics.count(.writeBlocks, writes.count)
		try invalidateWriteTargets(segments)
		let pieces = Set(writes.map(\.piece))
		let invalidated = pieces.filter(committedContains)
		for piece in pieces { record.set(piece, false); recoveryChecked[piece / 8] &= ~UInt8(128 >> (piece % 8)) }
		if !invalidated.isEmpty {
			// Leave invalidated bits false after failure: save may detect an external edit.
			try save()
		}
		for piece in pieces { try forgetPendingVerification(piece) }
		var files: [Int: (descriptor: Int32, identity: FileStamp)] = [:], order: [Int] = []
		defer { for file in files.values { close(file.descriptor) } }
		for index in writes.indices {
			if index > 0 { try check() }
			let write = writes[index], parts = segments[index]
			var cursor = write.data.startIndex
			for segment in parts {
				defer { cursor += segment.count }
				if segment.padding { continue }
				let (directory, path) = location(segment.file)
				let file: Int32
				let opened: FileStamp
				if let cached = files[segment.file] {
					file = cached.descriptor; opened = cached.identity; StorageDiagnostics.count(.writeDescriptorCacheHits)
				} else {
					if files.count == 8 { let oldest = order.removeFirst(); close(files.removeValue(forKey: oldest)!.descriptor) }
					file = try directory.openFile(path, write: true)
					do { opened = try directory.stamp(file) } catch { close(file); throw error }
					files[segment.file] = (file, opened); order.append(segment.file)
				}
				// An owned open descriptor keeps its device/inode identity. The path and
				// post-write content stamp still require fresh inspection for every block.
				// Re-check even the first open: replacement can occur after the initial scan.
				guard let current = try directory.inspect(path), current.sameFile(opened) else { throw StorageFailure.invalid("payload replaced during write batch") }
				if current != record.stamps[segment.file] { try invalidateChangedFiles(external: record.stamps[segment.file] != nil) }
				pendingFlush.insert(segment.file)
				try StorageDirectory.write(write.data[cursor..<(cursor + segment.count)], to: file, offset: segment.offset, check: check)
				record.stamps[segment.file] = try directory.stamp(file)
			}
		}
	}
}
