import Foundation
import Darwin

public enum StorageEvent: Sendable, Equatable {
	case pieceHashed(Int)
	case repairStaged(Int)
	case repairBackup(Int)
	case journalDurable
	case filePublished(Int)
	case entryDurable(Int)
	case checkpointDurable
	case sourceRemoved(Int)
	case sourceWillBeClaimed(Int)
	case sourceClaimed(Int)
	case pieceLayersChanged
	case payloadFlushed(Int)
	case progressCheckpointDurable
}

struct StorageJournal: Codable {
	struct Entry: Codable {
		let index: Int
		let sourceRoot: String
		let source: String
		let destinationRoot: String
		let destination: String
		let sourceDirectory: FileStamp
		let targetDirectory: FileStamp
		let original: FileStamp
		let digest: Data
		let copy: Bool
		let removeSource: Bool
		let temporary: String
		var temporaryStamp: FileStamp?
		var published: FileStamp?
		// The existing durable temporary name also identifies interrupted source cleanup.
		var claimedSource: String {
			let parent = (source as NSString).deletingLastPathComponent
			let name = ".butter-source-" + String((temporary as NSString).lastPathComponent.dropFirst(".butter-copy-".count))
			return parent.isEmpty ? name : parent + "/" + name
		}
	}
	var version = 1
	let before: StorageCheckpoint
	var after: StorageCheckpoint
	var entries: [Entry]
	var repairs: [StorageRepairEntry]?
	func validate(layout: StorageLayout, identity: Data) throws {
		guard (version == 1 && repairs == nil) || (version == 2 && repairs != nil && entries.isEmpty), entries.count <= layout.files.count else { throw StorageFailure.invalid("operation journal version or count") }
		try before.validate(layout: layout, identity: identity); try after.validate(layout: layout, identity: identity)
		if let repairs {
			guard !repairs.isEmpty, repairs.count <= layout.files.count, before.paths == after.paths, before.destination == after.destination,
				before.selected == after.selected, before.spilled == after.spilled else { throw StorageFailure.invalid("repair journal mapping") }
			var indices: Set<Int> = [], paths: Set<String> = []
			for entry in repairs {
				guard layout.files.indices.contains(entry.index), !layout.files[entry.index].pad, indices.insert(entry.index).inserted,
					entry.root.hasPrefix("/"), !entry.root.utf8.contains(0), entry.digest.count == 32, entry.staged.size == layout.files[entry.index].size,
					(entry.original == nil && entry.originalHash == nil) || (entry.original != nil && entry.originalHash?.count == 32) else { throw StorageFailure.invalid("repair journal entry") }
				for path in [entry.path, entry.temporary, entry.backup] {
					_ = try StorageLayout.components(path)
					guard paths.insert(StorageLayout.pathKey(entry.root + "/" + path)).inserted else { throw StorageFailure.invalid("duplicate repair path") }
				}
				guard (entry.temporary as NSString).deletingLastPathComponent == (entry.path as NSString).deletingLastPathComponent,
					(entry.backup as NSString).deletingLastPathComponent == (entry.path as NSString).deletingLastPathComponent,
					(entry.temporary as NSString).lastPathComponent.hasPrefix(".butter-repair-"),
					(entry.backup as NSString).lastPathComponent.hasPrefix(".butter-backup-") else { throw StorageFailure.invalid("repair staging paths") }
			}
			return
		}
		var indices: Set<Int> = []
		for entry in entries {
			guard layout.files.indices.contains(entry.index), !layout.files[entry.index].pad, indices.insert(entry.index).inserted,
				entry.sourceRoot.hasPrefix("/"), entry.destinationRoot.hasPrefix("/"), !entry.sourceRoot.utf8.contains(0), !entry.destinationRoot.utf8.contains(0),
				entry.digest.count == 32, entry.original.size >= 0 else { throw StorageFailure.invalid("operation journal entry") }
			for path in [entry.source, entry.destination, entry.temporary] { _ = try StorageLayout.components(path) }
			guard URL(fileURLWithPath: entry.temporary).lastPathComponent.hasPrefix(".butter-copy-") else { throw StorageFailure.invalid("operation temporary path") }
		}
	}
	func encoded() throws -> Data {
		let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
		let data = try encoder.encode(self)
		guard data.count <= 33_554_432 else { throw StorageFailure.limit("operation journal bytes") }; return data
	}
}

