import Foundation
import Darwin
import CryptoKit

// Reuse only the last parent during one stamp scan. No descriptor survives into
// the next scan, which must observe renamed/replaced directories afresh.
final class StorageStampScan {
	init() { StorageDiagnostics.count(.scans) }
	private var root: StorageDirectory?
	private var parentPath: String?
	private var descriptor: Int32 = -1
	deinit { if descriptor >= 0 { close(descriptor) } }
	func inspect(_ path: String, in directory: StorageDirectory) throws -> FileStamp? {
		// The parent was validated when this scan opened it. Compare exact UTF-8
		// bytes before reusing that validation; every new leaf still needs validation.
		let slash = path.lastIndex(of: "/")
		let parentEnd = slash ?? path.startIndex
		if !path.hasPrefix("/"), root === directory, let parentPath, path[..<parentEnd].utf8.elementsEqual(parentPath.utf8) {
			let name = path[(slash.map { path.index(after: $0) } ?? path.startIndex)...]
			guard path.utf8.count <= 4096 else { throw StorageFailure.invalid("relative file path") }
			if StorageLayout.validComponent(name) {
				guard descriptor >= 0 else { return nil }
				return try directory.inspect(String(name), at: descriptor)
			}
			// A slash joined to a combining mark is not a standalone Character.
			// Resolve this ambiguous split through the validated byte components.
			guard name.utf8.contains(47) else { throw StorageFailure.invalid("relative file path") }
		}
		let parts = try StorageLayout.components(path), parent = parts.dropLast().joined(separator: "/")
		if root !== directory || parentPath != parent {
			if descriptor >= 0 { close(descriptor) }; descriptor = -1
			root = directory; parentPath = parent
			do {
				descriptor = try directory.parent(path) { parent, _ in
					let copy = dup(parent)
					StorageDiagnostics.count(.descriptorDuplicates)
					guard copy >= 0 else { throw diskError("Cannot retain inspection directory") }; return copy
				}
			} catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
		}
		guard descriptor >= 0 else { return nil }
		return try directory.inspect(parts.last!, at: descriptor)
	}
}

func diskError(_ context: String, code: Int32 = errno) -> NSError {
	NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(cString: strerror(code)))"])
}

struct FileStamp: Codable, Equatable, Sendable {
	let device: Int32
	let inode: UInt64
	let size: Int64
	let modifiedSeconds: Int64
	let modifiedNanos: Int64
	let changedSeconds: Int64
	let changedNanos: Int64
	init(_ value: stat) {
		device = value.st_dev; inode = value.st_ino; size = value.st_size
		modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
		changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
	}
	func sameFile(_ other: FileStamp) -> Bool { device == other.device && inode == other.inode }
}

