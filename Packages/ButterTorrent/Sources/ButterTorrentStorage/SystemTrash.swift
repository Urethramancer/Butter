import Foundation
import Darwin

extension StorageState {
	#if os(macOS)
	func trashInSystem(check: () throws -> Void) throws -> [URL] {
		if hasJournal {
			let journal = try operationJournal()
			guard journal.trashStaged != nil else { throw StorageFailure.recoveryRequired("a filesystem operation is pending") }
			try recover(acceptMatchingCopies: false, check: check)
			return record.receipts.dropFirst(journal.before.receipts.count).map { URL(fileURLWithPath: $0) }
		}

		try ready(allowCheckpointRetry: true)
		try save()
		let name = ".butter-trash-" + UUID().uuidString
		var staging: [String: (source: StorageDirectory, target: StorageDirectory)] = [:]
		var entries: [StorageJournal.Entry] = []
		defer {
			// Keep the directories if the move journal reached disk.
			if !hasJournal, (try? state.inspect("operation.plist") == nil) == true {
				for (source, target) in staging.values { try? source.removeChild(name, expected: target) }
			}
		}
		for index in record.paths.indices where !layout.files[index].pad {
			try check()
			let (source, path) = location(index)
			guard try source.inspect(path) != nil else { continue }
			let target: StorageDirectory
			if let existing = staging[source.url.path] { target = existing.target }
			else {
				target = try source.child(name, create: true)
				staging[source.url.path] = (source, target)
			}
			if let entry = try entry(index, source: source, path: path, target: target, destination: trashName(index), move: true, check: check) {
				entries.append(entry)
			}
		}
		guard !entries.isEmpty else { return [] }
		guard record.receipts.count + entries.count <= 50_000 else { throw StorageFailure.limit("Trash receipts") }
		let previous = record.receipts.count
		var after = record
		after.verified.resetBytes(in: 0..<after.verified.count)
		try perform(after: after, entries: entries, systemTrash: true, check: check)
		return record.receipts.dropFirst(previous).map { URL(fileURLWithPath: $0) }
	}
	#endif

	func finishSystemTrash(_ journal: inout StorageJournal, check: () throws -> Void) throws {
		#if os(macOS)
		// The source moves and any cross-volume copy cleanup are already durable.
		// System Trash accepts an item URL and does not expose its directory to us.
		// Resume an interrupted item first, then visit each staging directory once.
		if let index = journal.trashInFlight {
			let entry = journal.entries[index], target = try StorageDirectory(URL(fileURLWithPath: entry.destinationRoot), create: false)
			try handOff(index, in: target, journal: &journal, check: check)
		}
		for (root, indices) in Dictionary(grouping: journal.entries.indices, by: { journal.entries[$0].destinationRoot }) {
			try check()
			guard let firstIndex = indices.first else { continue }
			let first = journal.entries[firstIndex]
			let source = try StorageDirectory(URL(fileURLWithPath: first.sourceRoot), create: false)
			guard try source.identity().sameFile(first.sourceDirectory) else { throw StorageFailure.recoveryRequired("Trash staging parent was replaced") }
			let name = URL(fileURLWithPath: root).lastPathComponent
			let target: StorageDirectory
			do { target = try source.child(name) }
			catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)
				&& indices.allSatisfy({ journal.entries[$0].published == nil }) {
				// An earlier attempt may have emptied and removed this directory.
				continue
			}
			guard try target.identity().sameFile(first.targetDirectory) else { throw StorageFailure.recoveryRequired("Trash staging directory was replaced") }
			for index in indices where journal.entries[index].published != nil {
				try handOff(index, in: target, journal: &journal, check: check)
			}
			try source.removeChild(name, expected: target)
		}
		record = journal.after
		try save()
		#else
		throw StorageFailure.invalid("supply a Trash directory on this platform")
		#endif
	}

	#if os(macOS)
	private func handOff(_ index: Int, in target: StorageDirectory, journal: inout StorageJournal, check: () throws -> Void) throws {
		try check()
		let entry = journal.entries[index]
		guard try target.identity().sameFile(entry.targetDirectory) else { throw StorageFailure.recoveryRequired("Trash staging directory was replaced") }
		if let staged = try target.inspect(entry.destination) {
			guard staged == entry.published else { throw StorageFailure.recoveryRequired("staged Trash file changed") }
			journal.trashInFlight = index
			try persist(journal)
			let url = target.url.appendingPathComponent(entry.destination)
			var current = stat()
			guard lstat(url.path, &current) == 0, FileStamp(current) == staged else { throw StorageFailure.recoveryRequired("staged Trash path changed") }
			var receipt: NSURL?
			try FileManager.default.trashItem(at: url, resultingItemURL: &receipt)
			if let receipt = receipt as URL? { journal.after.receipts.append(receipt.path) }
		} else if journal.trashInFlight != index {
			throw StorageFailure.recoveryRequired("staged Trash file is missing")
		}
		// An interrupted system handoff may have succeeded before recording its URL.
		try target.sync(target.fd)
		journal.entries[index].published = nil
		journal.trashInFlight = nil
		try persist(journal)
	}
	#endif
}
