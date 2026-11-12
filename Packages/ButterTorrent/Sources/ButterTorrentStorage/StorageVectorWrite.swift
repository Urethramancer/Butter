import Foundation
import Darwin

extension StorageDirectory {
	typealias VectorWriter = (Int32, UnsafePointer<iovec>, Int32, Int64) -> Int

	// Borrow each immutable buffer only while its vector is in use. No pointer
	// escapes this synchronous operation, including after a short write or EINTR.
	static func writeVector(_ data: [Data], to file: Int32, offset: Int64,
		check: () throws -> Void, didWrite: () throws -> Void,
		write: VectorWriter = { pwritev($0, $1, $2, $3) }) throws {
		guard (1...16).contains(data.count), data.allSatisfy({ !$0.isEmpty }) else { throw StorageFailure.limit("write vector buffers") }
		let total = data.reduce(0) { $0 + $1.count }
		guard total <= 262144, offset >= 0, offset <= Int64.max - Int64(total) else { throw StorageFailure.limit("write vector bytes") }
		var vectors: [iovec] = []; vectors.reserveCapacity(data.count)
		func drain() throws {
			var first = 0, written = 0
			while written < total {
				try check()
				let count = vectors.withUnsafeBufferPointer { write(file, $0.baseAddress!.advanced(by: first), Int32($0.count - first), offset + Int64(written)) }
				if count < 0, errno == EINTR { continue }
				guard count > 0 else { throw diskError("Cannot write file", code: count == 0 ? EIO : errno) }
				guard count <= total - written else { throw StorageFailure.invalid("write vector result") }
				try didWrite(); written += count
				var consumed = count
				while first < vectors.count, consumed >= vectors[first].iov_len { consumed -= vectors[first].iov_len; first += 1 }
				if consumed > 0 {
					vectors[first].iov_base = vectors[first].iov_base!.advanced(by: consumed)
					vectors[first].iov_len -= consumed
				}
			}
		}
		func borrow(_ index: Int) throws {
			if index == data.count { try drain(); return }
			try data[index].withUnsafeBytes { bytes in
				vectors.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: bytes.baseAddress!), iov_len: bytes.count))
				defer { vectors.removeLast() }
				try borrow(index + 1)
			}
		}
		try borrow(0)
	}
}
