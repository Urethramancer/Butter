import Foundation
import Darwin

// One synchronous verification owns this cursor. Every use rechecks the parent
// through the root and refreshes effective access; only an unchanged parent is
// reused. Deeper paths retain component-by-component traversal.
final class StorageVerificationPaths {
	private var root: StorageDirectory?
	private var name: String?
	private var descriptor: Int32 = -1
	private var stamp: FileStamp?
	deinit { reset() }
	private func reset() {
		if descriptor >= 0 { close(descriptor) }
		descriptor = -1; stamp = nil; name = nil; root = nil
	}
	private func supports(_ path: String) -> Bool {
		var slash = false
		for byte in path.utf8 where byte == 47 {
			if slash { return false }; slash = true
		}
		return slash
	}
	func inspect(_ path: String, in directory: StorageDirectory) throws -> FileStamp? {
		guard supports(path) else { reset(); return try directory.inspect(path) }
		let parts = try StorageLayout.components(path)
		guard let parent = try prepare(parts[0], in: directory) else { return nil }
		return try directory.inspect(parts[1], at: parent)
	}
	func openFile(_ path: String, in directory: StorageDirectory) throws -> Int32 {
		guard supports(path) else { reset(); return try directory.openFile(path) }
		let parts = try StorageLayout.components(path)
		guard let parent = try prepare(parts[0], in: directory) else { return try directory.openFile(path) }
		return try directory.openFile(parts[1], at: parent)
	}
	private func prepare(_ parent: String, in directory: StorageDirectory) throws -> Int32? {
		if root !== directory || name?.utf8.elementsEqual(parent.utf8) != true { reset() }
		if descriptor >= 0 {
			var current = stat()
			StorageDiagnostics.count(.verificationParentInspections)
			if fstatat(directory.fd, parent, &current, AT_SYMLINK_NOFOLLOW) != 0 {
				let code = errno; reset()
				if code == ENOENT { return nil }; throw diskError("Cannot inspect managed directory", code: code)
			}
			if current.st_mode & S_IFMT != S_IFDIR || FileStamp(current) != stamp { reset() }
			else {
				StorageDiagnostics.count(.verificationParentAccessChecks)
				if faccessat(descriptor, ".", R_OK, AT_EACCESS) != 0 { reset() }
				else { StorageDiagnostics.count(.verificationParentHits) }
			}
		}
		if descriptor < 0 {
			let file = openat(directory.fd, parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			StorageDiagnostics.opened(.directoryOpens)
			guard file >= 0 else {
				if errno == ENOENT { return nil }; throw diskError("Cannot open managed directory")
			}
			var value = stat()
			StorageDiagnostics.count(.verificationParentInspections)
			guard fstat(file, &value) == 0 else {
				let error = diskError("Cannot inspect managed directory"); close(file); throw error
			}
			descriptor = file; stamp = FileStamp(value); root = directory; name = parent
		}
		return descriptor
	}
}
