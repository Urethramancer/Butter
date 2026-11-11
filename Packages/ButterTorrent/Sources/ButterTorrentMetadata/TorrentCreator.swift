import Foundation
import CryptoKit
import Darwin

/// TorrentCreator creates hybrid metadata using one bounded, cancellable hashing worker.
public enum TorrentCreator {
	private struct SourceFile {
		let path: [String]
		let size: Int64
	}

	public static func create(source: URL, trackers: [String], isPrivate: Bool,
		pieceLength requestedLength: Int? = nil, progress: (Double) -> Void = { _ in },
		isCancelled: () -> Bool = { false }) throws -> Data {
		func check() throws { if isCancelled() { throw CancellationError() } }
		try check()
		guard !isPrivate || !trackers.isEmpty else { throw MetadataError.invalid("a private torrent requires a tracker") }
		guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MetadataError.invalid("source is a symbolic link") }
		let source = source.standardizedFileURL.resolvingSymlinksInPath()
		let (files, directory) = try list(source, check: check)
		var total: Int64 = 0
		for file in files {
			let sum = total.addingReportingOverflow(file.size)
			guard !sum.overflow else { throw MetadataError.limit("source size") }
			total = sum.partialValue
		}
		guard total > 0 else { throw MetadataError.invalid("source contains no data") }
		var pieceLength = requestedLength ?? 16384
		if requestedLength == nil {
			while total / Int64(pieceLength) > 2048 && pieceLength < 16 * 1024 * 1024 { pieceLength *= 2 }
		}
		guard pieceLength >= 16384, pieceLength <= 16 * 1024 * 1024, pieceLength & (pieceLength - 1) == 0 else {
			throw MetadataError.invalid("invalid creation piece length")
		}
		// Bound retained hash lists before reading payload data, not just at encoding.
		var paddedSize: Int64 = 0
		for file in files {
			let padding = directory && file.size % Int64(pieceLength) != 0 ? Int64(pieceLength) - file.size % Int64(pieceLength) : 0
			let sum = paddedSize.addingReportingOverflow(file.size)
			let padded = sum.partialValue.addingReportingOverflow(padding)
			guard !sum.overflow, !padded.overflow else { throw MetadataError.limit("source size") }
			paddedSize = padded.partialValue
		}
		guard paddedSize / Int64(pieceLength) < 400_000 else { throw MetadataError.limit("creation piece count") }
		var pieces = Data(), layers: [Data: BencodeValue] = [:]
		var v1Files: [BencodeValue] = [], tree: [Data: BencodeValue] = [:]
		var processed: Int64 = 0
		let base = directory ? source : source.deletingLastPathComponent()
		let baseFD = open(base.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard baseFD >= 0 else { throw posix("Cannot open source folder") }
		defer { close(baseFD) }
		for file in files {
			try check()
			let fd = try openFile(base: baseFD, path: file.path)
			let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
			defer { close(fd) }
			var before = stat()
			guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size == file.size else {
				throw MetadataError.invalid("source changed during traversal")
			}
			var remaining = file.size, v1Bytes = 0
			var sha1 = Insecure.SHA1(), leaves: [Data] = [], roots: [Data] = []
			let blocksPerPiece = pieceLength / 16384
			func finishV1() {
				pieces.append(contentsOf: sha1.finalize()); sha1 = Insecure.SHA1(); v1Bytes = 0
			}
			while remaining > 0 {
				try check()
				let length = Int(min(remaining, 16384))
				var block = Data()
				while block.count < length {
					guard let bytes = try handle.read(upToCount: length - block.count), !bytes.isEmpty else {
						throw MetadataError.invalid("source became shorter during hashing")
					}
					block.append(bytes)
				}
				sha1.update(data: block); v1Bytes += block.count
				if v1Bytes == pieceLength { finishV1() }
				leaves.append(Data(SHA256.hash(data: block)))
				if leaves.count == blocksPerPiece { roots.append(merkle(leaves, zero: Data(repeating: 0, count: 32))); leaves.removeAll(keepingCapacity: true) }
				remaining -= Int64(block.count); processed += Int64(block.count)
				progress(min(0.99, Double(processed) / Double(total)))
			}
			var after = stat()
			guard fstat(fd, &after) == 0, before.st_size == after.st_size,
				before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
				before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
				throw MetadataError.invalid("source changed during hashing")
			}
			if !leaves.isEmpty {
				if file.size >= Int64(pieceLength) {
					leaves += Array(repeating: Data(repeating: 0, count: 32), count: blocksPerPiece - leaves.count)
				}
				roots.append(merkle(leaves, zero: Data(repeating: 0, count: 32)))
			}
			var properties: [String: BencodeValue] = ["length": .integer(file.size)]
			if !roots.isEmpty {
				var zero = Data(repeating: 0, count: 32), blockCount = 1
				while blockCount < blocksPerPiece { zero = Data(SHA256.hash(data: zero + zero)); blockCount *= 2 }
				let root = merkle(roots, zero: zero)
				properties["pieces root"] = .bytes(root)
				if file.size > Int64(pieceLength) { layers[root] = .bytes(roots.reduce(into: Data()) { $0.append($1) }) }
			}
			insert(properties: object(properties), path: ArraySlice(file.path), tree: &tree)
			if directory {
				v1Files.append(object(["length": .integer(file.size), "path": .list(file.path.map { .bytes(Data($0.utf8)) })]))
			}
			if v1Bytes > 0 {
				if directory {
					let padding = pieceLength - v1Bytes
					var left = padding
					while left > 0 {
						try check()
						let size = min(left, 16384); sha1.update(data: Data(repeating: 0, count: size)); left -= size
					}
					v1Files.append(object(["length": .integer(Int64(padding)), "attr": .bytes(Data("p".utf8)), "path": .list([.bytes(Data(".pad".utf8)), .bytes(Data(String(padding).utf8))])]))
				}
				finishV1()
			}
		}
		try check()
		var info: [String: BencodeValue] = [
			"name": .bytes(Data(source.lastPathComponent.utf8)), "piece length": .integer(Int64(pieceLength)),
			"meta version": .integer(2), "pieces": .bytes(pieces), "file tree": .dictionary(tree)
		]
		if directory { info["files"] = .list(v1Files) }
		else { info["length"] = .integer(total) }
		if isPrivate { info["private"] = .integer(1) }
		var metadata: [String: BencodeValue] = ["info": object(info), "piece layers": .dictionary(layers)]
		if let tracker = trackers.first {
			metadata["announce"] = .bytes(Data(tracker.utf8))
			metadata["announce-list"] = .list([.list(trackers.map { .bytes(Data($0.utf8)) })])
		}
		let bytes = try object(metadata).encoded()
		_ = try TorrentMetadata(bytes)
		try check()
		progress(1)
		return bytes
	}

	private static func object(_ fields: [String: BencodeValue]) -> BencodeValue {
		.dictionary(Dictionary(uniqueKeysWithValues: fields.map { (Data($0.key.utf8), $0.value) }))
	}
	private static func insert(properties: BencodeValue, path: ArraySlice<String>, tree: inout [Data: BencodeValue]) {
		guard let first = path.first else { tree[Data()] = properties; return }
		let key = Data(first.utf8)
		var child = tree[key]?.dictionary ?? [:]
		insert(properties: properties, path: path.dropFirst(), tree: &child)
		tree[key] = .dictionary(child)
	}
	private static func merkle(_ hashes: [Data], zero: Data) -> Data {
		precondition(!hashes.isEmpty)
		var layer = hashes, count = 1
		while count < layer.count { count *= 2 }
		layer += Array(repeating: zero, count: count - layer.count)
		while layer.count > 1 {
			layer = stride(from: 0, to: layer.count, by: 2).map { Data(SHA256.hash(data: layer[$0] + layer[$0 + 1])) }
		}
		return layer[0]
	}
	private static func list(_ source: URL, check: () throws -> Void) throws -> ([SourceFile], Bool) {
		let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
		let attributes = try source.resourceValues(forKeys: keys)
		guard attributes.isSymbolicLink != true else { throw MetadataError.invalid("source is a symbolic link") }
		let directory = attributes.isDirectory == true
		var files: [SourceFile] = []
		func append(_ attributes: URLResourceValues, path: [String]) throws {
			guard attributes.isRegularFile == true, let size = attributes.fileSize else { return }
			guard files.count < 50_000, path.count <= 90 else { throw MetadataError.limit("source file count or depth") }
			files.append(SourceFile(path: path, size: Int64(size)))
		}
		if directory {
			var failure: Error?
			guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in failure = error; return false }) else {
				throw MetadataError.invalid("cannot traverse source folder")
			}
			for case let url as URL in enumerator {
				try check()
				let attributes = try url.resourceValues(forKeys: keys)
				if attributes.isSymbolicLink == true { enumerator.skipDescendants(); continue }
				let path = Array(url.resolvingSymlinksInPath().pathComponents.dropFirst(source.pathComponents.count))
				try append(attributes, path: path)
			}
			if let failure { throw failure }
		} else { try append(attributes, path: [source.lastPathComponent]) }
		files.sort { $0.path.joined(separator: "/").utf8.lexicographicallyPrecedes($1.path.joined(separator: "/").utf8) }
		return (files, directory)
	}
	private static func openFile(base: Int32, path: [String]) throws -> Int32 {
		var parent = dup(base)
		guard parent >= 0 else { throw posix("Cannot access source folder") }
		defer { close(parent) }
		for component in path.dropLast() {
			let next = openat(parent, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
			guard next >= 0 else { throw posix("Cannot access source subfolder") }
			close(parent); parent = next
		}
		guard let name = path.last else { throw MetadataError.invalid("missing source filename") }
		let fd = openat(parent, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
		guard fd >= 0 else { throw posix("Cannot read source file") }
		return fd
	}
	private static func posix(_ context: String) -> NSError {
		NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "\(context): \(String(cString: strerror(errno)))"])
	}
}
