import Foundation

// All disk access is isolated from the UI actor; atomic replacement keeps the previous state on failure.
actor StateStorage {
	let root: URL
	init(root: URL) { self.root = root }
	func load() throws -> SavedState {
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		let url = root.appendingPathComponent("state.json")
		guard FileManager.default.fileExists(atPath: url.path) else { return SavedState() }
		return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: url))
	}
	func save(_ state: SavedState) throws {
		try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
		try JSONEncoder().encode(state).write(to: root.appendingPathComponent("state.json"), options: .atomic)
	}
}