// Root descriptors anchor every operation. Each descendant is opened without following links.
final class StorageDirectory: @unchecked Sendable {
	let url: URL
	let fd: Int32
	private init(url: URL, descriptor: Int32) { self.url = url; fd = descriptor }
	init(_ url: URL, create: Bool = true) throws {
		guard url.isFileURL, url.path.hasPrefix("/") else { throw StorageFailure.invalid("absolute storage root") }
		// The user chooses the root; aliases above it (e.g. /var) may resolve once.
		self.url = url.standardizedFileURL.resolvingSymlinksInPath()
		if create { try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true) }
		// Anchors need search access; names() requests listing access separately.
		fd = open(self.url.path, O_SEARCH | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		StorageDiagnostics.opened(.directoryOpens)
		guard fd >= 0 else { throw diskError("Cannot open storage root") }
	}
	deinit { close(fd) }
	func child(_ name: String, create: Bool = false) throws -> StorageDirectory {
		guard try StorageLayout.components(name).count == 1 else { throw StorageFailure.invalid("state directory name") }
		if create {
			guard mkdirat(fd, name, 0o700) == 0 else { throw diskError("Cannot create state directory") }; try sync(fd)
		}
		let descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		StorageDiagnostics.opened(.directoryOpens)
		guard descriptor >= 0 else { throw diskError("Cannot open state directory") }
		return StorageDirectory(url: url.appendingPathComponent(name), descriptor: descriptor)
	}
	func names() throws -> [String] {
		let descriptor = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
		StorageDiagnostics.opened(.directoryOpens)
		guard descriptor >= 0 else { throw diskError("Cannot enumerate state directory") }
		guard let directory = fdopendir(descriptor) else { close(descriptor); throw diskError("Cannot enumerate state directory") }
		defer { closedir(directory) }
		var names: [String] = []; errno = 0
		while let entry = readdir(directory) {
			let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
				pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
			}
			if name != "." && name != ".." { names.append(name) }
			guard names.count <= 50_016 else { throw StorageFailure.limit("state directory entries") }; errno = 0
		}
		guard errno == 0 else { throw diskError("Cannot enumerate state directory") }; return names
	}
	func removeChild(_ name: String, expected: StorageDirectory) throws {
		var value = stat()
		guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw diskError("Cannot inspect state directory") }
		guard try FileStamp(value).sameFile(expected.identity()), value.st_mode & S_IFMT == S_IFDIR else { throw StorageFailure.recoveryRequired("state directory identity changed") }
		guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw diskError("Cannot remove state directory") }; try sync(fd)
	}
	func identity() throws -> FileStamp {
		var value = stat()
		guard fstat(fd, &value) == 0 else { throw diskError("Cannot inspect storage root") }
		return FileStamp(value)
	}
	func parent<T>(_ path: String, create: Bool = false, _ body: (Int32, String) throws -> T) throws -> T {
		let parts = try StorageLayout.components(path)
		var directory = dup(fd)
		StorageDiagnostics.count(.descriptorDuplicates)
		guard directory >= 0 else { throw diskError("Cannot duplicate directory") }
		defer { close(directory) }
		for part in parts.dropLast() {
			if create, mkdirat(directory, part, 0o700) == 0 { try sync(directory) }
			let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			StorageDiagnostics.opened(.directoryOpens)
			guard next >= 0 else { throw diskError("Cannot open managed directory") }
			close(directory); directory = next
		}
		return try body(directory, parts.last!)
	}
	func openFile(_ path: String, write: Bool = false, exclusive: Bool = false) throws -> Int32 {
		try parent(path, create: write) { directory, name in
			let flags = (write ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (exclusive ? O_EXCL : 0)
			let file = openat(directory, name, flags, 0o600)
			StorageDiagnostics.opened(.fileOpens)
			guard file >= 0 else { throw diskError("Cannot open managed file") }
			do { _ = try stamp(file, shared: !write); return file } catch { close(file); throw error }
		}
	}
	func stamp(_ file: Int32, shared: Bool = false) throws -> FileStamp {
		StorageDiagnostics.count(.fileDescriptorInspections)
		var value = stat()
		guard fstat(file, &value) == 0 else { throw diskError("Cannot inspect managed file") }
		return try regularStamp(value, shared: shared)
	}
	private func regularStamp(_ value: stat, shared: Bool = false) throws -> FileStamp {
		guard value.st_mode & S_IFMT == S_IFREG else { throw StorageFailure.invalid("managed path is not a regular file") }
		guard shared || value.st_nlink == 1 else { throw StorageFailure.shared("hard-linked file") }
		return FileStamp(value)
	}
	func inspect(_ path: String) throws -> FileStamp? {
		do {
			return try parent(path) { directory, name in try inspect(name, at: directory) }
		}
		catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
	}
	fileprivate func inspect(_ name: String, at directory: Int32) throws -> FileStamp? {
		StorageDiagnostics.count(.filesInspected)
		var value = stat()
		if fstatat(directory, name, &value, AT_SYMLINK_NOFOLLOW) != 0 {
			if errno == ENOENT { return nil }; throw diskError("Cannot inspect managed file")
		}
		return try regularStamp(value)
	}
	func read(_ path: String, maximum: Int) throws -> Data {
		let file = try openFile(path); defer { close(file) }
		guard try stamp(file, shared: true).size <= maximum else { throw StorageFailure.limit("state bytes") }
		var result = Data()
		while true {
			let bytes = try Self.read(file, offset: Int64(result.count), count: min(65536, maximum - result.count + 1))
			if bytes.isEmpty { return result }
			guard bytes.count <= maximum - result.count else { throw StorageFailure.limit("state bytes") }; result.append(bytes)
		}
	}
	static func read(_ file: Int32, offset: Int64, count: Int) throws -> Data {
		var bytes = Data(count: count)
		while true {
			let readCount = bytes.withUnsafeMutableBytes { pread(file, $0.baseAddress, count, off_t(offset)) }
			if readCount < 0 {
				if errno == EINTR { continue }; throw diskError("Cannot read file")
			}
			bytes.count = readCount
			StorageDiagnostics.io(read: true, bytes: readCount)
			return bytes
		}
	}
	static func write(_ data: Data, to file: Int32, offset: Int64, maximumChunk: Int = 65536, profile: StorageWriteProfile? = nil, check: () throws -> Void) throws {
		try data.withUnsafeBytes { bytes in
			var written = 0
			while written < bytes.count {
				profile?.enter(.prewriteChecks)
				try check()
				let requested = min(maximumChunk, bytes.count - written)
				profile?.count("syscallAttempts"); profile?.histogram("syscallBytes", requested)
				profile?.enter(.payloadSyscall)
				let count = pwrite(file, bytes.baseAddress!.advanced(by: written), requested, off_t(offset) + off_t(written))
				profile?.enter(.prewriteChecks)
				if count < 0, errno == EINTR { profile?.count("syscallRetries"); continue }
				guard count > 0 else { throw diskError("Cannot write file") }; written += count
				profile?.count("physicalBytes", count)
				if count < requested { profile?.count("shortWrites") }
				StorageDiagnostics.io(read: false, bytes: count)
			}
		}
	}
	func sync(_ file: Int32) throws { guard fsync(file) == 0 else { throw diskError("Cannot flush file") } }
	func atomic(_ data: Data, path: String, exclusive: Bool = false) throws {
		try parent(path, create: true) { directory, name in
			let temporary = ".atomic-" + UUID().uuidString
			let file = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
			StorageDiagnostics.opened(.atomicStateOpens)
			guard file >= 0 else { throw diskError("Cannot create atomic state") }
			defer { close(file); unlinkat(directory, temporary, 0) }
			try Self.write(data, to: file, offset: 0, check: {})
			try sync(file)
			let result = exclusive ? renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) : renameat(directory, temporary, directory, name)
			guard result == 0 else { throw diskError("Cannot publish atomic state") }
			try sync(directory)
		}
	}
	func remove(_ path: String, expected: FileStamp) throws {
		try parent(path) { directory, name in
			guard let current = try inspect(path), current == expected else { throw StorageFailure.recoveryRequired("source identity or content stamp changed") }
			guard unlinkat(directory, name, 0) == 0 else { throw diskError("Cannot remove managed file") }; try sync(directory)
		}
	}
	func claimFile(_ path: String, as claimed: String, expected: FileStamp, digest: Data,
		check: () throws -> Void, beforeClaim: () -> Void = {}) throws -> FileStamp? {
		var claimedNow = false
		if try inspect(claimed) == nil {
			guard let current = try inspect(path) else { return nil }
			guard current == expected, try self.digest(path, check: check) == digest else { throw StorageFailure.recoveryRequired("source changed before claiming; it was retained") }
			beforeClaim()
			try rename(path, to: self, path: claimed)
			claimedNow = true
		}
		let checked = try checkedDigest(claimed, check: check)
		guard checked.stamp.sameFile(expected), checked.hash == digest else {
			guard claimedNow else { throw StorageFailure.recoveryRequired("unrecognised claim retained at \(url.appendingPathComponent(claimed).path)") }
			do { try rename(claimed, to: self, path: path) }
			catch { throw StorageFailure.recoveryRequired("replacement retained at \(url.appendingPathComponent(claimed).path)") }
			throw StorageFailure.recoveryRequired("source changed during claiming; it was retained")
		}
		return checked.stamp
	}
	func rename(_ source: String, to target: StorageDirectory, path: String) throws {
		try parent(source) { from, name in
			try target.parent(path, create: true) { destination, final in
				guard renameatx_np(from, name, destination, final, UInt32(RENAME_EXCL)) == 0 else {
					if errno == EEXIST { throw StorageFailure.collision(path) }; throw diskError("Cannot move managed file")
				}
				try target.sync(destination); try sync(from)
			}
		}
	}
	func digest(_ path: String, check: () throws -> Void) throws -> Data {
		try checkedDigest(path, check: check).hash
	}
	func checkedDigest(_ path: String, check: () throws -> Void) throws -> (hash: Data, stamp: FileStamp) {
		let file = try openFile(path); defer { close(file) }
		let before = try stamp(file, shared: true)
		var hash = SHA256(), offset: Int64 = 0
		while offset < before.size {
			try check(); let data = try Self.read(file, offset: offset, count: Int(min(65536, before.size - offset)))
			guard !data.isEmpty else { throw StorageFailure.invalid("file shortened during copy") }
			hash.update(data: data); offset += Int64(data.count)
			StorageDiagnostics.count(.bytesHashed, data.count); StorageDiagnostics.count(.sha256Bytes, data.count)
		}
		guard try stamp(file, shared: true) == before else { throw StorageFailure.invalid("file changed during copy") }
		return (Data(hash.finalize()), before)
	}
}
