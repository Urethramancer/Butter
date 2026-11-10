import Foundation
import Darwin

public enum StorageEvent: Sendable, Equatable {
	case journalDurable
	case filePublished(Int)
	case entryDurable(Int)
	case checkpointDurable
	case sourceRemoved(Int)
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
	}
	var version = 1
	let before: StorageCheckpoint
	var after: StorageCheckpoint
	var entries: [Entry]
	func validate(layout: StorageLayout, identity: Data) throws {
		guard version == 1, entries.count <= layout.files.count else { throw StorageFailure.invalid("operation journal version or count") }
		try before.validate(layout: layout, identity: identity); try after.validate(layout: layout, identity: identity)
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
		guard !closed else { throw StorageFailure.closed }
		guard hasJournal else { return }
		var journal = try PropertyListDecoder().decode(StorageJournal.self, from: state.read("operation.plist", maximum: 33_554_432))
		try journal.validate(layout: layout, identity: record.metadataHash)
		try claim(extra: futurePaths(journal.after) + journal.entries.flatMap { [URL(fileURLWithPath: $0.sourceRoot).appendingPathComponent($0.source), URL(fileURLWithPath: $0.destinationRoot).appendingPathComponent($0.destination)] })
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
					guard existing.sameFile(entry.original), try source.inspect(entry.source) == nil else { throw StorageFailure.recoveryRequired("rename has conflicting files") }
				} else {
					guard acceptMatchingCopies else { throw StorageFailure.recoveryRequired("copy was published before its receipt; review both paths, then explicitly accept matching copies") }
				}
				guard try target.digest(entry.destination, check: check) == entry.digest else { throw StorageFailure.recoveryRequired("destination content changed") }
				entry.published = existing
			} else {
				guard entry.published == nil else { throw StorageFailure.recoveryRequired("published destination is missing") }
				guard let existing = try source.inspect(entry.source), existing == entry.original,
					try source.digest(entry.source, check: check) == entry.digest else { throw StorageFailure.recoveryRequired("source changed before operation") }
				if entry.copy {
					try copy(&entry, source: source, target: target, journal: &journal, index: index, check: check)
				} else { try source.rename(entry.source, to: target, path: entry.destination) }
				event(.filePublished(entry.index))
				guard try target.digest(entry.destination, check: check) == entry.digest else { throw StorageFailure.recoveryRequired("published bytes changed") }
				entry.published = try target.inspect(entry.destination)
			}
			journal.entries[index] = entry; try persist(journal); event(.entryDurable(entry.index))
		}
		try check()
		record = journal.after
		payload = try StorageDirectory(URL(fileURLWithPath: record.destination), create: false)
		try prepareEmptyFiles()
		record.stamps = try stamps(); try save(); event(.checkpointDurable)
		for entry in journal.entries where entry.copy && entry.removeSource {
			try check()
			let source = try StorageDirectory(URL(fileURLWithPath: entry.sourceRoot), create: false)
			if let current = try source.inspect(entry.source) {
				guard current == entry.original, try source.digest(entry.source, check: check) == entry.digest else { throw StorageFailure.recoveryRequired("source copy changed; it was retained") }
				try source.remove(entry.source, expected: entry.original); event(.sourceRemoved(entry.index))
			}
		}
		guard let operation = try state.inspect("operation.plist") else { throw StorageFailure.invalid("missing operation journal") }
		try state.remove("operation.plist", expected: operation)
		hasJournal = false; try claim()
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
