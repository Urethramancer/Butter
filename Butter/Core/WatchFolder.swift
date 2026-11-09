import Foundation
import Darwin

struct WatchedFile: Sendable {
	var url: URL
	var signature: String
	var contents: Data
}
actor FolderWatcher {
	private var observed: [String: (String, Date)] = [:]
	private func signature(_ url: URL) throws -> String {
		let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
		guard attributes[.type] as? FileAttributeType == .typeRegular,
			let size = attributes[.size] as? NSNumber, size.int64Value > 0,
			let modified = attributes[.modificationDate] as? Date,
			let inode = attributes[.systemFileNumber] as? NSNumber,
			let device = attributes[.systemNumber] as? NSNumber else { throw CocoaError(.fileReadInvalidFileName) }
		return "\(url.path)|\(size)|\(modified.timeIntervalSince1970)|\(device)|\(inode)"
	}
	func scan(_ path: String, imported: Set<String>, now: Date = Date()) throws -> [WatchedFile] {
		guard !path.isEmpty else { observed = [:]; return [] }
		let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey], options: .skipsHiddenFiles)
		var ready: [WatchedFile] = []; var present = Set<String>()
		for url in urls where url.pathExtension.lowercased() == "torrent" {
			let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
			guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0, let modified = values.contentModificationDate else { continue }
			let key = url.path; present.insert(key)
			let current = try signature(url)
			let legacy = current.components(separatedBy: "|").dropLast(2).joined(separator: "|")
			if imported.contains(current) || imported.contains(legacy) { continue }
			if let previous = observed[key], previous.0 == current {
				if now.timeIntervalSince(previous.1) >= 3 && now.timeIntervalSince(modified) >= 3 {
					let contents = try Data(contentsOf: url)
					if try signature(url) == current { ready.append(WatchedFile(url: url, signature: current, contents: contents)) }
				}
			} else { observed[key] = (current, now) }
		}
		observed = observed.filter { present.contains($0.key) }
		return ready
	}
	// Claim the directory entry before checking it. A replacement is retained, never unlinked.
	func removeImported(_ file: WatchedFile) throws {
		let fm = FileManager.default
		guard try signature(file.url) == file.signature, try Data(contentsOf: file.url) == file.contents else { return }
		let claimed = file.url.deletingLastPathComponent().appendingPathComponent(".butter-import-\(UUID().uuidString).torrent")
		guard renameatx_np(AT_FDCWD, file.url.path, AT_FDCWD, claimed.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		do {
			// The signature includes the path; compare with the original path prefix restored.
			let claimedSignature = try signature(claimed)
			let expected = claimed.path + String(file.signature.dropFirst(file.url.path.count))
			guard claimedSignature == expected, try Data(contentsOf: claimed) == file.contents else { throw CocoaError(.fileReadUnknown) }
			try fm.removeItem(at: claimed)
		} catch {
			if renameatx_np(AT_FDCWD, claimed.path, AT_FDCWD, file.url.path, UInt32(RENAME_EXCL)) != 0 {
				throw NSError(domain: "Butter.Watcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "A changed watched file was retained at \(claimed.path). The original path is occupied; review both files."])
			}
			throw error
		}
	}
}
