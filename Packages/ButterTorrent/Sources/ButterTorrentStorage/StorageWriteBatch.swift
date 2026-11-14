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
		try await worker.run(write: true) { [state] cancellation in
			try state.writeOperations(writes, maximumBytes: 262144, maximumCount: 16, check: cancellation.check)
		}
	}
	/// Writes received blocks using contiguous file ranges within a shared 1 MiB buffer budget.
	public func writeDownloadBatch(_ writes: [StorageWrite], bufferBudget: DownloadWriteBufferBudget) async throws {
		try StorageState.validateWrites(writes, maximumBytes: 1_048_576, maximumCount: 64)
		let size = writes.reduce(0) { $0 + $1.data.count }
		let reserved = writes.count > 1 && bufferBudget.reserve(size)
		defer { if reserved { bufferBudget.release(size) } }
		try await worker.run(write: true) { [state] cancellation in
			try state.writeOperations(writes, maximumBytes: 1_048_576, maximumCount: 64, coalescing: reserved, budgetFallback: writes.count > 1 && !reserved, check: cancellation.check)
		}
	}
}

extension StorageState {
	private func invalidateWriteTargets(_ segments: [[StorageLayout.Segment]]) throws {
		var targets: Set<Int> = []
		for parts in segments { for segment in parts where !segment.padding { targets.insert(segment.file) } }
		writeProfile?.count("targetFiles", targets.count)
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
	func writeOperations(_ writes: [StorageWrite], maximumBytes: Int, maximumCount: Int, coalescing: Bool = false, budgetFallback: Bool = false, diagnosticRecorder: StorageWriteProfile? = StorageWriteProfile.make(), check: () throws -> Void) throws {
		let profile = diagnosticRecorder; writeProfile = profile
		var outcome = "failed"
		defer { profile?.finish(outcome: outcome); writeProfile = nil }
		profile?.count(coalescing ? "coalescedJobs" : "ordinaryJobs")
		profile?.count("receivedBlocks", writes.count)
		profile?.histogram("blocksPerJob", writes.count)
		if let profile { let bytes = writes.reduce(0) { $0 + $1.data.count }; profile.histogram("bytesPerJob", bytes); profile.count("logicalBytes", bytes) }
		if budgetFallback { profile?.count("bufferBudgetFallback") }
		profile?.enter(.setup)
		func checked() throws {
			do { try check() } catch { if error is CancellationError { outcome = "cancelled" }; throw error }
		}
		try ready(); try checked(); try Self.validateWrites(writes, maximumBytes: maximumBytes, maximumCount: maximumCount)
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
		profile?.enter(.targetInspection)
		try invalidateWriteTargets(segments)
		profile?.enter(.progressInvalidation)
		let pieces = Set(writes.map(\.piece))
		let invalidated = pieces.filter(committedContains)
		for piece in pieces { record.set(piece, false); recoveryChecked[piece / 8] &= ~UInt8(128 >> (piece % 8)) }
		if !invalidated.isEmpty {
			// Leave invalidated bits false after failure: save may detect an external edit.
			try save()
		}
		for piece in pieces { try forgetPendingVerification(piece) }
		if coalescing {
			try writeContiguousRanges(writes, segments: segments, check: checked); outcome = "succeeded"; return
		}
		var files: [Int: Int32] = [:], order: [Int] = []
		defer { profile?.enter(.cleanup); for file in files.values { close(file); profile?.count("descriptorCloses") } }
		for index in writes.indices {
			profile?.enter(.prewriteChecks)
			if index > 0 { try checked() }
			let write = writes[index], parts = segments[index]
			var cursor = write.data.startIndex
			for segment in parts {
				defer { cursor += segment.count }
				if segment.padding { continue }
				profile?.enter(.descriptorAcquisition)
				profile?.count("descriptorAcquisitions")
				let (directory, path) = location(segment.file)
				let file: Int32
				if let cached = files[segment.file] {
					file = cached; profile?.count("descriptorHits"); StorageDiagnostics.count(.writeDescriptorCacheHits)
				} else {
					if files.count == 8 { let oldest = order.removeFirst(); profile?.enter(.cleanup); close(files.removeValue(forKey: oldest)!); profile?.count("descriptorCloses"); profile?.enter(.descriptorAcquisition) }
					file = try directory.openFile(path, write: true); files[segment.file] = file; order.append(segment.file)
				}
				profile?.enter(.prewriteChecks)
				// Re-check even the first open: replacement can occur after the initial scan.
				let opened = try directory.stamp(file)
				guard let current = try directory.inspect(path), current.sameFile(opened) else { throw StorageFailure.invalid("payload replaced during write batch") }
				if current != record.stamps[segment.file] {
					profile?.count(record.stamps[segment.file] == nil ? "ordinaryMismatchAbsent" : "ordinaryMismatchRecorded")
					try invalidateChangedFiles(external: record.stamps[segment.file] != nil, origin: "ordinary")
				}
				pendingFlush.insert(segment.file)
				try StorageDirectory.write(write.data[cursor..<(cursor + segment.count)], to: file, offset: segment.offset, profile: profile, check: checked)
				profile?.enter(.postwriteStamping)
				record.stamps[segment.file] = try directory.stamp(file)
			}
		}
		outcome = "succeeded"
	}
}
