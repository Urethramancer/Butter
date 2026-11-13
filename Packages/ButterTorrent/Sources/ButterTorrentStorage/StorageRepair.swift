import Foundation
import Darwin

/// StorageRepairResult reports published files and the affected piece outcomes.
public struct StorageRepairResult: Codable, Sendable {
	public let repairedFiles: Int
	public let verifiedPieces: Int
	public let pendingPieces: Int
}

struct StorageRepairEntry: Codable {
	let index: Int
	let root: String
	let path: String
	let rootStamp: FileStamp
	let temporary: String
	let backup: String
	let original: FileStamp?
	let originalHash: Data?
	let staged: FileStamp
	let digest: Data
	var published: FileStamp?
}

extension TorrentStorage {
	/// Replaces one managed file using verified staged bytes, retaining the source.
	public func repairFile(_ index: Int, from source: URL) async throws -> StorageRepairResult {
		try await flush()
		return try await worker.run(bulk: true) { [state] cancellation in
			try state.repairFiles([index: source], check: cancellation.check)
		}
	}
}

extension StorageState {
	func needsRepair(_ index: Int) throws -> Bool {
		try layout.pieces(touchingFile: index).contains { !record.contains($0) } || record.stamps[index]?.size != layout.files[index].size
	}
	func repairFiles(_ sources: [Int: URL], check: () throws -> Void) throws -> StorageRepairResult {
		try ready(); try check(); try invalidateChangedFiles()
		guard !sources.isEmpty else { throw StorageFailure.invalid("no matching files to repair") }
		let managed = Set(layout.files.indices.filter { !layout.files[$0].pad }.map { index in
			let (directory, path) = location(index); return StorageLayout.pathKey(directory.url.appendingPathComponent(path).path)
		})
		var candidates: [(Int, URL, FileStamp, FileStamp)] = []
		for index in sources.keys.sorted() {
			guard layout.files.indices.contains(index), !layout.files[index].pad else { throw StorageFailure.invalid("repair file index") }
			let url = sources[index]!
			guard url.isFileURL, url.path.hasPrefix("/") else { throw StorageFailure.invalid("absolute repair source") }
			let source = try StorageDirectory(url.deletingLastPathComponent(), create: false), path = url.lastPathComponent
			guard let stamp = try source.inspect(path), stamp.size == layout.files[index].size else { throw StorageFailure.invalid("repair source length for \(layout.files[index].path)") }
			let key = StorageLayout.pathKey(source.url.appendingPathComponent(path).path), stateKey = StorageLayout.pathKey(state.url.path)
			guard !managed.contains(key), key != stateKey, !key.hasPrefix(stateKey + "/") else { throw StorageFailure.invalid("repair source overlaps managed storage; choose a separate copy") }
			if try needsRepair(index) { candidates.append((index, source.url.appendingPathComponent(path), stamp, try source.identity())) }
		}
		if candidates.isEmpty { return StorageRepairResult(repairedFiles: 0, verifiedPieces: 0, pendingPieces: 0) }
		try claim(extra: candidates.map { $0.1 })
		var entries: [StorageRepairEntry] = [], temporaryFiles: [(StorageDirectory, String, FileStamp)] = []
		defer { if !hasJournal { try? claim() } }
		do {
			for (index, url, original, sourceRoot) in candidates {
				try check()
				let source = try StorageDirectory(url.deletingLastPathComponent(), create: false), path = url.lastPathComponent
				guard try source.identity().sameFile(sourceRoot) else { throw StorageFailure.invalid("repair source directory changed before copying") }
				let (target, destination) = location(index)
				let parent = (destination as NSString).deletingLastPathComponent
				let prefix = parent.isEmpty ? "" : parent + "/", token = UUID().uuidString
				let temporary = prefix + ".butter-repair-" + token, backup = prefix + ".butter-backup-" + token
				let old = try target.inspect(destination)
				let oldHash = try old.map { _ in try target.digest(destination, check: check) }
				let input = try source.openFile(path)
				defer { close(input) }
				guard try source.stamp(input) == original else { throw StorageFailure.invalid("repair source changed before copying") }
				let output = try target.openFile(temporary, write: true, exclusive: true)
				defer { close(output) }
				temporaryFiles.append((target, temporary, try target.stamp(output)))
				var offset: Int64 = 0
				while offset < original.size {
					try check()
					let bytes = try StorageDirectory.read(input, offset: offset, count: Int(min(65536, original.size - offset)))
					guard !bytes.isEmpty else { throw StorageFailure.invalid("repair source shortened") }
					try StorageDirectory.write(bytes, to: output, offset: offset, check: check); offset += Int64(bytes.count)
				}
				try target.sync(output); try target.parent(temporary) { parent, _ in try target.sync(parent) }
				guard try source.stamp(input) == original, try source.inspect(path) == original,
					try StorageDirectory(source.url, create: false).identity().sameFile(sourceRoot) else { throw StorageFailure.invalid("repair source changed during copying") }
				let staged = try target.checkedDigest(temporary, check: check)
				guard try target.inspect(temporary) == staged.stamp, try target.inspect(destination) == old else { throw StorageFailure.invalid("repair destination changed during staging") }
				entries.append(StorageRepairEntry(index: index, root: target.url.path, path: destination, rootStamp: try target.identity(), temporary: temporary, backup: backup,
					original: old, originalHash: oldHash, staged: staged.stamp, digest: staged.hash))
				event(.repairStaged(index))
			}
			let affected = try Set(entries.flatMap { try layout.pieces(touchingFile: $0.index) })
			let baseline = try stamps()
			let overlay = Dictionary(uniqueKeysWithValues: entries.map { entry in (entry.index, (location(entry.index).0, entry.temporary)) })
			var after = record
			for piece in affected.sorted() {
				try check()
				var available = true
				let length = try layout.length(of: piece)
				for offset in stride(from: 0, to: length, by: 1_048_576) {
					for segment in try layout.segments(piece: piece, offset: offset, count: min(1_048_576, length - offset)) where !segment.padding {
						let (directory, path) = overlay[segment.file] ?? location(segment.file)
						if (try directory.inspect(path)?.size ?? -1) < segment.offset + Int64(segment.count) { available = false }
					}
				}
				var valid = false
				if available {
					let digest = try digestPiece(piece, overlay: overlay, check: check), expected = merkle.expected(piece)
					guard digest.legacyValid, expected == nil || digest.root == expected else { throw StorageFailure.invalid("repair data fails piece \(piece); no files were replaced") }
					valid = !merkle.index.enabled || expected != nil
				}
				guard !record.contains(piece) || valid else { throw StorageFailure.invalid("repair would lose verified piece \(piece)") }
				after.set(piece, valid)
			}
			guard try stamps() == baseline else { throw StorageFailure.invalid("payload changed during repair verification") }
			for entry in entries {
				let target = location(entry.index).0
				guard try target.inspect(entry.temporary) == entry.staged, try target.inspect(entry.path) == entry.original else { throw StorageFailure.invalid("repair files changed during verification") }
			}
			var journal = StorageJournal(before: record, after: after, entries: [])
			journal.version = 2; journal.repairs = entries
			try journal.validate(layout: layout, identity: record.metadataHash); try check()
			do { try persist(journal) }
			catch {
				// Atomic publication may have succeeded before its directory flush failed.
				do { hasJournal = try state.inspect("operation.plist") != nil } catch { hasJournal = true }
				throw error
			}
			hasJournal = true; event(.journalDurable)
			try recoverRepair(&journal, check: check)
			return StorageRepairResult(repairedFiles: entries.count, verifiedPieces: affected.filter(record.contains).count, pendingPieces: affected.filter { !record.contains($0) }.count)
		} catch {
			if !hasJournal {
				for (directory, path, owned) in temporaryFiles {
					if let current = try directory.inspect(path), current.sameFile(owned) { try directory.remove(path, expected: current) }
				}
			}
			throw error
		}
	}

