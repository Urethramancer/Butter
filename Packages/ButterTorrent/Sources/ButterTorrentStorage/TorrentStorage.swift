import Foundation
import Darwin
import CryptoKit
import ButterTorrentMetadata

/// TorrentStorage exposes serial, bounded disk operations without GUI dependencies.
public actor TorrentStorage {
	let worker: StorageWorker
	let state: StorageState
	public nonisolated let layout: StorageLayout
	public nonisolated let infoHashes: InfoHashes
	public nonisolated let merkleIndex: MerkleIndex
	private init(state: StorageState, worker: StorageWorker) { self.state = state; self.worker = worker; layout = state.layout; infoHashes = state.metadata.hashes; merkleIndex = state.merkle.index }
	public static func open(metadata: TorrentMetadata, destination: URL, stateDirectory: URL, selected: [Bool]? = nil,
		coordinator: StorageCoordinator = .shared, event: @escaping @Sendable (StorageEvent) -> Void = { _ in }) async throws -> TorrentStorage {
		let worker = StorageWorker()
		let state = try await worker.run { cancellation in
			let layout = try StorageLayout(metadata: metadata)
			let state = try StorageState(metadata: metadata, layout: layout, destination: destination, stateDirectory: stateDirectory, selected: selected, coordinator: coordinator, event: event, check: cancellation.check)
			try cancellation.check(); return state
		}
		return TorrentStorage(state: state, worker: worker)
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
		try await worker.run { [state] cancellation in try state.verify(piece: piece, check: cancellation.check) }
	}
	public func checkpoint(downloaded: Int64, uploaded: Int64) async throws {
		try await worker.run { [state] cancellation in
			try state.ready(); try cancellation.check()
			guard downloaded >= 0, uploaded >= 0 else { throw StorageFailure.invalid("negative counters") }
			state.record.downloaded = downloaded; state.record.uploaded = uploaded; try state.save()
		}
	}
	public func shutdown() async throws {
		try await worker.run { [state] _ in
			if state.closed { return }
			guard !state.hasJournal else { throw StorageFailure.recoveryRequired("a filesystem operation is pending") }
			try state.save(); state.closed = true; state.coordinator.release(state.owner); state.lease.release()
		}
	}
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
	init(metadata: TorrentMetadata, layout: StorageLayout, destination: URL, stateDirectory: URL, selected: [Bool]?, coordinator: StorageCoordinator, event: @escaping @Sendable (StorageEvent) -> Void, check: () throws -> Void) throws {
		self.metadata = metadata; self.layout = layout; self.coordinator = coordinator; self.event = event
		merkle = try MerkleCatalog(metadata: metadata)
		state = try StorageDirectory(stateDirectory)
		lease = try StorageLease(directory: state)
		do {
			let identity = Data(SHA256.hash(data: metadata.originalInfo))
			if try state.inspect("checkpoint.plist") != nil {
				record = try PropertyListDecoder().decode(StorageCheckpoint.self, from: state.read("checkpoint.plist", maximum: 16_777_216))
				try record.validate(layout: layout, identity: identity)
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
			hasJournal = try state.inspect("operation.plist") != nil
			if !hasJournal {
				try prepareEmptyFiles()
				// Stamps are hints: coarse filesystems can conceal same-size edits.
				let cached = (0..<layout.pieceCount).filter { record.contains($0) }
				record.verified = Data(repeating: 0, count: record.verified.count)
				for piece in cached {
					try check()
					try invalidateChangedFiles()
					do { record.set(piece, try checkedPiece(piece, check: check).valid) }
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
	func ready() throws {
		guard !closed else { throw StorageFailure.closed }
		guard !hasJournal else { throw StorageFailure.recoveryRequired("a filesystem operation is pending") }
	}
	func prepareEmptyFiles() throws {
		for index in layout.files.indices where layout.files[index].size == 0 && record.selected[index] {
			if try payload.inspect(record.paths[index]) == nil { let file = try payload.openFile(record.paths[index], write: true); close(file) }
		}
	}
	func location(_ index: Int) -> (StorageDirectory, String) {
		record.spilled[index] ? (state, "unwanted/\(index)") : (payload, record.paths[index])
	}
	func stamps() throws -> [FileStamp?] {
		try record.paths.indices.map { index in
			if layout.files[index].pad { return nil }
			let (directory, path) = location(index); return try directory.inspect(path)
		}
	}
	func invalidateChangedFiles() throws {
		let current = try stamps()
		for piece in 0..<layout.pieceCount where record.contains(piece) {
			var offset = 0
			while offset < (try layout.length(of: piece)) {
				let length = min(65536, try layout.length(of: piece) - offset)
				if try layout.segments(piece: piece, offset: offset, count: length).contains(where: { !$0.padding && (current[$0.file] == nil || current[$0.file] != record.stamps[$0.file]) }) { record.set(piece, false); break }
				offset += length
			}
		}
		record.stamps = current
	}
	func save() throws {
		// Flush payload before publishing any progress record.
		for index in record.paths.indices where !layout.files[index].pad {
			let (directory, path) = location(index)
			if try directory.inspect(path) != nil {
				let file = try directory.openFile(path); defer { close(file) }
				try directory.sync(file); try directory.parent(path) { parent, _ in try directory.sync(parent) }
			}
		}
		try invalidateChangedFiles(); record.generation &+= 1
		try state.atomic(record.encoded(), path: "checkpoint.plist")
	}
	func snapshot() throws -> StorageSnapshot {
		guard !closed else { throw StorageFailure.closed }
		if !hasJournal { try invalidateChangedFiles() }
		return StorageSnapshot(destination: payload.url, paths: record.paths, selected: record.selected,
			verifiedPieces: hasJournal ? [] : Set((0..<layout.pieceCount).filter { record.contains($0) }), downloaded: record.downloaded, uploaded: record.uploaded,
			trashReceipts: record.receipts.map { URL(fileURLWithPath: $0) }, needsRecovery: hasJournal)
	}
	func read(piece: Int, offset: Int, count: Int, verifiedOnly: Bool, check: () throws -> Void) throws -> Data {
		try ready()
		_ = try layout.length(of: piece)
		if verifiedOnly { try invalidateChangedFiles(); guard record.contains(piece) else { throw StorageFailure.invalid("piece has not been verified") } }
		let segments = try layout.segments(piece: piece, offset: offset, count: count)
		if verifiedOnly {
			do {
				let checked = try checkedPiece(piece, range: offset..<(offset + count), check: check)
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
		try ready(); try check()
		let segments = try layout.segments(piece: piece, offset: offset, count: data.count)
		try invalidateChangedFiles()
		var cursor = 0
		for segment in segments {
			if segment.padding, data[cursor..<(cursor + segment.count)].contains(where: { $0 != 0 }) { throw StorageFailure.invalid("nonzero padding") }; cursor += segment.count
		}
		// Durable invalidation precedes modifying bytes previously advertised as verified.
		if record.contains(piece) {
			record.set(piece, false)
			do { try save() } catch { record.set(piece, true); throw error }
		}
		cursor = 0
		for segment in segments {
			defer { cursor += segment.count }
			if segment.padding { continue }
			let (directory, path) = location(segment.file), file = try directory.openFile(path, write: true)
			defer { close(file) }
			try StorageDirectory.write(data.subdata(in: cursor..<(cursor + segment.count)), to: file, offset: segment.offset, check: check)
			record.stamps[segment.file] = try directory.stamp(file)
		}
	}
	func verify(piece: Int, check: () throws -> Void) throws -> Bool {
		try ready()
		_ = try layout.length(of: piece)
		try invalidateChangedFiles()
		record.set(piece, false)
		let valid = try checkedPiece(piece, check: check).valid
		record.set(piece, valid); try save(); return valid
	}
	func verifiedPiece(_ piece: Int, check: () throws -> Void) throws -> Data {
		try ready(); let length = try layout.length(of: piece); try invalidateChangedFiles()
		guard record.contains(piece) else { throw StorageFailure.invalid("piece has not been verified") }
		do {
			let result = try checkedPiece(piece, range: 0..<length, check: check)
			guard result.valid else { throw StorageFailure.invalid("verified payload failed its hash") }; return result.bytes
		} catch { record.set(piece, false); throw error }
	}
	private func checkedPiece(_ piece: Int, range: Range<Int>? = nil, check: () throws -> Void) throws -> (valid: Bool, bytes: Data) {
		let length = try layout.length(of: piece)
		let hashes = metadata.document.root["info"]?["pieces"]?.bytes
		let mapping = merkle.index.pieces[piece]
		if merkle.index.enabled && merkle.expected(piece) == nil { throw StorageFailure.missingHashes }
		let before = try stamps()
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
		guard try stamps() == before else { throw StorageFailure.invalid("payload changed during verification") }
		var valid = hashes.map { Data(hash.finalize()) == $0.subdata(in: (piece * 20)..<(piece * 20 + 20)) } ?? true
		if let mapping, let file = merkle.index.files[mapping.root] {
			leaves += Array(repeating: Data(repeating: 0, count: 32), count: (1 << file.base) - leaves.count)
			valid = try valid && MerkleMath.root(leaves) == merkle.expected(piece)
		}
		return (valid, result)
	}
}
