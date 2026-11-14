import Foundation
import Darwin

extension StorageState {
	private struct WriteRange {
		let file: Int
		let offset: Int64
		var bytes: Range<Int>
	}
	// Validation and durable invalidation have completed before allocating this buffer.
	func writeContiguousRanges(_ writes: [StorageWrite], segments: [[StorageLayout.Segment]], check: () throws -> Void) throws {
		let sorted = writes.indices.sorted {
			writes[$0].piece == writes[$1].piece ? writes[$0].offset < writes[$1].offset : writes[$0].piece < writes[$1].piece
		}
		let overlaps = zip(sorted, sorted.dropFirst()).contains { first, second in
			writes[first].piece == writes[second].piece && writes[first].offset + writes[first].data.count > writes[second].offset
		}
		// Preserve last-write-wins semantics for callers supplying overlapping bytes.
		let indices = overlaps ? Array(writes.indices) : sorted
		var buffer = Data(count: writes.reduce(0) { $0 + $1.data.count })
		var ranges: [WriteRange] = [], cursor = 0
		try buffer.withUnsafeMutableBytes { target in
			for index in indices {
				let write = writes[index], parts = segments[index]
				try check()
				write.data.withUnsafeBytes { source in
					target.baseAddress!.advanced(by: cursor).copyMemory(from: source.baseAddress!, byteCount: source.count)
				}
				for segment in parts {
					if !segment.padding {
						if let last = ranges.last, last.file == segment.file, last.offset + Int64(last.bytes.count) == segment.offset, last.bytes.upperBound == cursor {
							ranges[ranges.count - 1].bytes = last.bytes.lowerBound..<(cursor + segment.count)
						} else { ranges.append(WriteRange(file: segment.file, offset: segment.offset, bytes: cursor..<(cursor + segment.count))) }
					}
					cursor += segment.count
				}
			}
		}
		StorageDiagnostics.count(.contiguousWriteRanges, ranges.count)
		var files: [Int: Int32] = [:], order: [Int] = []
		defer { for file in files.values { close(file) } }
		for range in ranges {
			try check()
			let (directory, path) = location(range.file)
			let file: Int32
			if let cached = files[range.file] { file = cached; StorageDiagnostics.count(.writeDescriptorCacheHits) }
			else {
				if files.count == 8 { let oldest = order.removeFirst(); close(files.removeValue(forKey: oldest)!) }
				file = try directory.openFile(path, write: true); files[range.file] = file; order.append(range.file)
			}
			pendingFlush.insert(range.file)
			try StorageDirectory.write(buffer[range.bytes], to: file, offset: range.offset, maximumChunk: 1_048_576) {
				// Refresh path, identity, link and permission observations on every retry.
				try check()
				let opened = try directory.stamp(file)
				guard let current = try directory.inspect(path), current.sameFile(opened) else { throw StorageFailure.invalid("payload replaced during write batch") }
				if current != record.stamps[range.file] { try invalidateChangedFiles(external: record.stamps[range.file] != nil) }
			}
			record.stamps[range.file] = try directory.stamp(file)
		}
	}
}
