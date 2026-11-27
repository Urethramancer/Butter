import Foundation
import Darwin

extension StorageState {
	private struct WriteRange {
		let file: Int
		let offset: Int64
		var bytes: Range<Int>
	}
	// Validation and durable invalidation have completed before allocating this buffer.
	func writeContiguousRanges(_ writes: [StorageWrite], segments: [[StorageLayout.Segment]], retainedFiles: UnsafeMutablePointer<[Int: (fd: Int32, stamp: FileStamp)]>? = nil, check: () throws -> Void) throws {
		let profile = writeProfile
		profile?.enter(.packing)
		let sorted = writes.indices.sorted {
			writes[$0].piece == writes[$1].piece ? writes[$0].offset < writes[$1].offset : writes[$0].piece < writes[$1].piece
		}
		let overlaps = zip(sorted, sorted.dropFirst()).contains { first, second in
			writes[first].piece == writes[second].piece && writes[first].offset + writes[first].data.count > writes[second].offset
		}
		// Preserve last-write-wins semantics for callers supplying overlapping bytes.
		if overlaps { profile?.count("overlapJobs") }
		let indices = overlaps ? Array(writes.indices) : sorted
		let totalBytes = writes.reduce(0) { $0 + $1.data.count }
		let raw = totalBytes > 0 ? malloc(totalBytes) : nil
		if totalBytes > 0, raw == nil { throw diskError("Cannot allocate write buffer", code: ENOMEM) }
		var buffer = raw.map { Data(bytesNoCopy: $0, count: totalBytes, deallocator: .free) } ?? Data()
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
		profile?.count("contiguousRanges", ranges.count)
		for range in ranges { profile?.histogram("contiguousBytes", range.bytes.count) }
		var files: [Int: (fd: Int32, stamp: FileStamp)] = [:], order: [Int] = []
		var transferred = false
		defer {
			if !transferred {
				profile?.enter(.cleanup)
				for entry in files.values { close(entry.fd); profile?.count("descriptorCloses") }
			}
		}
		for range in ranges {
			profile?.enter(.prewriteChecks)
			try check()
			profile?.enter(.descriptorAcquisition)
			profile?.count("descriptorAcquisitions")
			let (directory, path) = location(range.file)
			let file: Int32
			var freshStamp: FileStamp?
			if let cached = files[range.file] { file = cached.fd; profile?.count("descriptorHits"); StorageDiagnostics.count(.writeDescriptorCacheHits) }
			else {
				if files.count == 8 { let oldest = order.removeFirst(); profile?.enter(.cleanup); close(files.removeValue(forKey: oldest)!.fd); profile?.count("descriptorCloses"); profile?.enter(.descriptorAcquisition) }
				let (openedFile, openedStamp) = try directory.openFileWithStamp(path, write: true)
				file = openedFile; freshStamp = openedStamp; files[range.file] = (openedFile, openedStamp); order.append(range.file)
			}
			pendingFlush.insert(range.file)
			try StorageDirectory.write(buffer[range.bytes], to: file, offset: range.offset, maximumChunk: 1_048_576, profile: profile) {
				// Refresh path, identity, link and permission observations on every retry.
				try check()
				let opened: FileStamp
				if let initial = freshStamp { opened = initial; freshStamp = nil }
				else { opened = try directory.stamp(file) }
				guard let current = try directory.inspect(path), current.sameFile(opened) else { throw StorageFailure.invalid("payload replaced during write batch") }
				if current != record.stamps[range.file] {
					profile?.count(record.stamps[range.file] == nil ? "coalescedMismatchAbsent" : "coalescedMismatchRecorded")
					try invalidateChangedFiles(external: record.stamps[range.file] != nil, origin: "coalesced")
				}
			}
			profile?.enter(.postwriteStamping)
			let finalStamp = try directory.stamp(file)
			record.stamps[range.file] = finalStamp
			files[range.file] = (file, finalStamp)
		}
		if let retainedFiles {
			retainedFiles.pointee = files
			transferred = true
		}
	}
}
