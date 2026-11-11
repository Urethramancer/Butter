import Foundation
import Darwin

struct WatchedFile: Sendable {
	var url: URL
	var signature: String
	var contents: Data
}
struct WatchedFileOperations: Sendable {
	var moveExclusively: @Sendable (URL, URL) throws -> Void = { source, target in
		guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, target.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
	}
	var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
}
actor FolderWatcher {
	private var observed: [String: (String, Date)] = [:]
	private let operations: WatchedFileOperations
	private let maximumBytes: Int
	private let maximumBatchBytes: Int
	init(operations: WatchedFileOperations = WatchedFileOperations(), maximumBytes: Int = 32 * 1024 * 1024, maximumBatchBytes: Int = 64 * 1024 * 1024) {
		precondition(maximumBytes > 0 && maximumBatchBytes >= maximumBytes)
		self.operations = operations; self.maximumBytes = maximumBytes; self.maximumBatchBytes = maximumBatchBytes
	}
	private func read(_ url: URL, maximum: Int) throws -> Data {
		let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
		guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
		let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
		defer { close(descriptor) }
		var attributes = stat()
		guard fstat(descriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.fileReadInvalidFileName) }
		guard attributes.st_size <= maximum else { throw CocoaError(.fileReadTooLarge) }
		var result = Data()
		while true {
			try Task.checkCancellation()
			let bytes = try handle.read(upToCount: min(65536, maximum - result.count + 1)) ?? Data()
			if bytes.isEmpty { return result }
			guard bytes.count <= maximum - result.count else { throw CocoaError(.fileReadTooLarge) }
			result.append(bytes)
		}
	}
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
		var ready: [WatchedFile] = []; var present = Set<String>(); var retainedBytes = 0
		for url in urls where url.pathExtension.lowercased() == "torrent" {
			let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
			guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) > 0, let modified = values.contentModificationDate else { continue }
			let key = url.path; present.insert(key)
			let current = try signature(url)
			let legacy = current.components(separatedBy: "|").dropLast(2).joined(separator: "|")
			if imported.contains(current) || imported.contains(legacy) { continue }
			guard (values.fileSize ?? 0) <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
			if (values.fileSize ?? 0) > maximumBatchBytes - retainedBytes { continue }
			if let previous = observed[key], previous.0 == current {
				if now.timeIntervalSince(previous.1) >= 3 && now.timeIntervalSince(modified) >= 3 {
					let contents = try read(url, maximum: min(maximumBytes, maximumBatchBytes - retainedBytes))
					if try signature(url) == current { ready.append(WatchedFile(url: url, signature: current, contents: contents)); retainedBytes += contents.count }
				}
			} else { observed[key] = (current, now) }
		}
		observed = observed.filter { present.contains($0.key) }
		return ready
	}
	// Claim the directory entry before checking it. A replacement is retained, never unlinked.
	func removeImported(_ file: WatchedFile) throws {
		guard try signature(file.url) == file.signature, try read(file.url, maximum: maximumBytes) == file.contents else { return }
		let claimed = file.url.deletingLastPathComponent().appendingPathComponent(".butter-import-\(UUID().uuidString).torrent")
		try operations.moveExclusively(file.url, claimed)
		do {
			// The signature includes the path; compare with the original path prefix restored.
			let claimedSignature = try signature(claimed)
			let expected = claimed.path + String(file.signature.dropFirst(file.url.path.count))
			guard claimedSignature == expected, try read(claimed, maximum: maximumBytes) == file.contents else { throw CocoaError(.fileReadUnknown) }
			try operations.remove(claimed)
		} catch {
			do { try operations.moveExclusively(claimed, file.url) } catch {
				throw NSError(domain: "Butter.Watcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "A watched file was retained at \(claimed.path). Could not restore the original path: \(error.localizedDescription) Review the retained file before retrying.", NSUnderlyingErrorKey: error])
			}
			throw error
		}
	}
}
