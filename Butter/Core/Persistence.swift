import Foundation
import Darwin

protocol StatePersisting: Sendable {
	func load() async throws -> SavedState
	func save(_ state: SavedState) async throws
}
// All disk access is isolated from the UI actor; atomic replacement keeps the previous state on failure.
actor StateStorage: StatePersisting {
	let root: URL
	private let write: @Sendable (Data, URL) throws -> Void
	init(root: URL, write: @escaping @Sendable (Data, URL) throws -> Void = { try StateStorage.replace($0, at: $1) }) { self.root = root; self.write = write }
	func load() throws -> SavedState {
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let url = root.appendingPathComponent("state.json")
		guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
		let state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
		try validate(state)
		return state
	}
	func save(_ state: SavedState) throws {
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try validate(state)
		try write(JSONEncoder().encode(state), root.appendingPathComponent("state.json"))
	}
	// Retain an undo link until the rename and its directory entry are durable.
	nonisolated private static func replace(_ data: Data, at url: URL) throws {
		let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard directory >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		defer { close(directory) }
		let temporary = ".state-\(UUID().uuidString)", backup = ".previous-\(UUID().uuidString)", name = url.lastPathComponent
		let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
		guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		defer { close(file); unlinkat(directory, temporary, 0); unlinkat(directory, backup, 0) }
		try data.withUnsafeBytes { bytes in
			var offset = 0
			while offset < bytes.count {
				let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
				if count < 0 && errno == EINTR { continue }
				guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
				offset += count
			}
		}
		guard fsync(file) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		let retained = linkat(directory, name, directory, backup, 0) == 0
		guard retained || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		guard renameat(directory, temporary, directory, name) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		if fsync(directory) != 0 {
			let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
			let restored = retained ? renameat(directory, backup, directory, name) : unlinkat(directory, name, 0)
			guard restored == 0, fsync(directory) == 0 else {
				throw NSError(domain: "Butter.Storage", code: 4, userInfo: [NSLocalizedDescriptionKey: "State replacement and rollback could not be made durable. Check disk access before restarting transfers.", NSUnderlyingErrorKey: failure])
			}
			throw failure
		}
	}
	private func validate(_ state: SavedState) throws {
		var ids = Set<String>()
		let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
		for record in state.transfers {
			guard !record.id.isEmpty, record.id.utf8.count <= 128, record.id.unicodeScalars.allSatisfy({ allowed.contains($0) }), ids.insert(record.id).inserted else {
				throw NSError(domain: "Butter.Storage", code: 2, userInfo: [NSLocalizedDescriptionKey: "Saved transfers contain an invalid or duplicate identifier. Repair state.json or restore a backup; no data was discarded."])
			}
		}
		let p = state.preferences
		guard (0...65535).contains(p.port), (1...5000).contains(p.peers), (1...1000).contains(p.torrentPeers), (0...100).contains(p.activeDownloads), (0...100).contains(p.activeSeeds), (0...1440).contains(p.idleMinutes), p.ratioLimit.isFinite, p.ratioLimit >= 0 else {
			throw NSError(domain: "Butter.Storage", code: 3, userInfo: [NSLocalizedDescriptionKey: "Saved preferences contain an invalid network or queue limit. Repair state.json or restore a backup."])
		}
	}
}