	func recoverRepair(_ journal: inout StorageJournal, check: () throws -> Void) throws {
		guard var entries = journal.repairs else { throw StorageFailure.invalid("missing repair journal entries") }
		let affected = try Set(entries.flatMap { try layout.pieces(touchingFile: $0.index) })
		for entry in entries {
			let (directory, path) = location(entry.index)
			guard directory.url.path == entry.root, path == entry.path else { throw StorageFailure.recoveryRequired("repair destination mapping changed") }
		}
		try claim(extra: entries.flatMap { entry in [entry.temporary, entry.backup].map { URL(fileURLWithPath: entry.root).appendingPathComponent($0) } })
		// Invalidation is durable before any existing destination is claimed.
		for piece in affected { record.set(piece, false) }
		try save()
		for index in entries.indices {
			try check(); var entry = entries[index]
			let target = try StorageDirectory(URL(fileURLWithPath: entry.root), create: false)
			guard try target.identity().sameFile(entry.rootStamp) else { throw StorageFailure.recoveryRequired("repair destination root was replaced") }
			if let current = try target.inspect(entry.path), current.sameFile(entry.staged) {
				entry.published = try checkedRepairFile(target, path: entry.path, owned: entry.staged, digest: entry.digest, check: check)
			} else {
				if let original = entry.original, let digest = entry.originalHash {
					guard try target.claimFile(entry.path, as: entry.backup, expected: original, digest: digest, check: check) != nil else { throw StorageFailure.recoveryRequired("repair original and backup are missing") }
					event(.repairBackup(entry.index))
				} else if try target.inspect(entry.path) != nil || target.inspect(entry.backup) != nil { throw StorageFailure.recoveryRequired("repair destination has conflicting files") }
				_ = try checkedRepairFile(target, path: entry.temporary, owned: entry.staged, digest: entry.digest, check: check)
				try target.rename(entry.temporary, to: target, path: entry.path); event(.filePublished(entry.index))
				entry.published = try checkedRepairFile(target, path: entry.path, owned: entry.staged, digest: entry.digest, check: check)
			}
			entries[index] = entry; journal.repairs = entries; try persist(journal); event(.entryDurable(entry.index))
		}
		var after = journal.after; after.generation = max(record.generation, after.generation)
		record = after
		for entry in entries { record.stamps[entry.index] = entry.published; pendingFlush.insert(entry.index) }
		try save(); event(.checkpointDurable)
		for entry in entries {
			try check()
			let target = try StorageDirectory(URL(fileURLWithPath: entry.root), create: false)
			_ = try checkedRepairFile(target, path: entry.path, owned: entry.staged, digest: entry.digest, check: check)
			if let original = entry.original, let digest = entry.originalHash, try target.inspect(entry.backup) != nil {
				let backup = try checkedRepairFile(target, path: entry.backup, owned: original, digest: digest, check: check)
				try target.remove(entry.backup, expected: backup)
			}
		}
		guard let operation = try state.inspect("operation.plist") else { throw StorageFailure.recoveryRequired("repair journal is missing") }
		try state.remove("operation.plist", expected: operation); hasJournal = false
		for piece in affected { finishVerificationAttempt(piece, pending: !record.contains(piece)) }
		try claim()
	}
	private func checkedRepairFile(_ directory: StorageDirectory, path: String, owned: FileStamp, digest: Data, check: () throws -> Void) throws -> FileStamp {
		guard let current = try directory.inspect(path), current.sameFile(owned) else { throw StorageFailure.recoveryRequired("repair file is missing or replaced; retain the journal and backup files") }
		let checked = try directory.checkedDigest(path, check: check)
		guard checked.stamp.sameFile(owned), checked.hash == digest, try directory.inspect(path) == checked.stamp else { throw StorageFailure.recoveryRequired("repair file identity or contents changed") }
		return checked.stamp
	}
}
