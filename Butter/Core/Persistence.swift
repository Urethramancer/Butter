import Foundation

// All disk access is isolated from the UI actor; atomic replacement keeps the previous state on failure.
actor StateStorage {
	let root: URL
	private let write: @Sendable (Data, URL) throws -> Void
	init(root: URL, write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) { self.root = root; self.write = write }
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
