import Foundation
import Darwin

// A single bounded enumeration belongs to one stamp scan. Names remain in the
// packed buffer; matching never constructs or normalises a directory-entry String.
final class StorageBulkInspection {
	private struct Entry {
		let name: Range<Int>
		let stamp: FileStamp
	}
	static let maximumEntries = 256
	static let bufferBytes = 32768
	static let common: UInt32 = UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_OBJTYPE)
		| UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_CHGTIME) | UInt32(ATTR_CMN_FILEID)
	static let files: UInt32 = UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_DATALENGTH)
	private let bytes: Data
	private var entries: [UInt64: Entry]
	private init(bytes: Data, entries: [UInt64: Entry]) { self.bytes = bytes; self.entries = entries }
	static func read(_ parent: Int32) -> StorageBulkInspection? {
		// A dup shares the enumeration offset; use a separate directory description.
		let directory = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard directory >= 0 else { return nil }; defer { close(directory) }
		var attributes = attrlist()
		attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
		attributes.commonattr = common | UInt32(ATTR_CMN_ERROR) | ATTR_CMN_RETURNED_ATTRS
		attributes.fileattr = files
		var bytes = Data(count: bufferBytes)
		let count = bytes.withUnsafeMutableBytes { buffer in
			getattrlistbulk(directory, &attributes, buffer.baseAddress, buffer.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
		}
		return count > 0 ? decode(bytes, count: Int(count)) : nil
	}
	static func decode(_ bytes: Data, count: Int) -> StorageBulkInspection? {
		guard count > 0, bytes.count <= bufferBytes else { return nil }
		return bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
			var offset = 0, entries: [UInt64: Entry] = [:]
			entries.reserveCapacity(min(count, maximumEntries))
			for _ in 0..<min(count, maximumEntries) {
				guard offset <= buffer.count - MemoryLayout<UInt32>.size else { return nil }
				let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
				guard length >= MemoryLayout<UInt32>.size, length <= buffer.count - offset else { return nil }
				let base = offset
				let entry = UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + length)])
				offset += length
				var cursor = Cursor(bytes: entry)
				guard cursor.take(UInt32.self) != nil, let returned = cursor.take(attribute_set_t.self), let error = cursor.take(UInt32.self) else { return nil }
				let referenceOffset = cursor.offset
				guard let reference = cursor.take(attrreference_t.self), let device = cursor.take(dev_t.self), let kind = cursor.take(fsobj_type_t.self),
					let modified = cursor.take(timespec.self), let changed = cursor.take(timespec.self), let inode = cursor.take(UInt64.self),
					let links = cursor.take(UInt32.self), let size = cursor.take(off_t.self) else { return nil }
				guard error == 0, returned.commonattr & common == common, returned.fileattr & files == files else { continue }
				let start = referenceOffset + Int(reference.attr_dataoffset), nameBytes = Int(reference.attr_length)
				guard start >= cursor.offset, start <= entry.count, (2...256).contains(nameBytes), nameBytes <= entry.count - start,
					entry[start + nameBytes - 1] == 0 else { return nil }
				let name = entry[start..<(start + nameBytes - 1)]
				guard !name.contains(where: { $0 == 0 || $0 == 47 }), !(name.count <= 2 && name.allSatisfy { $0 == 46 }),
					kind == UInt32(VREG.rawValue), links == 1 else { continue }
				var value = stat()
				value.st_dev = device; value.st_ino = inode; value.st_size = size
				value.st_mtimespec = modified; value.st_ctimespec = changed
				// A duplicate or hash collision discards the batch; it never supplies a stamp.
				guard entries.updateValue(Entry(name: (base + start)..<(base + start + name.count), stamp: FileStamp(value)), forKey: key(name)) == nil else { return nil }
			}
			return StorageBulkInspection(bytes: bytes, entries: entries)
		}
	}
	func take(_ name: String) -> FileStamp? {
		guard let entry = entries.removeValue(forKey: Self.key(name.utf8)) else { return nil }
		// Exact bytes, not just a hash or Unicode equivalence, establish the match.
		return bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
			buffer[entry.name].elementsEqual(name.utf8) ? entry.stamp : nil
		}
	}
	private static func key<Bytes: Sequence>(_ bytes: Bytes) -> UInt64 where Bytes.Element == UInt8 {
		bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
	}
	private struct Cursor {
		let bytes: UnsafeRawBufferPointer
		var offset = 0
		mutating func take<T>(_ type: T.Type) -> T? {
			guard MemoryLayout<T>.size <= bytes.count - offset else { return nil }
			let value = bytes.loadUnaligned(fromByteOffset: offset, as: type)
			offset += MemoryLayout<T>.size; return value
		}
	}
}
