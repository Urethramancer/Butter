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
		try await performWriteBatch(writes, bufferBudget: nil) { _, _, _ in () }
	}
	/// Writes received blocks using contiguous file ranges within a shared 1 MiB buffer budget.
	public func writeDownloadBatch(_ writes: [StorageWrite], bufferBudget: DownloadWriteBufferBudget) async throws {
		try await performWriteBatch(writes, bufferBudget: bufferBudget) { _, _, _ in () }
	}
	/// Writes a batch and verifies one completed piece in the same disk job.
	/// Write failures throw; verification failures are returned after successful writes.
	public func writeAndVerifyBatch(_ writes: [StorageWrite], piece: Int, bufferBudget: DownloadWriteBufferBudget? = nil) async throws -> Result<Bool, Error> {
		let result = try await performWriteBatch(writes, bufferBudget: bufferBudget, retainDescriptors: true) { state, openFiles, cancellation in
			let verified = Result { try state.verify(piece: piece, profileKind: .verificationInWrite, openFiles: openFiles, check: cancellation.check) }
			return (verified, state.checkpointDeadline)
		}
		armCheckpointTimer(result.1); return result.0
	}
	private func performWriteBatch<Output: Sendable>(_ writes: [StorageWrite], bufferBudget: DownloadWriteBufferBudget?, retainDescriptors: Bool = false, afterWrite: @escaping @Sendable (StorageState, [Int: (fd: Int32, stamp: FileStamp)], DiskCancellation) throws -> Output) async throws -> Output {
		let maximumBytes = bufferBudget == nil ? 262144 : 1_048_576, maximumCount = bufferBudget == nil ? 16 : 64
		try StorageState.validateWrites(writes, maximumBytes: maximumBytes, maximumCount: maximumCount)
		let size = bufferBudget == nil ? 0 : writes.reduce(0) { $0 + $1.data.count }
		let reserved = writes.count > 1 && bufferBudget?.reserve(size) == true
		defer { if reserved { bufferBudget?.release(size) } }
		return try await worker.run(write: true) { [state] cancellation in
			var openFiles: [Int: (fd: Int32, stamp: FileStamp)] = [:]
			defer { for entry in openFiles.values { close(entry.fd) } }
			if retainDescriptors {
				try state.writeOperations(writes, maximumBytes: maximumBytes, maximumCount: maximumCount, coalescing: reserved, budgetFallback: bufferBudget != nil && writes.count > 1 && !reserved, retainedFiles: &openFiles, check: cancellation.check)
			} else {
				try state.writeOperations(writes, maximumBytes: maximumBytes, maximumCount: maximumCount, coalescing: reserved, budgetFallback: bufferBudget != nil && writes.count > 1 && !reserved, check: cancellation.check)
			}
			return try afterWrite(state, openFiles, cancellation)
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
	func writeOperations(_ writes: [StorageWrite], maximumBytes: Int, maximumCount: Int, coalescing: Bool = false, budgetFallback: Bool = false, diagnosticRecorder: StorageWriteProfile? = StorageWriteProfile.make(), retainedFiles: UnsafeMutablePointer<[Int: (fd: Int32, stamp: FileStamp)]>? = nil, check: () throws -> Void) throws {
		#if BUTTER_STORAGE_REPLAY_CAPTURE
		guard layout.pieceLength == 262144, writes.allSatisfy({ $0.offset.isMultiple(of: 16384) && $0.data.count == 16384 }) else {
			throw StorageFailure.invalid("unexpected replay block geometry")
		}
		capturedWriteJobs.append(writes.map { $0.piece * 16 + $0.offset / 16384 })
		#endif
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
			try writeContiguousRanges(writes, segments: segments, retainedFiles: retainedFiles, check: checked); outcome = "succeeded"; return
		}
		var files: [Int: (fd: Int32, stamp: FileStamp)] = [:], order: [Int] = []
		var transferred = false
		defer {
			if !transferred {
				profile?.enter(.cleanup)
				for entry in files.values { close(entry.fd); profile?.count("descriptorCloses") }
			}
		}
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
				var freshStamp: FileStamp?
				if let cached = files[segment.file] {
					file = cached.fd; profile?.count("descriptorHits"); StorageDiagnostics.count(.writeDescriptorCacheHits)
				} else {
					if files.count == 8 { let oldest = order.removeFirst(); profile?.enter(.cleanup); close(files.removeValue(forKey: oldest)!.fd); profile?.count("descriptorCloses"); profile?.enter(.descriptorAcquisition) }
					let (openedFile, openedStamp) = try directory.openFileWithStamp(path, write: true)
					file = openedFile; freshStamp = openedStamp; files[segment.file] = (openedFile, openedStamp); order.append(segment.file)
				}
				profile?.enter(.prewriteChecks)
				// Re-check even the first open: replacement can occur after the initial scan.
				let opened = try freshStamp ?? directory.stamp(file)
				guard let current = try directory.inspect(path), current.sameFile(opened) else { throw StorageFailure.invalid("payload replaced during write batch") }
				if current != record.stamps[segment.file] {
					profile?.count(record.stamps[segment.file] == nil ? "ordinaryMismatchAbsent" : "ordinaryMismatchRecorded")
					try invalidateChangedFiles(external: record.stamps[segment.file] != nil, origin: "ordinary")
				}
				pendingFlush.insert(segment.file)
				try StorageDirectory.write(write.data[cursor..<(cursor + segment.count)], to: file, offset: segment.offset, profile: profile, check: checked)
				profile?.enter(.postwriteStamping)
				let finalStamp = try directory.stamp(file)
				record.stamps[segment.file] = finalStamp
				files[segment.file] = (file, finalStamp)
			}
		}
		if let retainedFiles {
			retainedFiles.pointee = files
			transferred = true
		}
		outcome = "succeeded"
	}
}
