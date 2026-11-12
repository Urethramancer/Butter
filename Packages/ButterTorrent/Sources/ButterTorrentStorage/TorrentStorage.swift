import Foundation
import Darwin
import CryptoKit
import ButterTorrentMetadata

/// TorrentStorage exposes serial, bounded disk operations without GUI dependencies.
public actor TorrentStorage {
	let worker: StorageWorker
	let state: StorageState
	let checkpointClock: any StorageCheckpointClock
	var checkpointTimer: Task<Void, Never>?
	var checkpointTimerID: UUID?
	var checkpointTimerDeadline: TimeInterval?
	var closing = false
	var shutdownCompleted = false
	public nonisolated let layout: StorageLayout
	public nonisolated let infoHashes: InfoHashes
	public nonisolated let merkleIndex: MerkleIndex
	private init(state: StorageState, worker: StorageWorker, clock: any StorageCheckpointClock) { self.state = state; self.worker = worker; checkpointClock = clock; layout = state.layout; infoHashes = state.metadata.hashes; merkleIndex = state.merkle.index }
	public static func open(metadata: TorrentMetadata, destination: URL, stateDirectory: URL, selected: [Bool]? = nil,
		coordinator: StorageCoordinator = .shared, preparedState: PreparedTransferState? = nil, checkpointPolicy: StorageCheckpointPolicy = .immediate,
		checkpointClock: any StorageCheckpointClock = ContinuousStorageCheckpointClock(), event: @escaping @Sendable (StorageEvent) -> Void = { _ in }) async throws -> TorrentStorage {
		try checkpointPolicy.validate()
		guard preparedState == nil || preparedState?.directory == stateDirectory else { throw StorageFailure.invalid("prepared checkpoint directory") }
		let worker = StorageWorker()
		let state = try await worker.run(bulk: true) { cancellation in
			let layout = try StorageLayout(metadata: metadata)
			let state = try StorageState(metadata: metadata, layout: layout, destination: destination, stateDirectory: stateDirectory, selected: selected, coordinator: coordinator, anchoredState: preparedState?.anchor, checkpointPolicy: checkpointPolicy, checkpointClock: checkpointClock, event: event, check: cancellation.check)
			try cancellation.check(); return state
		}
		return TorrentStorage(state: state, worker: worker, clock: checkpointClock)
	}
	public func snapshot() async throws -> StorageSnapshot { try await worker.run { [state] _ in try state.snapshot() } }
	public func read(piece: Int, offset: Int, count: Int, verifiedOnly: Bool = true) async throws -> Data {
		try await worker.run { [state] cancellation in try state.read(piece: piece, offset: offset, count: count, verifiedOnly: verifiedOnly, check: cancellation.check) }
	}
	public func write(piece: Int, offset: Int, data: Data) async throws {
		try await worker.run { [state] cancellation in try state.write(piece: piece, offset: offset, data: data, check: cancellation.check) }
	}
	/// Returns one immutable, hash-checked piece, bounded by the layout's 16 MiB limit.
	public func readVerifiedPiece(_ piece: Int) async throws -> Data {
		try await worker.run { [state] cancellation in try state.verifiedPiece(piece, check: cancellation.check) }
	}
	@discardableResult public func verify(piece: Int) async throws -> Bool {
		let result = try await worker.run { [state] cancellation in
			let valid = try state.verify(piece: piece, check: cancellation.check); return (valid, state.checkpointDeadline)
		}
		armCheckpointTimer(result.1); return result.0
	}
	public func checkpoint(downloaded: Int64, uploaded: Int64, corruptBytes: Int64? = nil, redundantBytes: Int64? = nil) async throws {
		let deadline = checkpointTimerDeadline
		await drainCheckpointTimer()
		do { try await worker.run { [state] cancellation in
			try state.ready(allowCheckpointRetry: true); try cancellation.check()
			let corrupt = corruptBytes ?? state.record.corruptBytes ?? 0, redundant = redundantBytes ?? state.record.redundantBytes ?? 0
			guard downloaded >= 0, uploaded >= 0, corrupt >= 0, redundant >= 0, corrupt <= downloaded, redundant <= downloaded - corrupt else { throw StorageFailure.invalid("payload counters") }
			state.record.corruptBytes = corrupt; state.record.redundantBytes = redundant
			state.record.downloaded = downloaded; state.record.uploaded = uploaded; try state.save()
		} } catch { armCheckpointTimer(deadline); throw error }
	}
	public func shutdown() async throws {
		closing = true; await drainCheckpointTimer()
		do { try await worker.run { [state] _ in
			if state.closed { return }
			guard !state.hasJournal else { throw StorageFailure.recoveryRequired("a filesystem operation is pending") }
			try state.save(); state.closed = true; state.coordinator.release(state.owner); state.lease.release()
		}; shutdownCompleted = true } catch { closing = shutdownCompleted; throw error }
	}
	deinit { checkpointTimer?.cancel() }
}

