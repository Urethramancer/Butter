import Foundation

extension TorrentStorage {
	/// Repairs exact original relative-path matches as one recoverable transaction.
	public func repairFolder(from folder: URL) async throws -> StorageRepairResult {
		try await flush()
		return try await worker.run(bulk: true) { [state] cancellation in
			try state.ready(); try cancellation.check(); try state.invalidateChangedFiles()
			let source = try StorageDirectory(folder, create: false)
			let candidates = try state.repairFolderMatches(source, check: cancellation.check)
			let needed = try candidates.filter { try state.needsRepair($0.key) }
			if needed.isEmpty { return StorageRepairResult(repairedFiles: 0, verifiedPieces: 0, pendingPieces: 0) }
			return try state.repairFiles(needed, check: cancellation.check)
		}
	}
}

extension StorageState {
	func repairFolderMatches(_ source: StorageDirectory, check: () throws -> Void) throws -> [Int: URL] {
		let files = layout.files.filter { !$0.pad }
		let paths = try Dictionary(uniqueKeysWithValues: files.map { ($0.index, try StorageLayout.components($0.path)) })
		let canStripRoot = paths.values.allSatisfy { $0.count > 1 && $0.first == metadata.inspection.name }
		func matches(stripRoot: Bool) throws -> [Int: URL] {
			var result: [Int: URL] = [:]
			for file in files {
				try check()
				let parts = paths[file.index]!, path = (stripRoot ? Array(parts.dropFirst()) : parts).joined(separator: "/")
				if try source.inspect(path) != nil { result[file.index] = source.url.appendingPathComponent(path) }
			}
			return result
		}
		let parentMatches = try matches(stripRoot: false)
		let rootMatches = try canStripRoot ? matches(stripRoot: true) : [:]
		guard parentMatches.isEmpty || rootMatches.isEmpty else { throw StorageFailure.invalid("folder matches both torrent-root and parent paths; choose an unambiguous source folder") }
		let result = parentMatches.isEmpty ? rootMatches : parentMatches
		guard !result.isEmpty else { throw StorageFailure.invalid("no files match the torrent's original relative paths") }
		return result
	}
}
