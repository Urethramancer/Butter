import Foundation

struct WatchedFile: Sendable { var url: URL; var signature: String }
actor FolderWatcher {
	private var observed: [String: (Int64, Date, Date)] = [:]
	func scan(_ path: String, imported: Set<String>, now: Date = Date()) throws -> [WatchedFile] {
		guard !path.isEmpty else { observed = [:]; return [] }
		let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey], options: .skipsHiddenFiles)
		var ready: [WatchedFile] = []; var present = Set<String>()
		for url in urls where url.pathExtension.lowercased() == "torrent" {
			let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
			guard values.isRegularFile == true, let size = values.fileSize, size > 0, let modified = values.contentModificationDate else { continue }
			let key = url.path; present.insert(key)
			let signature = "\(key)|\(size)|\(modified.timeIntervalSince1970)"
			if imported.contains(signature) { continue }
			if let previous = observed[key], previous.0 == Int64(size), previous.1 == modified {
				if now.timeIntervalSince(previous.2) >= 3 && now.timeIntervalSince(modified) >= 3 { ready.append(WatchedFile(url: url, signature: signature)) }
			} else { observed[key] = (Int64(size), modified, now) }
		}
		observed = observed.filter { present.contains($0.key) }
		return ready
	}
}