// Access is confined to the session's serial disk worker after initialisation.
final class StorageState: @unchecked Sendable {
	let metadata: TorrentMetadata
	let layout: StorageLayout
	let state: StorageDirectory
	var payload: StorageDirectory
	var record: StorageCheckpoint
	var merkle: MerkleCatalog
	let coordinator: StorageCoordinator
	let owner = UUID()
	let event: @Sendable (StorageEvent) -> Void
	let lease: StorageLease
	var closed = false
	var hasJournal = false
	var pendingFlush: Set<Int> = []
	let checkpointPolicy: StorageCheckpointPolicy
	let checkpointClock: any StorageCheckpointClock
	var committedVerified: Data
	var pendingVerified: Data
	var recoveryChecked: Data
	var pendingVerifiedBytes: Int64 = 0
	var pendingSince: TimeInterval?
	let checkpointFailures = StorageCheckpointFailures()
	var checkpointError: (any Error)? {
		get { checkpointFailures.error }
		set { checkpointFailures.set(newValue) }
	}
	init(metadata: TorrentMetadata, layout: StorageLayout, destination: URL, stateDirectory: URL, selected: [Bool]?, coordinator: StorageCoordinator, anchoredState: StorageDirectory? = nil,
		checkpointPolicy: StorageCheckpointPolicy = .immediate, checkpointClock: any StorageCheckpointClock = ContinuousStorageCheckpointClock(), event: @escaping @Sendable (StorageEvent) -> Void, check: () throws -> Void) throws {
		self.metadata = metadata; self.layout = layout; self.coordinator = coordinator; self.event = event
		try checkpointPolicy.validate(); self.checkpointPolicy = checkpointPolicy; self.checkpointClock = checkpointClock
		committedVerified = Data(repeating: 0, count: (layout.pieceCount + 7) / 8); pendingVerified = committedVerified; recoveryChecked = committedVerified
		merkle = try MerkleCatalog(metadata: metadata)
		state = try anchoredState ?? StorageDirectory(stateDirectory)
		lease = try StorageLease(directory: state)
		do {
			let identity = Data(SHA256.hash(data: metadata.originalInfo))
			if try state.inspect("checkpoint.plist") != nil {
				record = try PropertyListDecoder().decode(StorageCheckpoint.self, from: state.read("checkpoint.plist", maximum: 16_777_216))
				try record.validate(layout: layout, identity: identity)
				committedVerified = record.verified
			} else {
				let selection = selected ?? layout.files.map { !$0.pad }
				guard selection.count == layout.files.count else { throw StorageFailure.invalid("selection count") }
				record = StorageCheckpoint(metadataHash: identity, destination: destination.standardizedFileURL.resolvingSymlinksInPath().path,
					paths: layout.files.map(\.path), selected: selection.enumerated().map { $0.element && !layout.files[$0.offset].pad },
					spilled: selection.enumerated().map { !$0.element && !layout.files[$0.offset].pad }, stamps: Array(repeating: nil, count: layout.files.count),
					verified: Data(repeating: 0, count: (layout.pieceCount + 7) / 8))
				try record.validate(layout: layout, identity: identity)
			}
			payload = try StorageDirectory(URL(fileURLWithPath: record.destination))
			try StorageLayout.validateIsolation(destination: payload.url, paths: record.paths, state: state.url)
			if try state.inspect("metadata.torrent") != nil {
				let stored = try TorrentMetadata(state.read("metadata.torrent", maximum: 33_554_432))
				guard stored.originalInfo == metadata.originalInfo else { throw StorageFailure.invalid("saved metadata identity") }
			} else { try state.atomic(metadata.document.original, path: "metadata.torrent") }
		} catch { throw error }
		do {
			try claim()
			try restoreHashes()
			// Reopened files may contain externally written bytes awaiting durability.
			pendingFlush = Set(layout.files.indices.filter { !layout.files[$0].pad })
			hasJournal = try state.inspect("operation.plist") != nil
			if !hasJournal {
				try prepareEmptyFiles()
				// Stamps are hints: coarse filesystems can conceal same-size edits.
				let cached = (0..<layout.pieceCount).filter { record.contains($0) }
				record.verified = Data(repeating: 0, count: record.verified.count)
				for piece in cached {
					try check()
					let before = try invalidateChangedFiles()
					do { record.set(piece, try checkedPiece(piece, before: before, check: check).valid) }
					catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { }
					catch StorageFailure.invalid("short payload read") { }
					catch StorageFailure.missingHashes { }
				}
				try save()
			}
		} catch { coordinator.release(owner); throw error }
	}
	deinit { coordinator.release(owner) }
	func claim(extra: [URL] = []) throws {
		let paths = record.paths.indices.filter { !layout.files[$0].pad }.map { location($0).0.url.appendingPathComponent(location($0).1) }
		try coordinator.claim(owner, paths: [state.url] + paths + extra)
	}
	func ready(allowCheckpointRetry: Bool = false) throws {
		guard !closed else { throw StorageFailure.closed }
		guard !hasJournal else { throw StorageFailure.recoveryRequired("a filesystem operation is pending") }
		if !allowCheckpointRetry, let checkpointError { throw checkpointError }
	}
	func prepareEmptyFiles() throws {
		for index in layout.files.indices where layout.files[index].size == 0 && record.selected[index] {
			if try payload.inspect(record.paths[index]) == nil {
				let file = try payload.openFile(record.paths[index], write: true); close(file); pendingFlush.insert(index)
			}
		}
	}
	func location(_ index: Int) -> (StorageDirectory, String) {
		record.spilled[index] ? (state, "unwanted/\(index)") : (payload, record.paths[index])
	}
	func stamps() throws -> [FileStamp?] {
		let scan = StorageStampScan()
		return try record.paths.indices.map { index in
			if layout.files[index].pad { return nil }
			let (directory, path) = location(index); return try scan.inspect(path, in: directory)
		}
	}
	@discardableResult func invalidateChangedFiles() throws -> [FileStamp?] {
		let current = try stamps()
		let changed = Set(current.indices.filter { current[$0] != record.stamps[$0] })
		guard !changed.isEmpty else { return current }
		for index in changed where !layout.files[index].pad {
			for piece in try layout.pieces(touchingFile: index) { record.set(piece, false) }
		}
		record.stamps = current
		return current
	}
	func save() throws {
		do {
			// Flush payload before publishing any progress record.
			for index in pendingFlush.sorted() {
				let (directory, path) = location(index)
				if try directory.inspect(path) != nil {
					let file = try directory.openFile(path); defer { close(file) }
					try directory.sync(file); try directory.parent(path) { parent, _ in try directory.sync(parent) }
					event(.payloadFlushed(index))
				}
			}
			try invalidateChangedFiles(); record.generation &+= 1
			try state.atomic(record.encoded(), path: "checkpoint.plist")
			committedVerified = record.verified; pendingFlush.removeAll()
			pendingVerified.resetBytes(in: 0..<pendingVerified.count); pendingVerifiedBytes = 0; pendingSince = nil; checkpointError = nil
			event(.progressCheckpointDurable)
		} catch { if case .batched = checkpointPolicy { checkpointError = error }; throw error }
	}
	func requireFlush(piece: Int) throws {
		let length = try layout.length(of: piece)
		for offset in stride(from: 0, to: length, by: 1_048_576) {
			for segment in try layout.segments(piece: piece, offset: offset, count: min(1_048_576, length - offset)) where !segment.padding {
				pendingFlush.insert(segment.file)
			}
		}
	}
	func snapshot() throws -> StorageSnapshot {
		guard !closed else { throw StorageFailure.closed }
		if let checkpointError { throw checkpointError }
		if !hasJournal { try invalidateChangedFiles() }
		return StorageSnapshot(hasExistingPayload: record.stamps.contains { ($0?.size ?? 0) > 0 }, destination: payload.url, paths: record.paths, selected: record.selected,
			verifiedPieces: hasJournal ? [] : Set((0..<layout.pieceCount).filter { record.contains($0) }), downloaded: record.downloaded, uploaded: record.uploaded,
			corruptBytes: record.corruptBytes ?? 0, redundantBytes: record.redundantBytes ?? 0,
			trashReceipts: record.receipts.map { URL(fileURLWithPath: $0) }, needsRecovery: hasJournal)
	}
	func read(piece: Int, offset: Int, count: Int, verifiedOnly: Bool, check: () throws -> Void) throws -> Data {
		try ready()
		_ = try layout.length(of: piece)
		let before: [FileStamp?]?
		if verifiedOnly { before = try invalidateChangedFiles(); guard record.contains(piece) else { throw StorageFailure.invalid("piece has not been verified") } }
		else { before = nil }
		let segments = try layout.segments(piece: piece, offset: offset, count: count)
		if let before {
			do {
				let checked = try checkedPiece(piece, range: offset..<(offset + count), before: before, check: check)
				guard checked.valid else { throw StorageFailure.invalid("verified payload failed its hash") }
				return checked.bytes
			} catch { record.set(piece, false); throw error }
		}
		var result = Data()
		for segment in segments {
			try check()
			if segment.padding { result.append(Data(repeating: 0, count: segment.count)); continue }
			let (directory, path) = location(segment.file), file = try directory.openFile(path)
			defer { close(file) }
			var done = 0
			while done < segment.count {
				try check(); let data = try StorageDirectory.read(file, offset: segment.offset + Int64(done), count: min(65536, segment.count - done))
				guard !data.isEmpty else { throw StorageFailure.invalid("short payload read") }; done += data.count; result.append(data)
			}
		}
		return result
	}
	func write(piece: Int, offset: Int, data: Data, check: () throws -> Void) throws {
		try writeOperations([StorageWrite(piece: piece, offset: offset, data: data)], maximumBytes: 1_048_576, maximumCount: 1, check: check)
	}