extension StorageState {
	func persist(_ journal: StorageJournal) throws { try state.atomic(journal.encoded(), path: "operation.plist") }
	func perform(after: StorageCheckpoint, entries: [StorageJournal.Entry], check: () throws -> Void) throws {
		try ready(); try check()
		try save()
		try invalidateChangedFiles()
		var after = after
		for index in after.verified.indices { after.verified[index] &= record.verified[index] }
		let journal = StorageJournal(before: record, after: after, entries: entries)
		try journal.validate(layout: layout, identity: record.metadataHash)
		try claim(extra: futurePaths(after) + entries.map { URL(fileURLWithPath: $0.destinationRoot).appendingPathComponent($0.destination) })
		do { try persist(journal) } catch { try? claim(); throw error }
		hasJournal = true; event(.journalDurable)
		try recover(acceptMatchingCopies: false, check: check)
	}
	func recover(acceptMatchingCopies: Bool, check: () throws -> Void) throws {
		writeDescriptors.removeAll(profile: writeProfile)
		guard !closed else { throw StorageFailure.closed }
		guard hasJournal else { return }
		var journal = try PropertyListDecoder().decode(StorageJournal.self, from: state.read("operation.plist", maximum: 33_554_432))
		try journal.validate(layout: layout, identity: record.metadataHash)
		if journal.version == 2 { try recoverRepair(&journal, check: check); return }
		try claim(extra: futurePaths(journal.after) + journal.entries.flatMap {
			[URL(fileURLWithPath: $0.sourceRoot).appendingPathComponent($0.source),
			 URL(fileURLWithPath: $0.sourceRoot).appendingPathComponent($0.claimedSource),
			 URL(fileURLWithPath: $0.destinationRoot).appendingPathComponent($0.destination)]
		})
		for index in journal.entries.indices {
			try check()
			var entry = journal.entries[index]
			let source = try StorageDirectory(URL(fileURLWithPath: entry.sourceRoot), create: false)
			let target = try StorageDirectory(URL(fileURLWithPath: entry.destinationRoot), create: false)
			guard try source.identity().sameFile(entry.sourceDirectory), try target.identity().sameFile(entry.targetDirectory) else { throw StorageFailure.recoveryRequired("an operation root was replaced") }
			if let existing = try target.inspect(entry.destination) {
				if let published = entry.published {
					guard existing.sameFile(published) else { throw StorageFailure.recoveryRequired("published destination was replaced") }
				} else if !entry.copy {
					guard existing.sameFile(entry.original) else { throw StorageFailure.recoveryRequired("rename has conflicting files") }
				} else {
					guard acceptMatchingCopies else { throw StorageFailure.recoveryRequired("copy was published before its receipt; review both paths, then explicitly accept matching copies") }
				}
				let checked = try target.checkedDigest(entry.destination, check: check)
				guard checked.hash == entry.digest else { throw StorageFailure.recoveryRequired("destination content changed") }
				entry.published = checked.stamp
			} else {
				guard entry.published == nil else { throw StorageFailure.recoveryRequired("published destination is missing") }
				if entry.copy {
					guard let existing = try source.inspect(entry.source), existing == entry.original,
						try source.digest(entry.source, check: check) == entry.digest else { throw StorageFailure.recoveryRequired("source changed before operation") }
					try copy(&entry, source: source, target: target, journal: &journal, index: index, check: check)
				} else {
					guard try claimSource(entry, from: source, check: check) != nil else { throw StorageFailure.recoveryRequired("rename source is missing") }
					try source.rename(entry.claimedSource, to: target, path: entry.destination)
				}
				event(.filePublished(entry.index))
				let checked = try target.checkedDigest(entry.destination, check: check)
				guard checked.hash == entry.digest else { throw StorageFailure.recoveryRequired("published bytes changed") }
				entry.published = checked.stamp
			}
			journal.entries[index] = entry; try persist(journal); event(.entryDurable(entry.index))
		}
		try check()
		record = journal.after
		payload = try StorageDirectory(URL(fileURLWithPath: record.destination), create: false)
		// Bulk recovery can publish externally supplied or renamed files.
		pendingFlush.formUnion(layout.files.indices.filter { !layout.files[$0].pad })
		try prepareEmptyFiles()
		// Preserve the stamps bound to checked content, then invalidate any later edits.
		for entry in journal.entries {
			let (directory, path) = location(entry.index)
			if directory.url.path == entry.destinationRoot && path == entry.destination { record.stamps[entry.index] = entry.published }
		}
		try save(); event(.checkpointDurable)
		for entry in journal.entries where entry.copy && entry.removeSource {
			try check()
			let target = try StorageDirectory(URL(fileURLWithPath: entry.destinationRoot), create: false)
			guard let published = entry.published, try target.inspect(entry.destination) == published,
				try target.digest(entry.destination, check: check) == entry.digest else { throw StorageFailure.recoveryRequired("destination changed before source removal") }
			let source = try StorageDirectory(URL(fileURLWithPath: entry.sourceRoot), create: false)
			guard try source.identity().sameFile(entry.sourceDirectory) else { throw StorageFailure.recoveryRequired("source directory was replaced before cleanup") }
			try removeCopiedSource(entry, from: source, check: check)
		}
		guard let operation = try state.inspect("operation.plist") else { throw StorageFailure.invalid("missing operation journal") }
		try state.remove("operation.plist", expected: operation)
		hasJournal = false; try claim()
	}
	private func removeCopiedSource(_ entry: StorageJournal.Entry, from source: StorageDirectory, check: () throws -> Void) throws {
		guard let stamp = try claimSource(entry, from: source, check: check) else { return }
		try check()
		try source.remove(entry.claimedSource, expected: stamp)
		event(.sourceRemoved(entry.index))
	}
	private func claimSource(_ entry: StorageJournal.Entry, from source: StorageDirectory, check: () throws -> Void) throws -> FileStamp? {
		guard let stamp = try source.claimFile(entry.source, as: entry.claimedSource, expected: entry.original, digest: entry.digest, check: check,
			beforeClaim: { event(.sourceWillBeClaimed(entry.index)) }) else { return nil }
		event(.sourceClaimed(entry.index))
		return stamp
	}
	private func futurePaths(_ checkpoint: StorageCheckpoint) throws -> [URL] {
		let destination = URL(fileURLWithPath: checkpoint.destination)
		try StorageLayout.validateIsolation(destination: destination, paths: checkpoint.paths, state: state.url)
		return checkpoint.paths.indices.filter { !layout.files[$0].pad }.map { checkpoint.spilled[$0] ? state.url.appendingPathComponent("unwanted/\($0)") : destination.appendingPathComponent(checkpoint.paths[$0]) }
	}
	private func copy(_ entry: inout StorageJournal.Entry, source: StorageDirectory, target: StorageDirectory,
		journal: inout StorageJournal, index: Int, check: () throws -> Void) throws {
		if let leftover = try target.inspect(entry.temporary) {
			guard let expected = entry.temporaryStamp, leftover.sameFile(expected) else { throw StorageFailure.recoveryRequired("unrecorded temporary copy") }
			try target.remove(entry.temporary, expected: leftover)
		}
		let input = try source.openFile(entry.source), output = try target.openFile(entry.temporary, write: true, exclusive: true)
		defer { close(input); close(output) }
		entry.temporaryStamp = try target.stamp(output)
		journal.entries[index] = entry; try persist(journal)
		var offset: Int64 = 0
		while offset < entry.original.size {
			try check(); let bytes = try StorageDirectory.read(input, offset: offset, count: Int(min(65536, entry.original.size - offset)))
			guard !bytes.isEmpty else { throw StorageFailure.invalid("import source shortened") }
			try StorageDirectory.write(bytes, to: output, offset: offset, check: check); offset += Int64(bytes.count)
		}
		try target.sync(output)
		guard try source.stamp(input, shared: true) == entry.original,
			try target.digest(entry.temporary, check: check) == entry.digest else { throw StorageFailure.invalid("copy verification failed") }
		try target.rename(entry.temporary, to: target, path: entry.destination)
	}
}
