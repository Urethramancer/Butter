import Foundation
import Darwin
import CryptoKit

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
	init(_ url: URL, create: Bool = true) throws {
		guard url.isFileURL, url.path.hasPrefix("/") else { throw StorageFailure.invalid("absolute storage root") }
		// The user chooses the root; aliases above it (e.g. /var) may resolve once.
		self.url = url.standardizedFileURL.resolvingSymlinksInPath()
		if create { try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true) }
		fd = open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard fd >= 0 else { throw diskError("Cannot open storage root") }
	}
	deinit { close(fd) }
	func identity() throws -> FileStamp {
		var value = stat()
		guard fstat(fd, &value) == 0 else { throw diskError("Cannot inspect storage root") }
		return FileStamp(value)
	}
	func parent<T>(_ path: String, create: Bool = false, _ body: (Int32, String) throws -> T) throws -> T {
		let parts = try StorageLayout.components(path)
		var directory = dup(fd)
		guard directory >= 0 else { throw diskError("Cannot duplicate directory") }
		defer { close(directory) }
		for part in parts.dropLast() {
			if create, mkdirat(directory, part, 0o700) == 0 { try sync(directory) }
			let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			guard next >= 0 else { throw diskError("Cannot open managed directory") }
			close(directory); directory = next
		}
		return try body(directory, parts.last!)
	}
	func openFile(_ path: String, write: Bool = false, exclusive: Bool = false) throws -> Int32 {
		try parent(path, create: write) { directory, name in
			let flags = (write ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (exclusive ? O_EXCL : 0)
			let file = openat(directory, name, flags, 0o600)
			guard file >= 0 else { throw diskError("Cannot open managed file") }
			do { _ = try stamp(file, shared: !write); return file } catch { close(file); throw error }
		}
	}
	func stamp(_ file: Int32, shared: Bool = false) throws -> FileStamp {
		var value = stat()
		guard fstat(file, &value) == 0 else { throw diskError("Cannot inspect managed file") }
		guard value.st_mode & S_IFMT == S_IFREG else { throw StorageFailure.invalid("managed path is not a regular file") }
		guard shared || value.st_nlink == 1 else { throw StorageFailure.shared("hard-linked file") }
		return FileStamp(value)
	}
	func inspect(_ path: String) throws -> FileStamp? {
		do { let file = try openFile(path); defer { close(file) }; return try stamp(file) }
		catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return nil }
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
		var bytes = [UInt8](repeating: 0, count: count)
		let readCount = pread(file, &bytes, count, off_t(offset))
		if readCount < 0 { if errno == EINTR { return try read(file, offset: offset, count: count) }; throw diskError("Cannot read file") }
		return Data(bytes.prefix(readCount))
	}
	static func write(_ data: Data, to file: Int32, offset: Int64, check: () throws -> Void) throws {
		try data.withUnsafeBytes { bytes in
			var written = 0
			while written < bytes.count {
				try check()
				let count = pwrite(file, bytes.baseAddress!.advanced(by: written), min(65536, bytes.count - written), off_t(offset) + off_t(written))
				if count < 0, errno == EINTR { continue }
				guard count > 0 else { throw diskError("Cannot write file") }; written += count
			}
		}
	}
	func sync(_ file: Int32) throws { guard fsync(file) == 0 else { throw diskError("Cannot flush file") } }
	func atomic(_ data: Data, path: String) throws {
		try parent(path, create: true) { directory, name in
			let temporary = ".atomic-" + UUID().uuidString
			let file = openat(directory, temporary, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
			guard file >= 0 else { throw diskError("Cannot create atomic state") }
			defer { close(file); unlinkat(directory, temporary, 0) }
			try Self.write(data, to: file, offset: 0, check: {})
			try sync(file)
			guard renameat(directory, temporary, directory, name) == 0 else { throw diskError("Cannot publish atomic state") }
			try sync(directory)
		}
	}
	func remove(_ path: String, expected: FileStamp) throws {
		try parent(path) { directory, name in
			guard let current = try inspect(path), current == expected else { throw StorageFailure.recoveryRequired("source identity or content stamp changed") }
			guard unlinkat(directory, name, 0) == 0 else { throw diskError("Cannot remove managed file") }; try sync(directory)
		}
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
		}
		guard try stamp(file, shared: true) == before else { throw StorageFailure.invalid("file changed during copy") }
		return (Data(hash.finalize()), before)
	}
}
