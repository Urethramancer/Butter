import Foundation
import Darwin

extension TorrentStorage {
	public func recover(acceptMatchingCopies: Bool = false) async throws {
		try await worker.run { [state] cancellation in try state.recover(acceptMatchingCopies: acceptMatchingCopies, check: cancellation.check) }
	}
	public func rename(_ changes: [Int: String]) async throws {
		try await worker.run { [state] cancellation in
			try state.ready(); var after = state.record
			for (index, path) in changes {
				guard state.layout.files.indices.contains(index), !state.layout.files[index].pad else { throw StorageFailure.invalid("rename index") }
				_ = try StorageLayout.components(path); after.paths[index] = path
			}
			try StorageLayout.validatePaths(after.paths.indices.filter { !state.layout.files[$0].pad }.map { after.paths[$0] })
			var entries: [StorageJournal.Entry] = []
			for index in changes.keys.sorted() where !after.spilled[index] && after.paths[index] != state.record.paths[index] {
				if let entry = try state.entry(index, source: state.payload, path: state.record.paths[index], target: state.payload, destination: after.paths[index], move: true, check: cancellation.check) { entries.append(entry) }
			}
			try state.perform(after: after, entries: entries, check: cancellation.check)
		}
	}
	public func move(to destination: URL) async throws {
		try await worker.run { [state] cancellation in
			try state.ready(); let target = try StorageDirectory(destination)
			if target.url == state.payload.url { return }
			var after = state.record; after.destination = target.url.path
			var entries: [StorageJournal.Entry] = []
			for index in after.paths.indices where !state.layout.files[index].pad && !after.spilled[index] {
				if let entry = try state.entry(index, source: state.payload, path: after.paths[index], target: target, destination: after.paths[index], move: true, check: cancellation.check) { entries.append(entry) }
			}
			try state.perform(after: after, entries: entries, check: cancellation.check)
		}
	}
	public func select(_ selected: [Bool]) async throws {
		try await worker.run { [state] cancellation in
			try state.ready()
			guard selected.count == state.layout.files.count else { throw StorageFailure.invalid("selection count") }
			var after = state.record, entries: [StorageJournal.Entry] = []
			for index in selected.indices {
				after.selected[index] = selected[index] && !state.layout.files[index].pad
				if after.selected[index] && after.spilled[index] {
					let (source, path) = state.location(index)
					if let entry = try state.entry(index, source: source, path: path, target: state.payload, destination: after.paths[index], move: true, check: cancellation.check) { entries.append(entry) }
					after.spilled[index] = false
				}
			}
			try state.perform(after: after, entries: entries, check: cancellation.check)
		}
	}
	/// Copies existing files without removing the import source or trusting their hashes.
	public func importFiles(from directory: URL) async throws {
		try await worker.run { [state] cancellation in
			try state.ready(); let source = try StorageDirectory(directory, create: false)
			var entries: [StorageJournal.Entry] = []
			for index in state.record.paths.indices where !state.layout.files[index].pad {
				let (target, path) = state.location(index)
				if let entry = try state.entry(index, source: source, path: state.record.paths[index], target: target, destination: path, move: false, check: cancellation.check) {
					guard entry.original.size == state.layout.files[index].size else { throw StorageFailure.invalid("import file length") }; entries.append(entry)
				}
			}
			try state.perform(after: state.record, entries: entries, check: cancellation.check)
		}
	}
	/// Uses the system Trash by default; fixtures may supply a disposable Trash directory.
	public func trash(directory: URL? = nil) async throws -> [URL] {
		try await worker.run { [state] cancellation in
			try state.ready()
			let url: URL
			if let directory { url = directory }
			else {
				#if os(macOS)
				url = try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: state.payload.url, create: true)
				#else
				throw StorageFailure.invalid("supply a Trash directory on this platform")
				#endif
			}
			let target = try StorageDirectory(url)
			var entries: [StorageJournal.Entry] = [], after = state.record
			after.verified = Data(repeating: 0, count: after.verified.count)
			for index in after.paths.indices where !state.layout.files[index].pad {
				let (source, path) = state.location(index)
				let basename = URL(fileURLWithPath: after.paths[index]).lastPathComponent
				let receipt = UUID().uuidString + "-" + String(decoding: basename.utf8.prefix(160), as: UTF8.self)
				if let entry = try state.entry(index, source: source, path: path, target: target, destination: receipt, move: true, check: cancellation.check) {
					entries.append(entry); after.receipts.append(target.url.appendingPathComponent(receipt).path)
				}
			}
			guard after.receipts.count <= 50_000 else { throw StorageFailure.limit("Trash receipts") }
			try state.perform(after: after, entries: entries, check: cancellation.check)
			return entries.map { target.url.appendingPathComponent($0.destination) }
		}
	}
}

extension StorageState {
	func entry(_ index: Int, source: StorageDirectory, path: String, target: StorageDirectory, destination: String, move: Bool, check: () throws -> Void) throws -> StorageJournal.Entry? {
		try check()
		// Check every destination before journalling or touching a source.
		guard try target.inspect(destination) == nil else { throw StorageFailure.collision(destination) }
		guard let original = try source.inspect(path) else { return nil }
		var volume = stat()
		guard fstat(target.fd, &volume) == 0 else { throw diskError("Cannot inspect target volume") }
		let parent = (destination as NSString).deletingLastPathComponent
		let temporary = (parent.isEmpty ? "" : parent + "/") + ".butter-copy-" + UUID().uuidString
		return StorageJournal.Entry(index: index, sourceRoot: source.url.path, source: path, destinationRoot: target.url.path, destination: destination,
			sourceDirectory: try source.identity(), targetDirectory: try target.identity(),
			original: original, digest: try source.digest(path, check: check), copy: !move || original.device != volume.st_dev, removeSource: move,
			temporary: temporary)
	}
}
