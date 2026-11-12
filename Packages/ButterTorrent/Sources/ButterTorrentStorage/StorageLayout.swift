import Foundation
import ButterTorrentMetadata

public enum StorageFailure: Error, LocalizedError, Equatable, Sendable {
	case invalid(String), collision(String), shared(String), recoveryRequired(String), limit(String), closed
	case missingHashes
	public var errorDescription: String? {
		switch self {
		case .invalid(let text): "Invalid storage data: \(text)."
		case .collision(let path): "A file already occupies \(path). No existing file was replaced."
		case .shared(let path): "The managed file is shared: \(path). Use a separate copy."
		case .recoveryRequired(let text): "Storage recovery needs review: \(text). Files were retained."
		case .limit(let text): "Storage exceeded the \(text) limit."
		case .closed: "The torrent storage is closed."
		case .missingHashes: "Authenticated piece hashes are still missing."
		}
	}
}

/// StorageLayout maps bounded blocks to real files and virtual zero-filled padding.
public struct StorageLayout: Sendable {
	public struct Segment: Equatable, Sendable {
		public let file: Int
		public let offset: Int64
		public let count: Int
		public let padding: Bool
	}
	public let files: [TorrentMetadata.File]
	public let pieceLength: Int
	public let pieceCount: Int
	public let totalBytes: Int64
	private let starts: [Int64]
	public init(metadata: TorrentMetadata) throws {
		files = metadata.inspection.files
		guard files.count <= 50_000, metadata.pieceLength <= 16 * 1024 * 1024 else { throw StorageFailure.limit("file count or piece size") }
		pieceLength = Int(metadata.pieceLength)
		var starts: [Int64] = [], total: Int64 = 0
		for file in files { starts.append(total); total += file.size }
		self.starts = starts; totalBytes = total
		let count = total / metadata.pieceLength + (total % metadata.pieceLength == 0 ? 0 : 1)
		guard count <= 400_000 else { throw StorageFailure.limit("piece count") }
		pieceCount = Int(count)
		try Self.validatePaths(files.filter { !$0.pad }.map(\.path))
	}
	public func length(of piece: Int) throws -> Int {
		guard (0..<pieceCount).contains(piece) else { throw StorageFailure.invalid("piece index") }
		return Int(min(Int64(pieceLength), totalBytes - Int64(piece) * Int64(pieceLength)))
	}
	func pieces(touchingFile index: Int) throws -> Range<Int> {
		guard files.indices.contains(index) else { throw StorageFailure.invalid("file index") }
		guard files[index].size > 0 else { return 0..<0 }
		let first = starts[index] / Int64(pieceLength)
		let last = (starts[index] + files[index].size - 1) / Int64(pieceLength)
		return Int(first)..<(Int(last) + 1)
	}
	public func segments(piece: Int, offset: Int = 0, count: Int) throws -> [Segment] {
		let size = try length(of: piece)
		guard offset >= 0, count > 0, count <= 1_048_576, offset <= size, count <= size - offset else { throw StorageFailure.invalid("piece block range") }
		var position = Int64(piece) * Int64(pieceLength) + Int64(offset), remaining = count, result: [Segment] = []
		// Binary search, including empty files at a boundary.
		var lower = 0, upper = files.count
		while lower < upper {
			let middle = (lower + upper) / 2
			if starts[middle] + files[middle].size <= position { lower = middle + 1 } else { upper = middle }
		}
		var index = lower
		while remaining > 0, index < files.count {
			let offset = position - starts[index], length = Int(min(Int64(remaining), files[index].size - offset))
			if length > 0 { result.append(Segment(file: index, offset: offset, count: length, padding: files[index].pad)); position += Int64(length); remaining -= length }
			index += 1
		}
		guard remaining == 0 else { throw StorageFailure.invalid("incomplete block mapping") }
		return result
	}
	static func components(_ path: String) throws -> [String] {
		let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
		guard !parts.isEmpty, parts.count <= 100, path.utf8.count <= 4096,
			parts.allSatisfy({ validComponent($0) }) else { throw StorageFailure.invalid("relative file path") }
		return parts
	}
	static func validComponent(_ component: some StringProtocol) -> Bool {
		!component.isEmpty && component != "." && component != ".." && !component.utf8.contains(0) && component.utf8.count <= 255
	}
	static func pathKey(_ path: String) -> String {
		path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping
	}
	static func validatePaths(_ paths: [String]) throws {
		for path in paths { _ = try components(path) }
		let sorted = paths.map(pathKey).sorted()
		for (left, right) in zip(sorted, sorted.dropFirst()) where left == right || right.hasPrefix(left + "/") { throw StorageFailure.collision(right) }
	}
	static func validateIsolation(destination: URL, paths: [String], state: URL) throws {
		let root = pathKey(state.path)
		for path in paths {
			let file = pathKey(destination.appendingPathComponent(path).path)
			guard file != root, !file.hasPrefix(root + "/"), !root.hasPrefix(file + "/") else { throw StorageFailure.invalid("payload overlaps its checkpoint directory") }
		}
	}
}