	func verify(piece: Int, check: () throws -> Void) throws -> Bool {
		try ready()
		_ = try layout.length(of: piece)
		let before = try invalidateChangedFiles()
		try prepareVerification(of: piece)
		let wasVerified = record.contains(piece); record.set(piece, false)
		let valid = try checkedPiece(piece, before: before, check: check).valid
		if valid { try requireFlush(piece: piece) }
		record.set(piece, valid)
		if case .immediate = checkpointPolicy {
			do { try save() } catch { record.set(piece, false); throw error }
		} else if valid && !wasVerified { try newlyVerified(piece) }
		return valid
	}
	func verifiedPiece(_ piece: Int, check: () throws -> Void) throws -> Data {
		try ready(); let length = try layout.length(of: piece), before = try invalidateChangedFiles()
		guard record.contains(piece) else { throw StorageFailure.invalid("piece has not been verified") }
		do {
			let result = try checkedPiece(piece, range: 0..<length, before: before, check: check)
			guard result.valid else { throw StorageFailure.invalid("verified payload failed its hash") }; return result.bytes
		} catch { record.set(piece, false); throw error }
	}
	private func checkedPiece(_ piece: Int, range: Range<Int>? = nil, before: [FileStamp?], check: () throws -> Void) throws -> (valid: Bool, bytes: Data) {
		let expected = merkle.expected(piece)
		if merkle.index.enabled && expected == nil { throw StorageFailure.missingHashes }
		// The invalidation scan is also the verification baseline. Keep it across
		// checkpoint work so replacements in that interval cannot escape detection.
		let result = try digestPiece(piece, range: range, check: check)
		guard try stamps() == before else { throw StorageFailure.invalid("payload changed during verification") }
		return (result.legacyValid && result.root == expected, result.bytes)
	}
	func digestPiece(_ piece: Int, range: Range<Int>? = nil, check: () throws -> Void) throws -> (legacyValid: Bool, root: Data?, bytes: Data) {
		let length = try layout.length(of: piece)
		let hashes = metadata.document.root["info"]?["pieces"]?.bytes
		let mapping = merkle.index.pieces[piece]
		var hash = Insecure.SHA1(), offset = 0, result = Data(), leaves: [Data] = []
		while offset < length {
			try check(); let count = min(65536, length - offset)
			let data = try read(piece: piece, offset: offset, count: count, verifiedOnly: false, check: check)
			hash.update(data: data)
			if let mapping {
				for block in stride(from: offset, to: min(offset + count, mapping.length), by: 16384) {
					let end = min(block + 16384, mapping.length)
					leaves.append(Data(SHA256.hash(data: data.subdata(in: (block - offset)..<(end - offset)))))
				}
			}
			if let range {
				let lower = max(offset, range.lowerBound), upper = min(offset + count, range.upperBound)
				if lower < upper { result.append(data.subdata(in: (lower - offset)..<(upper - offset))) }
			}
			offset += count
		}
		let valid = hashes.map { Data(hash.finalize()) == $0.subdata(in: (piece * 20)..<(piece * 20 + 20)) } ?? true
		var root: Data?
		if let mapping, let file = merkle.index.files[mapping.root] {
			leaves += Array(repeating: Data(repeating: 0, count: 32), count: (1 << file.base) - leaves.count)
			root = try MerkleMath.root(leaves)
		}
		return (valid, root, result)
	}
}
