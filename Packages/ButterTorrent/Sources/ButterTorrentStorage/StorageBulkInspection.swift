import Foundation
import Darwin

// One bounded directory read belongs to one stamp scan. Unsupported or unsafe
// entries are deliberately omitted so the existing scalar checks handle them.
enum StorageBulkInspection {
	struct Entry {
		let name: String
		let stamp: FileStamp
	}
	static let maximumEntries = 256
	static let bufferBytes = 32768
	static let common: UInt32 = UInt32(ATTR_CMN_NAME) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_OBJTYPE)
		| UInt32(ATTR_CMN_MODTIME) | UInt32(ATTR_CMN_CHGTIME) | UInt32(ATTR_CMN_FILEID)
	static let files: UInt32 = UInt32(ATTR_FILE_LINKCOUNT) | UInt32(ATTR_FILE_DATALENGTH)

	static func read(_ parent: Int32) -> [String: Entry]? {
		// A dup shares the enumeration offset; use a separate directory description.
		let directory = openat(parent, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
		guard directory >= 0 else { return nil }; defer { close(directory) }
		var attributes = attrlist()
		attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
		attributes.commonattr = common | UInt32(ATTR_CMN_ERROR) | ATTR_CMN_RETURNED_ATTRS
		attributes.fileattr = files
		return withUnsafeTemporaryAllocation(byteCount: bufferBytes, alignment: MemoryLayout<UInt64>.alignment) { buffer in
			buffer.initializeMemory(as: UInt8.self, repeating: 0)
			let count = getattrlistbulk(directory, &attributes, buffer.baseAddress, buffer.count, UInt64(FSOPT_PACK_INVAL_ATTRS))
			guard count > 0 else { return nil }
			return decode(UnsafeRawBufferPointer(buffer), count: Int(count))
		}
	}
	static func decode(_ buffer: UnsafeRawBufferPointer, count: Int) -> [String: Entry]? {
		guard count > 0, buffer.count <= bufferBytes else { return nil }
		var offset = 0, result: [String: Entry] = [:]
		result.reserveCapacity(min(count, maximumEntries))
		for _ in 0..<min(count, maximumEntries) {
			guard offset <= buffer.count - MemoryLayout<UInt32>.size else { return nil }
			let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
			guard length >= MemoryLayout<UInt32>.size, length <= buffer.count - offset else { return nil }
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
			guard start >= cursor.offset, start <= entry.count, (1...256).contains(nameBytes), nameBytes <= entry.count - start,
				entry[start + nameBytes - 1] == 0 else { return nil }
			let pointer = entry.baseAddress!.advanced(by: start).assumingMemoryBound(to: CChar.self)
			guard let name = String(validatingCString: pointer), name.utf8.count == nameBytes - 1,
				!name.contains("/"), StorageLayout.validComponent(name) else { continue }
			guard kind == UInt32(VREG.rawValue), links == 1 else { continue }
			var value = stat()
			value.st_dev = device; value.st_ino = inode; value.st_size = size
			value.st_mtimespec = modified; value.st_ctimespec = changed
			// Store compact stamps, not full stat records or separate Data name keys.
			guard result.updateValue(Entry(name: name, stamp: FileStamp(value)), forKey: name) == nil else { return nil }
		}
		return result
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
